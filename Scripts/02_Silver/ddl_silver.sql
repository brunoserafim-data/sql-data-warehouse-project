/*
===============================================================================
DDL Script: Create Silver Layer Tables
===============================================================================
Script Name:     ddl_silver.sql
Description:     Creates all transformed tables within the Silver schema, 
                 incorporating both full truncate-and-reload and incremental 
                 watermarking strategies.
===============================================================================
*/

USE DataWarehouse;
GO

-- ============================================================================
-- 1. Customer Info Table
-- Strategy: Full Truncate & Reload
-- Notes: Cleans and standardizes CRM customer profiles. Wipes and reloads 
--        completely on every pipeline execution.
-- ============================================================================
IF OBJECT_ID('silver.crm_cust_info', 'U') IS NOT NULL
    DROP TABLE silver.crm_cust_info;
GO

CREATE TABLE silver.crm_cust_info (
    cst_id              INT,
    cst_key             NVARCHAR(50),
    cst_firstname       NVARCHAR(50),
    cst_lastname        NVARCHAR(50),
    cst_marital_status  NVARCHAR(50),
    cst_gndr            NVARCHAR(50),
    cst_create_date     DATE,
    dwh_create_date     DATETIME2 DEFAULT GETDATE()
);
GO

-- ============================================================================
-- 2. Product Info Table
-- Strategy: Full Truncate & Reload
-- Notes: Cleans product metadata and handles SCD logic / date overlaps. 
--        Wipes and reloads completely on every pipeline execution.
-- ============================================================================
IF OBJECT_ID('silver.crm_prd_info', 'U') IS NOT NULL
    DROP TABLE silver.crm_prd_info;
GO

CREATE TABLE silver.crm_prd_info (
    prd_id              INT,
    cat_id              NVARCHAR(50),
    prd_key             NVARCHAR(50),
    prd_nm              NVARCHAR(50),
    prd_cost            INT,
    prd_line            NVARCHAR(50),
    prd_start_dt        DATE,
    prd_end_dt          DATE,
    dwh_create_date     DATETIME2 DEFAULT GETDATE()
);
GO

-- ============================================================================
-- 3. Sales Details Table
-- Strategy: Incremental / Watermark Protected Load
-- Notes: High-volume transactional fact table. Uses `IS NULL` instead of 
--        `DROP TABLE` to prevent wiping historical delta data during redeployments.
--        Watermark is the bronze load_id (see audit.etl_watermark); rows are upserted
--        on the business key (sls_ord_num, sls_prd_key). One-time migration: the legacy
--        table (no bronze_load_id) is dropped and rebuilt from bronze history.
-- ============================================================================
IF OBJECT_ID('silver.crm_sales_details', 'U') IS NOT NULL
   AND COL_LENGTH('silver.crm_sales_details', 'bronze_load_id') IS NULL
    DROP TABLE silver.crm_sales_details;
GO

IF OBJECT_ID('silver.crm_sales_details', 'U') IS NULL
BEGIN
    CREATE TABLE silver.crm_sales_details (
        sls_ord_num         NVARCHAR(50) NOT NULL,
        sls_prd_key         NVARCHAR(50) NOT NULL,
        sls_cust_id         INT,
        sls_order_dt        DATE,
        sls_ship_dt         DATE,
        sls_due_dt          DATE,
        sls_sales           INT,
        sls_quantity        INT,
        sls_price           INT,
        bronze_load_id      BIGINT,                              -- bronze row this version came from
        dwh_create_date     DATETIME2 DEFAULT GETDATE(),
        dwh_update_date     DATETIME2 NULL,
        CONSTRAINT pk_silver_crm_sales_details PRIMARY KEY CLUSTERED (sls_ord_num, sls_prd_key)
    );
END
GO

-- ============================================================================
-- 4. ERP Location Table
-- Strategy: Full Truncate & Reload
-- Notes: Standardizes geographical and country codes from ERP extracts. 
--        Wipes and reloads completely on every pipeline execution.
-- ============================================================================
IF OBJECT_ID('silver.erp_loc_a101', 'U') IS NOT NULL
    DROP TABLE silver.erp_loc_a101;
GO

CREATE TABLE silver.erp_loc_a101 (
    cid                 NVARCHAR(50),
    cntry               NVARCHAR(50),
    dwh_create_date     DATETIME2 DEFAULT GETDATE()
);
GO

-- ============================================================================
-- 5. ERP Customer Table
-- Strategy: Full Truncate & Reload
-- Notes: Cleans secondary ERP customer details and birthdates. 
--        Wipes and reloads completely on every pipeline execution.
-- ============================================================================
IF OBJECT_ID('silver.erp_cust_az12', 'U') IS NOT NULL
    DROP TABLE silver.erp_cust_az12;
GO

CREATE TABLE silver.erp_cust_az12 (
    cid                 NVARCHAR(50),
    bdate               DATE,
    gen                 NVARCHAR(50),
    dwh_create_date     DATETIME2 DEFAULT GETDATE()
);
GO

-- ============================================================================
-- 6. ERP Product Category Table
-- Strategy: Full Truncate & Reload
-- Notes: Stores product categories, subcategories, and maintenance mappings. 
--        Wipes and reloads completely on every pipeline execution.
-- ============================================================================
IF OBJECT_ID('silver.erp_px_cat_g1v2', 'U') IS NOT NULL
    DROP TABLE silver.erp_px_cat_g1v2;
GO

CREATE TABLE silver.erp_px_cat_g1v2 ( 
    id                  NVARCHAR(50),
    cat                 NVARCHAR(50),
    subcat              NVARCHAR(50),
    maintenance         NVARCHAR(50),
    dwh_create_date     DATETIME2 DEFAULT GETDATE()
);
GO