# 📖 Data Warehouse Data Catalogue & Architecture

This document serves as the official Data Catalogue for the `DataWarehouse` database. It details table definitions, schema structures, primary/foreign key constraints, and execution loading strategies across all layers of the Medallion Architecture and Audit frameworks.

---

## 🏗️ Architecture & Refresh Strategy Overview

| Schema | Role | Refresh Pattern | Key Mechanics / State Management |
| :--- | :--- | :--- | :--- |
| **`audit`** | Control & Pipeline Metadata | Persistent | Stores execution state, logs, and incremental watermarks. |
| **`bronze`** | Raw Ingestion & Staging | **Hybrid** | Large transaction tables use **Incremental Watermark Append**; static lookup tables use **Full Truncate & Insert**. |
| **`silver`** | Cleansed & Standardised Data | **Full Refresh / Merge** | Standardises datatypes, handles `NULL` values, applies business rules, and enforces foreign key integrity. |
| **`gold`** | Analytical Star Schema | **Full Refresh / Upsert** | Star schema dimension and fact tables optimized for reporting and analytics. |

---

## 0. Audit & Pipeline Control (`audit`)

The `audit` schema manages pipeline execution state, system logs, and watermarking for incremental data ingestion.

### Table: `audit.etl_watermark`
* **Description:** Tracks the high-watermark value (last loaded timestamp/ID) for incrementally loaded tables to ensure idempotent processing without duplicate reads.
* **Loading Pattern:** Updated transactionally upon successful execution of the Bronze load procedures.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `table_name` | `VARCHAR(128)` | **PK / NO** | Unique identifier/name of the target Bronze table. |
| `last_watermark_value` | `VARCHAR(255)` | **NO** | High-watermark boundary from the last successful pipeline execution. |
| `last_loaded_utc` | `DATETIME2` | **NO** | UTC timestamp of when the watermark was updated. |

---

## 1. Bronze Layer (`bronze`)

The Bronze layer ingests raw source data. Column names and types closely match source structures, with raw audit metadata added.

### Table: `bronze.crm_sales_details`
* **Description:** Raw transaction logs for sales transactions ingested from the CRM system.
* **Refresh Strategy:** **Incremental Append** via High-Watermark tracking (`audit.etl_watermark`).
* **Watermark Key:** `sls_order_dt` / `sls_ship_dt`

| Column Name | Data Type | Nullable | Source Field | Description / Notes |
| :--- | :--- | :--- | :--- | :--- |
| `sls_ord_num` | `NVARCHAR(50)` | YES | `sls_ord_num` | Raw sales order number. |
| `sls_prd_key` | `NVARCHAR(50)` | YES | `sls_prd_key` | Raw product key joining to ERP system. |
| `sls_cust_id` | `INT` | YES | `sls_cust_id` | Foreign key referencing Customer ID. |
| `sls_order_dt` | `INT` | YES | `sls_order_dt` | Order date formatted as `YYYYMMDD` integer. |
| `sls_ship_dt` | `INT` | YES | `sls_ship_dt` | Shipping date formatted as `YYYYMMDD` integer. |
| `sls_due_dt` | `INT` | YES | `sls_due_dt` | Due date formatted as `YYYYMMDD` integer. |
| `sls_sales` | `INT` | YES | `sls_sales` | Total gross sale amount. |
| `sls_quantity` | `INT` | YES | `sls_quantity` | Quantity sold. |
| `sls_price` | `INT` | YES | `sls_price` | Unit price. |

### Table: `bronze.crm_cust_info`
* **Description:** Raw customer biographical data from CRM.
* **Refresh Strategy:** **Full Load (Truncate & Insert)**.

| Column Name | Data Type | Nullable | Source Field | Description / Notes |
| :--- | :--- | :--- | :--- | :--- |
| `cst_id` | `INT` | YES | `cst_id` | Unique raw customer identifier. |
| `cst_key` | `NVARCHAR(50)` | YES | `cst_key` | Natural key for customer matching. |
| `cst_firstname` | `NVARCHAR(50)` | YES | `cst_firstname` | First name. |
| `cst_lastname` | `NVARCHAR(50)` | YES | `cst_lastname` | Last name. |
| `cst_marital_status` | `NVARCHAR(50)` | YES | `cst_marital_status` | Raw marital status code (`M`, `S`). |
| `cst_gndr` | `NVARCHAR(50)` | YES | `cst_gndr` | Raw gender code (`M`, `F`). |
| `cst_create_date` | `DATE` | YES | `cst_create_date` | Date account was created. |

### Table: `bronze.erp_loc_a101`
* **Description:** Geographic location reference data from ERP.
* **Refresh Strategy:** **Full Load (Truncate & Insert)**.

| Column Name | Data Type | Nullable | Source Field | Description / Notes |
| :--- | :--- | :--- | :--- | :--- |
| `cid` | `NVARCHAR(50)` | YES | `cid` | Customer ID matching `crm_cust_info.cst_key`. |
| `cntry` | `NVARCHAR(50)` | YES | `cntry` | Raw country code/name string. |

---

## 2. Silver Layer (`silver`)

Cleansed, structured, and validated data. Business logic, `NULL` handling, whitespace trimming, and type casting are applied here.

### Table: `silver.crm_sales_details`
* **Description:** Sanitized sales order line items ready for analytics modeling.

| Column Name | Data Type | Nullable | Transformation Rules |
| :--- | :--- | :--- | :--- |
| `sls_ord_num` | `NVARCHAR(50)` | **NO** | Trimmed whitespace; filtered out invalid header rows. |
| `sls_prd_key` | `NVARCHAR(50)` | **NO** | Formatted product natural key. |
| `sls_cust_id` | `INT` | **NO** | Validated against Silver customer dimension. |
| `sls_order_dt` | `DATE` | YES | Converted from integer `YYYYMMDD` to ISO `DATE`. `NULL` if invalid (`0`). |
| `sls_ship_dt` | `DATE` | YES | Converted from integer `YYYYMMDD` to ISO `DATE`. |
| `sls_due_dt` | `DATE` | YES | Converted from integer `YYYYMMDD` to ISO `DATE`. |
| `sls_sales` | `DECIMAL(12,2)` | YES | Cast to decimal; re-calculated if missing (`quantity * price`). |
| `sls_quantity` | `INT` | YES | Enforced non-negative integer values. |
| `sls_price` | `DECIMAL(12,2)` | YES | Cast to currency decimal. |
| `dwh_create_date` | `DATETIME2` | **NO** | Default system timestamp `GETDATE()`. |

---

## 3. Gold Layer (`gold`)

Dimensional modeling schema (Star Schema) consisting of Business-ready Fact and Dimension tables for reporting tools (Power BI, Tableau).

### Fact Table: `gold.fact_sales`
* **Description:** Star schema central fact table storing transaction metrics.

| Column Name | Data Type | Nullable | Relationship / Description |
| :--- | :--- | :--- | :--- |
| `order_number` | `NVARCHAR(50)` | **NO** | Business transaction key. |
| `customer_key` | `INT` | **NO** | **FK** $\rightarrow$ `gold.dim_customers.customer_key` |
| `product_key` | `INT` | **NO** | **FK** $\rightarrow$ `gold.dim_products.product_key` |
| `order_date` | `DATE` | **NO** | Transaction order date. |
| `shipping_date` | `DATE` | YES | Shipping date. |
| `due_date` | `DATE` | YES | Payment due date. |
| `sales_amount` | `DECIMAL(12,2)` | YES | Line total currency value. |
| `quantity` | `INT` | YES | Units sold. |
| `price` | `DECIMAL(12,2)` | YES | Unit price. |

---

## 4. Data Quality & Validation Suite (`tests`)

The pipeline includes an automated test framework (`tests.run_dq_checks`) executed post-load to verify structural and logical integrity.

### Active Quality Assertions
1. **Uniqueness Tests:** Verifies primary keys across Silver and Gold tables contain zero duplicate values.
2. **Referential Integrity Checks:** Confirms orphaned records do not exist between `gold.fact_sales` and core dimensions.
3. **Date Logic Sanity Checks:** Ensures `sls_ship_dt >= sls_order_dt` across all sales records.
4. **Watermark Continuity Checks:** Validates `audit.etl_watermark` records are updated without timestamp drift or missing table state entries.