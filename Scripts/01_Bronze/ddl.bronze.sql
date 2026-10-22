/*
================================================================================
DDL Script: Bronze Schema Initialisation
================================================================================
Script Purpose:
    Drops and recreates all user tables within the 'bronze' staging layer.
    Use this script to reset or update the baseline DDL schema structures.
    Exception: bronze.crm_sales_details is an append-only history table (watermark
    source) and is NOT dropped on redeploy; it is only migrated once if it still has
    the legacy layout. Its staging table (bronze.crm_sales_details_stg) is dropped and
    recreated like the other tables. To reset the sales history, drop it manually.
================================================================================
*/

USE DataWarehouse;
GO

-- 1. Customer Info Table
IF OBJECT_ID('bronze.crm_cust_info', 'U') IS NOT NULL
    DROP TABLE bronze.crm_cust_info;
GO

CREATE TABLE bronze.crm_cust_info (
    cst_id              INT,
    cst_key             NVARCHAR(50),
    cst_firstname       NVARCHAR(50),
    cst_lastname        NVARCHAR(50),
    cst_marital_status  NVARCHAR(50),
    cst_gndr            NVARCHAR(50),
    cst_create_date     DATE
);
GO

-- 2. Product Info Table
IF OBJECT_ID('bronze.crm_prd_info', 'U') IS NOT NULL
    DROP TABLE bronze.crm_prd_info;
GO

CREATE TABLE bronze.crm_prd_info (
    prd_id          INT,
    prd_key         NVARCHAR(50),
    prd_nm          NVARCHAR(50),
    prd_cost        INT,
    prd_line        NVARCHAR(50),
    prd_start_dt    DATETIME,
    prd_end_dt      DATETIME
);
GO

-- 3. Sales Details Table
-- Incremental design: 3a. staging table (truncated every run) feeds
--                     3b. append-only history table (watermark source).
-- ----------------------------------------------------------------------------
-- 3a. Staging table: mirrors the CSV exactly (BULK INSERT target). Truncated every run.
IF OBJECT_ID('bronze.crm_sales_details_stg', 'U') IS NOT NULL
    DROP TABLE bronze.crm_sales_details_stg;
GO

CREATE TABLE bronze.crm_sales_details_stg (
    sls_ord_num     NVARCHAR(50),
    sls_prd_key     NVARCHAR(50),
    sls_cust_id     INT,
    sls_order_dt    INT,
    sls_ship_dt     INT,
    sls_due_dt      INT,
    sls_sales       INT,
    sls_quantity    INT,
    sls_price       INT
);
GO

-- 3b. History table: append-only. Only NEW or CHANGED source rows are inserted.
--     One-time migration: the legacy 9-column table (no load_id) is dropped; after
--     that the table is never dropped again so history survives redeployments.
IF OBJECT_ID('bronze.crm_sales_details', 'U') IS NOT NULL
   AND COL_LENGTH('bronze.crm_sales_details', 'load_id') IS NULL
    DROP TABLE bronze.crm_sales_details;
GO

IF OBJECT_ID('bronze.crm_sales_details', 'U') IS NULL
BEGIN
    CREATE TABLE bronze.crm_sales_details (
        sls_ord_num         NVARCHAR(50),
        sls_prd_key         NVARCHAR(50),
        sls_cust_id         INT,
        sls_order_dt        INT,
        sls_ship_dt         INT,
        sls_due_dt          INT,
        sls_sales           INT,
        sls_quantity        INT,
        sls_price           INT,
        -- load metadata
        load_id             BIGINT IDENTITY(1,1) NOT NULL,   -- watermark column
        batch_execution_id  UNIQUEIDENTIFIER     NOT NULL,
        load_ts             DATETIME2            NOT NULL DEFAULT SYSDATETIME(),
        row_hash            BINARY(32)           NOT NULL,   -- SHA2_256 of all source columns
        CONSTRAINT PK_bronze_crm_sales_details PRIMARY KEY CLUSTERED (load_id)
    );

    -- Supports change detection (new key / changed hash) during the bronze load
    CREATE NONCLUSTERED INDEX IX_bronze_crm_sales_details_key_hash
        ON bronze.crm_sales_details (sls_ord_num, sls_prd_key) INCLUDE (row_hash);
END;
GO

-- 4. ERP Location Table
IF OBJECT_ID('bronze.erp_loc_a101', 'U') IS NOT NULL
    DROP TABLE bronze.erp_loc_a101;
GO

CREATE TABLE bronze.erp_loc_a101 (
    cid     NVARCHAR(50),
    cntry   NVARCHAR(50)
);
GO

-- 5. ERP Customer Table
IF OBJECT_ID('bronze.erp_cust_az12', 'U') IS NOT NULL
    DROP TABLE bronze.erp_cust_az12;
GO

CREATE TABLE bronze.erp_cust_az12 (
    cid     NVARCHAR(50),
    bdate   DATE,
    gen     NVARCHAR(50)
);
GO

-- 6. ERP Product Category Table
IF OBJECT_ID('bronze.erp_px_cat_g1v2', 'U') IS NOT NULL
    DROP TABLE bronze.erp_px_cat_g1v2;
GO

CREATE TABLE bronze.erp_px_cat_g1v2 ( 
    id          NVARCHAR(50),
    cat         NVARCHAR(50),
    subcat      NVARCHAR(50),
    maintenance NVARCHAR(50)
);
GO