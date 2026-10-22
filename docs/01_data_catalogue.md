# 📖 Data Warehouse Data Catalogue & Architecture

This document is the data catalogue for the `DataWarehouse` database. It describes the tables and views in each layer of the medallion architecture, the audit framework, the loading strategy for each object, and the automated data quality checks.

It reflects the scripts in `Scripts/` and `tests/` as they currently stand. If a script changes, update this document with it.

> **Attribution:** the source CSV files, the Bronze / Silver / Gold layering and the overall table design originate from [DataWithBaraa's SQL Data Warehouse Project](https://github.com/DataWithBaraa/sql-data-warehouse-project) (MIT licence). The incremental loading, audit schema and orchestration described below are additions in this repository.

---

## 🏗️ Architecture & Refresh Strategy Overview

| Schema | Role | Refresh Pattern | Key Mechanics / State Management |
| :--- | :--- | :--- | :--- |
| **`audit`** | Control and pipeline metadata | Persistent | Stores the execution log (`audit.pipeline_log`) and the incremental watermark (`audit.etl_watermark`). The audit scripts never drop these tables; only `init_database.sql` resets them. |
| **`bronze`** | Raw ingestion | **Hybrid** | Sales are staged, then **new or changed rows are appended** to an append-only history table (row-hash change detection). The other five tables use **Truncate & Insert**. |
| **`silver`** | Cleansed and standardised data | **Hybrid** | Sales are **upserted incrementally** using a Bronze `load_id` watermark. The other five tables use **Truncate & Reload**. |
| **`gold`** | Analytical star schema | **Views** | Two dimension views and one fact view over Silver, calculated at query time (nothing is stored). |

Only `crm_sales_details` uses the incremental pattern. Every other table is fully reloaded on each run.

**Execution order:** `dbo.run_pipeline` runs `bronze.load_bronze`, then `silver.load_silver`, then checks that the Gold views exist, then runs `tests.run_dq_checks`. One `batch_execution_id` is generated per run and logged by every step. An application lock prevents two runs from overlapping.

---

## 0. Audit & Pipeline Control (`audit`)

### Table: `audit.etl_watermark`

* **Description:** stores the highest Bronze `load_id` that each incremental target has already processed. The watermark is a technical, increasing ID, not a business date, so late-arriving rows and rows with missing or invalid dates are not skipped.
* **Written by:** `silver.load_silver`, in the **same transaction** as the Silver sales upsert. If the load fails, both roll back and the next run retries the same window.
* **Seeded with:** one row for `silver.crm_sales_details`, with `last_load_id = 0`.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `target_table` | `NVARCHAR(128)` | **PK / NO** | Incremental target that the watermark belongs to (for example `silver.crm_sales_details`). |
| `last_load_id` | `BIGINT` | **NO** (default `0`) | Highest `bronze.crm_sales_details.load_id` already processed by Silver. |
| `last_run_ts` | `DATETIME2` | YES | Server-local timestamp (`SYSDATETIME()`) of the last watermark update. This is not UTC. |
| `last_batch_id` | `UNIQUEIDENTIFIER` | YES | `batch_execution_id` of the run that last advanced the watermark. |

### Table: `audit.pipeline_log`

* **Description:** one row per logged step of each pipeline run, with status, row count, duration and any error details.
* **Written by:** `audit.sp_log_start` (inserts a `RUNNING` row), `audit.sp_log_success` and `audit.sp_log_error` (update that row).

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `log_id` | `INT IDENTITY` | **PK / NO** | Log entry identifier. |
| `batch_execution_id` | `UNIQUEIDENTIFIER` | **NO** | Identifier shared by every step of one pipeline run. |
| `layer_name` | `NVARCHAR(50)` | **NO** | For example `Bronze`, `Silver`, `Orchestration`. |
| `procedure_name` | `NVARCHAR(128)` | **NO** | Procedure that logged the step (for example `silver.load_silver`). |
| `target_table` | `NVARCHAR(128)` | YES | Table being loaded. |
| `status` | `NVARCHAR(20)` | **NO** | `RUNNING`, `SUCCESS` or `FAILED`. |
| `rows_inserted` | `INT` | YES | Rows inserted by the step. For Silver sales this counts inserts only, not updates. |
| `start_time` | `DATETIME2` | **NO** | Start time (`GETDATE()`). |
| `end_time` | `DATETIME2` | YES | End time. |
| `duration_seconds` | `INT` | YES | Elapsed seconds. |
| `error_message` | `NVARCHAR(4000)` | YES | Captured error message. |
| `error_number` | `INT` | YES | SQL Server error number. |
| `error_state` | `INT` | YES | SQL Server error state. |

---

## 1. Bronze Layer (`bronze`)

The Bronze layer holds raw source data loaded with `BULK INSERT` from `/var/opt/mssql/datasets/`. Column names and types follow the source files. Nothing is cleansed here.

### Table: `bronze.crm_sales_details_stg` (staging)

* **Description:** exact copy of `sales_details.csv`. Truncated and reloaded on every run, then used as the input for change detection.
* **Refresh strategy:** **Truncate & Insert**. Dropped and recreated by `ddl.bronze.sql`.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `sls_ord_num` | `NVARCHAR(50)` | YES | Sales order number. |
| `sls_prd_key` | `NVARCHAR(50)` | YES | Product key (joins to the product tables after Silver cleansing). |
| `sls_cust_id` | `INT` | YES | Customer ID. |
| `sls_order_dt` | `INT` | YES | Order date as a `YYYYMMDD` integer (may be `0` or invalid). |
| `sls_ship_dt` | `INT` | YES | Ship date as a `YYYYMMDD` integer. |
| `sls_due_dt` | `INT` | YES | Due date as a `YYYYMMDD` integer. |
| `sls_sales` | `INT` | YES | Sales amount. |
| `sls_quantity` | `INT` | YES | Quantity sold. |
| `sls_price` | `INT` | YES | Unit price. |

### Table: `bronze.crm_sales_details` (append-only history)

* **Description:** every distinct version of each sales line seen so far, with load metadata. This is the source for the Silver watermark.
* **Refresh strategy:** **Incremental append**. A staged row is inserted only if its business key (`sls_ord_num`, `sls_prd_key`) has no earlier version, or if its `row_hash` differs from the latest stored version. Rows with a `NULL` order number or product key are not loaded, and one row per business key is taken from each load.
* **Not dropped on redeploy:** `ddl.bronze.sql` keeps this table (it migrates it once from an older layout). To reset the history, drop the table manually or re-run `init_database.sql`.
* **Indexes:** clustered primary key on `load_id`; non-clustered index on (`sls_ord_num`, `sls_prd_key`) including `row_hash`.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `sls_ord_num` | `NVARCHAR(50)` | YES | Sales order number. |
| `sls_prd_key` | `NVARCHAR(50)` | YES | Product key. |
| `sls_cust_id` | `INT` | YES | Customer ID. |
| `sls_order_dt` | `INT` | YES | Order date (`YYYYMMDD` integer). |
| `sls_ship_dt` | `INT` | YES | Ship date (`YYYYMMDD` integer). |
| `sls_due_dt` | `INT` | YES | Due date (`YYYYMMDD` integer). |
| `sls_sales` | `INT` | YES | Sales amount. |
| `sls_quantity` | `INT` | YES | Quantity sold. |
| `sls_price` | `INT` | YES | Unit price. |
| `load_id` | `BIGINT IDENTITY` | **PK / NO** | Increasing load identifier. This is the watermark column. |
| `batch_execution_id` | `UNIQUEIDENTIFIER` | **NO** | Pipeline run that inserted this version. |
| `load_ts` | `DATETIME2` | **NO** | Insert time (`SYSDATETIME()`). |
| `row_hash` | `BINARY(32)` | **NO** | SHA-256 hash of all nine source columns. `NULL` values are replaced with `'~'` before hashing. |

### Table: `bronze.crm_cust_info`

* **Description:** raw CRM customer records. **Refresh strategy:** Truncate & Insert.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `cst_id` | `INT` | YES | Customer ID (may repeat across versions of a customer). |
| `cst_key` | `NVARCHAR(50)` | YES | Customer number used to match ERP data. |
| `cst_firstname` | `NVARCHAR(50)` | YES | First name. |
| `cst_lastname` | `NVARCHAR(50)` | YES | Last name. |
| `cst_marital_status` | `NVARCHAR(50)` | YES | Raw code (`M`, `S`). |
| `cst_gndr` | `NVARCHAR(50)` | YES | Raw code (`M`, `F`). |
| `cst_create_date` | `DATE` | YES | Date the customer record was created. |

### Table: `bronze.crm_prd_info`

* **Description:** raw CRM product records. **Refresh strategy:** Truncate & Insert.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `prd_id` | `INT` | YES | Product record ID. |
| `prd_key` | `NVARCHAR(50)` | YES | Combined key: a five-character category prefix followed by the product number. |
| `prd_nm` | `NVARCHAR(50)` | YES | Product name. |
| `prd_cost` | `INT` | YES | Product cost. |
| `prd_line` | `NVARCHAR(50)` | YES | Raw product line code (`M`, `R`, `S`, `T`). |
| `prd_start_dt` | `DATETIME` | YES | Start of the record's validity. |
| `prd_end_dt` | `DATETIME` | YES | End of validity (not reliable in the source; recalculated in Silver). |

### Table: `bronze.erp_cust_az12`

* **Description:** raw ERP customer demographics. **Refresh strategy:** Truncate & Insert.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `cid` | `NVARCHAR(50)` | YES | Customer ID (may carry a `NAS` prefix). |
| `bdate` | `DATE` | YES | Birthdate. |
| `gen` | `NVARCHAR(50)` | YES | Raw gender value. |

### Table: `bronze.erp_loc_a101`

* **Description:** raw ERP customer locations. **Refresh strategy:** Truncate & Insert.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `cid` | `NVARCHAR(50)` | YES | Customer ID, formatted with a hyphen. |
| `cntry` | `NVARCHAR(50)` | YES | Raw country code or name. |

### Table: `bronze.erp_px_cat_g1v2`

* **Description:** raw ERP product categories. **Refresh strategy:** Truncate & Insert.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `id` | `NVARCHAR(50)` | YES | Category ID. |
| `cat` | `NVARCHAR(50)` | YES | Category. |
| `subcat` | `NVARCHAR(50)` | YES | Subcategory. |
| `maintenance` | `NVARCHAR(50)` | YES | Maintenance flag. |

---

## 2. Silver Layer (`silver`)

The Silver layer holds cleansed, standardised data. Missing values are defaulted, text is trimmed and standardised, dates are converted to `DATE`, and business rules are applied. Every table except sales is truncated and reloaded on each run. Each table also carries a `dwh_create_date DATETIME2` column, which defaults to `GETDATE()`.

### Table: `silver.crm_sales_details` (incremental)

* **Description:** one cleansed row per sales line (`sls_ord_num`, `sls_prd_key`), taken from the latest Bronze version.
* **Refresh strategy:** **Incremental upsert.** Each run processes Bronze rows where `last_load_id < load_id <= highest load_id at the start of the run`, keeps the newest version of each key, updates existing rows, inserts new ones and advances the watermark, all in one transaction. A full rebuild from all Bronze history runs when `@full_refresh = 1`, when Silver is empty, or when the stored watermark is no longer found in Bronze.
* **Not dropped on redeploy:** `ddl_silver.sql` keeps this table (it migrates it once from an older layout).

| Column Name | Data Type | Nullable | Transformation Rules |
| :--- | :--- | :--- | :--- |
| `sls_ord_num` | `NVARCHAR(50)` | **PK / NO** | Business key part 1. Rows with a `NULL` key are excluded. |
| `sls_prd_key` | `NVARCHAR(50)` | **PK / NO** | Business key part 2. Rows with a `NULL` key are excluded. |
| `sls_cust_id` | `INT` | YES | Passed through. It is not validated here; orphans are caught by the Gold quality checks. |
| `sls_order_dt` | `DATE` | YES | `YYYYMMDD` integer converted to `DATE`. `NULL` if the value is `0`, is not eight digits, or is not a valid date. |
| `sls_ship_dt` | `DATE` | YES | As above. |
| `sls_due_dt` | `DATE` | YES | As above. |
| `sls_sales` | `INT` | YES | Rebuilt as `quantity * price` when missing, not positive, or different from `quantity * price`. |
| `sls_quantity` | `INT` | YES | Passed through. |
| `sls_price` | `INT` | YES | Kept if positive. Otherwise derived as `ABS(sales) / quantity` (integer division). `NULL` if quantity is `0` or missing. |
| `bronze_load_id` | `BIGINT` | YES | `load_id` of the Bronze row this version came from. |
| `dwh_create_date` | `DATETIME2` | YES | Default `GETDATE()` (set on insert). |
| `dwh_update_date` | `DATETIME2` | YES | Set to `SYSDATETIME()` when an existing row is updated; `NULL` otherwise. |

### Table: `silver.crm_cust_info`

* **Refresh strategy:** Truncate & Reload.

| Column Name | Data Type | Nullable | Transformation Rules |
| :--- | :--- | :--- | :--- |
| `cst_id` | `INT` | YES | Rows with a `NULL` ID are excluded. One row per ID, keeping the latest `cst_create_date`. |
| `cst_key` | `NVARCHAR(50)` | YES | Passed through. |
| `cst_firstname` | `NVARCHAR(50)` | YES | Trimmed and capitalised (first letter upper case, rest lower case). `'n/a'` if blank. |
| `cst_lastname` | `NVARCHAR(50)` | YES | As above. |
| `cst_marital_status` | `NVARCHAR(50)` | YES | `S` → `Single`, `M` → `Married`, otherwise `n/a`. |
| `cst_gndr` | `NVARCHAR(50)` | YES | `M` → `Male`, `F` → `Female`, otherwise `n/a`. |
| `cst_create_date` | `DATE` | YES | Passed through. |

### Table: `silver.crm_prd_info`

* **Refresh strategy:** Truncate & Reload.

| Column Name | Data Type | Nullable | Transformation Rules |
| :--- | :--- | :--- | :--- |
| `prd_id` | `INT` | YES | Passed through. |
| `cat_id` | `NVARCHAR(50)` | YES | First five characters of the Bronze `prd_key`, with `-` replaced by `_` (matches `erp_px_cat_g1v2.id`). |
| `prd_key` | `NVARCHAR(50)` | YES | Bronze `prd_key` from the seventh character onwards (matches the product key on sales rows). |
| `prd_nm` | `NVARCHAR(50)` | YES | Passed through. |
| `prd_cost` | `INT` | YES | `NULL` replaced with `0`. |
| `prd_line` | `NVARCHAR(50)` | YES | `M` → `Mountain`, `R` → `Road`, `T` → `Touring`, `S` → `Other Sales`, otherwise `n/a`. |
| `prd_start_dt` | `DATE` | YES | Converted to `DATE`. |
| `prd_end_dt` | `DATE` | YES | Recalculated: the day before the next `prd_start_dt` for the same product key. `NULL` for the current version. |

### Table: `silver.erp_cust_az12`

* **Refresh strategy:** Truncate & Reload.

| Column Name | Data Type | Nullable | Transformation Rules |
| :--- | :--- | :--- | :--- |
| `cid` | `NVARCHAR(50)` | YES | `NAS` prefix removed. |
| `bdate` | `DATE` | YES | `NULL` if before 1924-01-01 or in the future. |
| `gen` | `NVARCHAR(50)` | YES | `M` / `MALE` → `Male`, `F` / `FEMALE` → `Female`, otherwise `n/a`. Carriage returns and line feeds are removed first. |

### Table: `silver.erp_loc_a101`

* **Refresh strategy:** Truncate & Reload.

| Column Name | Data Type | Nullable | Transformation Rules |
| :--- | :--- | :--- | :--- |
| `cid` | `NVARCHAR(50)` | YES | Hyphens removed (matches `crm_cust_info.cst_key`). |
| `cntry` | `NVARCHAR(50)` | YES | `US` / `USA` → `United States`, `DE` → `Germany`, blank or `NULL` → `n/a`, otherwise trimmed. |

### Table: `silver.erp_px_cat_g1v2`

* **Refresh strategy:** Truncate & Reload.

| Column Name | Data Type | Nullable | Transformation Rules |
| :--- | :--- | :--- | :--- |
| `id` | `NVARCHAR(50)` | YES | Passed through. |
| `cat` | `NVARCHAR(50)` | YES | Passed through. |
| `subcat` | `NVARCHAR(50)` | YES | Passed through. |
| `maintenance` | `NVARCHAR(50)` | YES | Trailing carriage return, line feed, tab and space characters removed. |

---

## 3. Gold Layer (`gold`)

The Gold layer is a star schema made of **views** over Silver. It is calculated each time it is queried, so it always reflects the current Silver data. Because the objects are views, the relationships below are logical and are **not enforced** by constraints.

> **Surrogate keys:** `customer_key` and `product_key` are produced by `ROW_NUMBER()` at query time. They stay consistent within a single query, but they can change when customers or products are added or removed. Do not store them outside the warehouse.

### View: `gold.dim_customers`

* **Description:** one row per customer, combining CRM details with ERP demographics and location.
* **Sources:** `silver.crm_cust_info` (left joined to `silver.erp_cust_az12` and `silver.erp_loc_a101` on `cst_key = cid`).

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `customer_key` | `BIGINT` | NO | Surrogate key: `ROW_NUMBER()` ordered by `cst_id`. |
| `customer_id` | `INT` | YES | CRM customer ID (unique; checked by the DQ suite). |
| `customer_number` | `NVARCHAR(50)` | YES | CRM customer number. |
| `first_name` | `NVARCHAR(50)` | YES | First name. |
| `last_name` | `NVARCHAR(50)` | YES | Last name. |
| `country` | `NVARCHAR(50)` | YES | Country from ERP; `NULL` if there is no ERP match. |
| `marital_status` | `NVARCHAR(50)` | YES | Marital status. |
| `gender` | `NVARCHAR(50)` | YES | CRM gender if known; otherwise the ERP value; otherwise `n/a`. |
| `birthdate` | `DATE` | YES | Birthdate from ERP. |
| `create_date` | `DATE` | YES | Date the CRM record was created. |

### View: `gold.dim_products`

* **Description:** one row per **current** product version. Products with an end date are excluded.
* **Sources:** `silver.crm_prd_info` (rows with `prd_end_dt IS NULL`), left joined to `silver.erp_px_cat_g1v2` on `cat_id = id`. A product whose category has no match has `NULL` category fields.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `product_key` | `BIGINT` | NO | Surrogate key: `ROW_NUMBER()` ordered by start date, then `prd_id`. |
| `product_id` | `INT` | YES | Product record ID. |
| `product_number` | `NVARCHAR(50)` | YES | Product key used to join sales. |
| `product_name` | `NVARCHAR(50)` | YES | Product name. |
| `category_id` | `NVARCHAR(50)` | YES | Category ID. |
| `category` | `NVARCHAR(50)` | YES | Category. |
| `subcategory` | `NVARCHAR(50)` | YES | Subcategory. |
| `maintenance` | `NVARCHAR(50)` | YES | Maintenance flag. |
| `cost` | `INT` | YES | Product cost. |
| `product_line` | `NVARCHAR(50)` | YES | Product line. |
| `start_date` | `DATE` | YES | Start date of the current version. |

### View: `gold.fact_sales`

* **Description:** one row per sales line, linked to the two dimensions.
* **Sources:** `silver.crm_sales_details`, left joined to `gold.dim_products` (`sls_prd_key = product_number`) and `gold.dim_customers` (`sls_cust_id = customer_id`).

| Column Name | Data Type | Nullable | Relationship / Description |
| :--- | :--- | :--- | :--- |
| `order_number` | `NVARCHAR(50)` | NO | Sales order number. |
| `product_key` | `BIGINT` | YES | Logical link to `gold.dim_products.product_key`. Left join; the DQ suite checks that no value is `NULL`. |
| `customer_key` | `BIGINT` | YES | Logical link to `gold.dim_customers.customer_key`. Left join; the DQ suite checks that no value is `NULL`. |
| `order_date` | `DATE` | YES | Order date. |
| `ship_date` | `DATE` | YES | Ship date. |
| `due_date` | `DATE` | YES | Due date. |
| `sales_amount` | `INT` | YES | Line total in whole currency units. |
| `quantity` | `INT` | YES | Units sold. |
| `price` | `INT` | YES | Unit price in whole currency units. |

---

## 4. Data Quality & Validation Suite (`tests`)

`tests.run_dq_checks` runs as the last step of `dbo.run_pipeline`. It stops at the **first failed assertion** and raises error `50001` with a message beginning `DQ_ERROR`, which fails the pipeline run. Because Gold is made of views, a failed check does not remove data already loaded into Silver.

### Silver checks

| Table | Assertions |
| :--- | :--- |
| `silver.crm_cust_info` | No `NULL` or duplicate `cst_id`; no leading or trailing spaces in `cst_key`; marital status and gender limited to standardised values. |
| `silver.crm_prd_info` | No `NULL` or duplicate `prd_id`; no negative or `NULL` cost; product line limited to standardised values; end date not before start date. |
| `silver.crm_sales_details` | Sales equals quantity × price, with no negative or missing metrics; order date not after ship or due date. |
| `silver.crm_sales_details` (watermark) | Watermark is not ahead of the highest Bronze `load_id`; Silver holds nothing newer than the watermark; Silver matches the latest Bronze version of every business key. |
| `silver.erp_cust_az12` | No remaining `NAS` prefix; birthdate in range; gender standardised. |
| `silver.erp_loc_a101` | No remaining hyphens in `cid`. |
| `silver.erp_px_cat_g1v2` | No unwanted whitespace. |

### Gold checks

| Object | Assertions |
| :--- | :--- |
| `gold.dim_customers` | No `NULL` or duplicate `customer_id`. |
| `gold.dim_products` | No `NULL` or duplicate `product_key`. |
| `gold.fact_sales` | No orphan product or customer keys; row count equals `silver.crm_sales_details` (no join fan-out or loss); no negative or zero sales, quantity or price; order date not after ship or due date. |

The standalone scripts `tests/01_quality_checks_silver.sql` and `tests/02_quality_checks_gold.sql` run similar checks but return rows only where a rule is violated, which is useful for investigating a failure.

---

## 5. Known Limitations

- Source deletions are not detected, so removed orders stay in Bronze history and Silver.
- Bronze sales history grows with every changed row and has no retention policy.
- Gold surrogate keys are not stable (see the Gold section).
- Monetary values are stored as whole numbers (`INT`), as in the source files.
- Gold views are not materialised and are not protected from bad data that has already loaded.
