/*
===============================================================================
DDL Script: ETL Watermark Table
===============================================================================
Purpose:
    Stores the last bronze load_id that each incremental target has processed.
    The watermark is a technical, monotonically increasing load_id (NOT a
    business date), so late-arriving rows and rows with NULL/invalid dates are
    never skipped.

Run order: after 04_audit/01_ddl_audit.sql (needs the 'audit' schema).
===============================================================================
*/

USE DataWarehouse;
GO

IF OBJECT_ID('audit.etl_watermark', 'U') IS NULL
BEGIN
    CREATE TABLE audit.etl_watermark (
        target_table     NVARCHAR(128)    NOT NULL PRIMARY KEY,   -- e.g. 'silver.crm_sales_details'
        last_load_id     BIGINT           NOT NULL DEFAULT 0,     -- highest bronze load_id already processed
        last_run_ts      DATETIME2        NULL,
        last_batch_id    UNIQUEIDENTIFIER NULL
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM audit.etl_watermark WHERE target_table = 'silver.crm_sales_details')
    INSERT INTO audit.etl_watermark (target_table)
    VALUES ('silver.crm_sales_details');
GO