# Enterprise SQL Data Warehouse - Data Catalogue

This document serves as the comprehensive data catalogue and dictionary for the enterprise SQL Data Warehouse project. It details the complete schema architecture, table structures, column specifications, data types, automated audit logging, and data quality test assertions across all layers (**Bronze**, **Silver**, **Gold**, **Audit**, and **Tests**).

---

## Table of Contents
1. [Audit Schema (`audit`)](#1-audit-schema-audit)
2. [Bronze Layer (`bronze`) - Raw Ingestion](#2-bronze-layer-bronze---raw-ingestion)
3. [Silver Layer (`silver`) - Cleansed & Watermarked Operational Data](#3-silver-layer-silver---cleansed--watermarked-operational-data)
4. [Gold Layer (`gold`) - Semantic Star-Schema Analytics](#4-gold-layer-gold---semantic-star-schema-analytics)
5. [Tests Schema (`tests`) - Automated Quality Gatekeeper](#5-tests-schema-tests---automated-quality-gatekeeper)

---

## 1. Audit Schema (`audit`)

The audit schema maintains centralized execution telemetry, batch tracking, and error logging across all stored procedures.

### `audit.pipeline_log`
Tracks pipeline execution states, batch identifiers, run durations, and row insertion counts.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `log_id` | `INT` | NO | Unique surrogate identifier for the log entry (Auto-incrementing PK). |
| `batch_id` | `VARCHAR(50)` | YES | Unique batch execution reference string linking multi-step pipeline runs. |
| `layer_name` | `VARCHAR(50)` | YES | Specifies the pipeline tier executed (`BRONZE`, `SILVER`, `GOLD`, or `ORCHESTRATION`). |
| `procedure_name` | `SYSNAME` | YES | Name of the stored procedure executing the step. |
| `rows_inserted` | `INT` | YES | Number of records successfully processed and inserted during the step. |
| `execution_status` | `VARCHAR(20)` | YES | Operational status (`STARTED`, `SUCCESS`, or `ERROR`). |
| `error_message` | `VARCHAR(MAX)` | YES | Detailed error description captured via `ERROR_MESSAGE()` upon failure. |
| `created_at` | `DATETIME2` | NO | Timestamp recording when the log entry was generated (`DEFAULT SYSDATETIME()`). |

---

## 2. Bronze Layer (`bronze`) - Raw Ingestion

The Bronze layer ingests raw source extracts as-is from CSV files (`.csv`) without structural alterations or type normalisation, utilizing full truncate-and-insert batch loads.

### 2.1 `bronze.crm_cust_info`
* **Source File:** `cust_info.csv`
* **Load Strategy:** Full Refresh (`TRUNCATE TABLE` followed by `BULK INSERT`)

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `cst_id` | `INT` | YES | Raw customer identifier from the CRM source system. |
| `cst_key` | `VARCHAR(50)` | YES | Business key / account reference string. |
| `cst_firstname` | `VARCHAR(50)` | YES | Raw customer first name. |
| `cst_lastname` | `VARCHAR(50)` | YES | Raw customer surname. |
| `cst_marital_status` | `VARCHAR(20)` | YES | Unprocessed marital status code (e.g. 'M', 'S'). |
| `cst_gndr` | `VARCHAR(20)` | YES | Unprocessed gender indicator string. |
| `cst_create_date` | `DATE` | YES | Raw account creation date stamp. |

---

### 2.2 `bronze.crm_prd_info`
* **Source File:** `prd_info.csv`
* **Load Strategy:** Full Refresh (`TRUNCATE TABLE` followed by `BULK INSERT`)

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `prd_id` | `INT` | YES | Raw product identifier from the CRM system. |
| `prd_key` | `VARCHAR(50)` | YES | Product SKU or business key string. |
| `prd_nm` | `VARCHAR(100)` | YES | Unprocessed product description name. |
| `prd_cost` | `DECIMAL(18,2)` | YES | Raw product manufacturing or acquisition cost. |
| `prd_line` | `VARCHAR(20)` | YES | Product line classification category. |
| `prd_start_dt` | `DATE` | YES | Product availability start date. |
| `prd_end_dt` | `DATE` | YES | Product discontinuation or retirement date. |

---

### 2.3 `bronze.crm_sales_details`
* **Source File:** `sales_details.csv`
* **Load Strategy:** Full Refresh (`TRUNCATE TABLE` followed by `BULK INSERT`)

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `sls_ord_num` | `VARCHAR(50)` | YES | Sales transaction order reference number. |
| `sls_prd_key` | `VARCHAR(50)` | YES | Product key associated with the order line. |
| `sls_cust_id` | `INT` | YES | Customer identifier associated with the transaction. |
| `sls_order_dt` | `DATE` | YES | Order placement date. |
| `sls_ship_dt` | `DATE` | YES | Order shipment date. |
| `sls_due_dt` | `DATE` | YES | Order payment due date. |
| `sls_sales` | `DECIMAL(18,2)` | YES | Gross transactional sales amount. |
| `sls_quantity` | `INT` | YES | Number of units purchased in the order line. |
| `sls_price` | `DECIMAL(18,2)` | YES | Unit selling price. |

---

### 2.4 `bronze.erp_cust_az12`
* **Source File:** `CUST_AZ12.csv`
* **Load Strategy:** Full Refresh (`TRUNCATE TABLE` followed by `BULK INSERT`)

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `cid` | `VARCHAR(50)` | YES | ERP system customer identifier string (requires prefix stripping). |
| `bdate` | `DATE` | YES | Customer date of birth. |
| `gen` | `VARCHAR(20)` | YES | ERP gender classification code. |

---

### 2.5 `bronze.erp_loc_a101`
* **Source File:** `LOC_A101.csv`
* **Load Strategy:** Full Refresh (`TRUNCATE TABLE` followed by `BULK INSERT`)

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `cid` | `VARCHAR(50)` | YES | Customer identifier linking location records to customers. |
| `cntry` | `VARCHAR(50)` | YES | Country name or regional code. |

---

### 2.6 `bronze.erp_px_cat_g1v2`
* **Source File:** `PX_CAT_G1V2.csv`
* **Load Strategy:** Full Refresh (`TRUNCATE TABLE` followed by `BULK INSERT`)

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `id` | `VARCHAR(50)` | YES | Product category identifier code. |
| `cat` | `VARCHAR(50)` | YES | High-level product category name. |
| `subcat` | `VARCHAR(50)` | YES | Product sub-category classification. |
| `maintenance` | `VARCHAR(20)` | YES | Maintenance requirement flag. |

---

## 3. Silver Layer (`silver`) - Cleansed & Watermarked Operational Data

The Silver layer transforms raw Bronze tables by applying string trimming, case normalisation, derived gender mapping, ISO country standardisation, key sanitisation, deduplication via ranking functions, and incremental watermark delta filtering (`@last_order_dt`).

### 3.1 `silver.crm_cust_info`
* **Transformations Applied:** Trimming whitespace, standardising marital status ('Married' / 'Single'), mapping gender values ('Male' / 'Female' / 'N/A'), and removing duplicate customer records using `ROW_NUMBER()`.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `cst_id` | `INT` | NO | Cleansed unique customer identifier. |
| `cst_key` | `VARCHAR(50)` | NO | Sanitised customer business key. |
| `cst_firstname` | `VARCHAR(50)` | YES | Cleaned first name (proper case / trimmed). |
| `cst_lastname` | `VARCHAR(50)` | YES | Cleaned surname (proper case / trimmed). |
| `cst_marital_status` | `VARCHAR(20)` | YES | Normalised marital status. |
| `cst_gndr` | `VARCHAR(20)` | YES | Standardised gender classification. |
| `cst_create_date` | `DATE` | YES | Validated account creation date. |

---

### 3.2 `silver.crm_prd_info`
* **Transformations Applied:** Extracting category sub-strings from product keys, handling missing cost values, and standardising product line abbreviations.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `prd_id` | `INT` | NO | Unique product identifier. |
| `cat_id` | `VARCHAR(50)` | YES | Extracted category identifier for ERP product mapping. |
| `prd_key` | `VARCHAR(50)` | NO | Sanitised product SKU. |
| `prd_nm` | `VARCHAR(100)` | YES | Cleaned product name. |
| `prd_cost` | `DECIMAL(18,2)` | YES | Validated product cost (defaults managed). |
| `prd_line` | `VARCHAR(20)` | YES | Normalised product line category. |
| `prd_start_dt` | `DATE` | YES | Effective start date for product availability. |
| `prd_end_dt` | `DATE` | YES | Effective end date (nulls handled for active products). |

---

### 3.3 `silver.crm_sales_details`
* **Transformations Applied:** Incremental watermark delta ingestion (`WHERE sls_order_dt > @last_order_dt`), date validation, and sales amount recalculation safety checks (`quantity * price`).

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `sls_ord_num` | `VARCHAR(50)` | NO | Sales order reference number. |
| `sls_prd_key` | `VARCHAR(50)` | NO | Product key linked to order line. |
| `sls_cust_id` | `INT` | NO | Customer identifier linked to transaction. |
| `sls_order_dt` | `DATE` | YES | Validated order date (watermark tracking field). |
| `sls_ship_dt` | `DATE` | YES | Validated shipment date. |
| `sls_due_dt` | `DATE` | YES | Validated payment due date. |
| `sls_sales` | `DECIMAL(18,2)` | YES | Calculated or verified gross sales value. |
| `sls_quantity` | `INT` | YES | Units ordered. |
| `sls_price` | `DECIMAL(18,2)` | YES | Unit price. |

---

### 3.4 `silver.erp_cust_az12`
* **Transformations Applied:** Stripping formatting prefixes (e.g. removing 'NAS' prefixes from customer keys), date-of-birth boundary checks, and gender standardisation.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `cid` | `VARCHAR(50)` | NO | Sanitised customer ID with prefixes removed. |
| `bdate` | `DATE` | YES | Cleaned customer date of birth. |
| `gen` | `VARCHAR(20)` | YES | Standardised gender classification. |

---

### 3.5 `silver.erp_loc_a101`
* **Transformations Applied:** Stripping special formatting characters from customer keys and standardising country nomenclature (e.g. mapping 'DE' to 'Germany', 'US' to 'United States').

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `cid` | `VARCHAR(50)` | NO | Cleaned customer ID. |
| `cntry` | `VARCHAR(50)` | YES | Standardised country name. |

---

### 3.6 `silver.erp_px_cat_g1v2`
* **Transformations Applied:** Trimming whitespace and standardising category, sub-category, and maintenance attribute values.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `id` | `VARCHAR(50)` | NO | Category identifier. |
| `cat` | `VARCHAR(50)` | YES | Standardised product category name. |
| `subcat` | `VARCHAR(50)` | YES | Standardised product sub-category name. |
| `maintenance` | `VARCHAR(20)` | YES | Normalised maintenance requirement status. |

---

## 4. Gold Layer (`gold`) - Semantic Star-Schema Analytics

The Gold layer provides business-ready analytical views structured in a Star Schema format, integrating CRM and ERP data sources for downstream Business Intelligence tools (e.g. Power BI, Tableau).

### 4.1 `gold.dim_customers`
* **Description:** Integrated customer dimension combining CRM demographics with ERP geographical and birthdate attributes.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `customer_key` | `INT` | NO | Surrogate primary key generated for the customer dimension. |
| `customer_id` | `INT` | NO | Natural customer identifier from source systems. |
| `customer_number` | `VARCHAR(50)` | NO | Business account key. |
| `first_name` | `VARCHAR(50)` | YES | Customer first name. |
| `last_name` | `VARCHAR(50)` | YES | Customer surname. |
| `birthdate` | `DATE` | YES | Customer date of birth (sourced from ERP). |
| `marital_status` | `VARCHAR(20)` | YES | Customer marital status. |
| `gender` | `VARCHAR(20)` | YES | Standardised gender. |
| `country` | `VARCHAR(50)` | YES | Customer country location (sourced from ERP). |
| `create_date` | `DATE` | YES | Account creation date. |

---

### 4.2 `gold.dim_products`
* **Description:** Integrated product dimension combining CRM product attributes with ERP category classifications.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `product_key` | `INT` | NO | Surrogate primary key for the product dimension. |
| `product_id` | `INT` | NO | Natural product identifier. |
| `product_number` | `VARCHAR(50)` | NO | Product SKU / key. |
| `product_name` | `VARCHAR(100)` | YES | Product description name. |
| `category` | `VARCHAR(50)` | YES | Product category classification (ERP). |
| `subcategory` | `VARCHAR(50)` | YES | Product sub-category classification (ERP). |
| `maintenance` | `VARCHAR(20)` | YES | Maintenance status indicator. |
| `cost` | `DECIMAL(18,2)` | YES | Product cost. |
| `product_line` | `VARCHAR(20)` | YES | Product line grouping. |
| `start_date` | `DATE` | YES | Effective start date. |

---

### 4.3 `gold.fact_sales`
* **Description:** Transactional fact table linking sales line items to `dim_customers` and `dim_products` via surrogate keys.

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `order_number` | `VARCHAR(50)` | NO | Sales transaction order reference number. |
| `product_key` | `INT` | NO | Foreign key linking to `gold.dim_products`. |
| `customer_key` | `INT` | NO | Foreign key linking to `gold.dim_customers`. |
| `order_date` | `DATE` | YES | Order placement date. |
| `shipping_date` | `DATE` | YES | Shipment date. |
| `due_date` | `DATE` | YES | Payment due date. |
| `sales_amount` | `DECIMAL(18,2)` | YES | Gross sales transaction amount. |
| `quantity` | `INT` | YES | Units purchased. |
| `price` | `DECIMAL(18,2)` | YES | Unit selling price. |

---

## 5. Tests Schema (`tests`) - Automated Quality Gatekeeper

The `tests` schema contains automated validation procedures executed between Silver layer processing and Gold layer exposure to enforce strict data reliability.

### `tests.run_dq_checks`
* **Execution Timing:** Automatically triggered by `dbo.run_pipeline` immediately after Silver transformation completion.
* **Fail-Fast Assertion Rules:**
  1. **Surrogate Key Uniqueness:** Asserts that primary key columns contain no duplicate values.
  2. **Nullability Checks:** Validates that mandatory business columns contain no unexpected `NULL` values.
  3. **Value Boundary Assertions:** Confirms that transactional sales and quantities contain no negative values (`sales >= 0`, `quantity >= 0`).
  4. **Referential Integrity:** Verifies that all foreign keys in transactional tables successfully resolve to parent dimension records, preventing orphaned records.
* **Error Handling:** If any assertion fails, the procedure logs the specific violation to `audit.pipeline_log`, raises an exception, and halts pipeline execution to protect semantic data integrity.