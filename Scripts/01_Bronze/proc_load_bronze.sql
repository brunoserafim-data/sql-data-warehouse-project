/*
===============================================================================
Stored Procedure: Load Bronze Layer (Source -> Bronze)
===============================================================================
Script Purpose:
    This stored procedure loads data into the 'bronze' schema from external CSV files. 
    It performs the following actions:
    - Truncates the bronze tables before loading data.
      Exception: bronze.crm_sales_details is loaded incrementally. The CSV is bulk loaded
      into the truncated staging table (bronze.crm_sales_details_stg); only new or changed
      rows are then appended to the history table, which is never truncated.
    - Uses the `BULK INSERT` command to load data from CSV Files to bronze tables.

Parameters:
    None.

Usage Example:
    EXEC bronze.load_bronze;

Docker Preparation:
    docker cp "F:\DWH_project\datasets" sqlserver:/var/opt/mssql/
===============================================================================
*/

USE DataWarehouse;
GO

CREATE OR ALTER PROCEDURE bronze.load_bronze AS
BEGIN
    -- Declare auditing control variables
    DECLARE @batch_execution_id UNIQUEIDENTIFIER = NEWID();
    DECLARE @log_id INT;
    DECLARE @rows INT;
    DECLARE @staged INT;

    -- Declare duration tracking variables
    DECLARE @start_time DATETIME, @end_time DATETIME, @batch_start_time DATETIME, @batch_end_time DATETIME;

    BEGIN TRY
        SET @batch_start_time = GETDATE();
        PRINT '==============================';
        PRINT 'Loading Bronze Layer';
        PRINT '==============================';

        PRINT '------------------------------';
        PRINT 'Loading CRM Tables';
        PRINT '------------------------------';

        -- ====================================================================
        -- 1. Table Load: bronze.crm_cust_info
        -- ====================================================================
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Bronze',
            @procedure_name     = 'bronze.load_bronze',
            @target_table       = 'bronze.crm_cust_info',
            @log_id             = @log_id OUTPUT;

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: bronze.crm_cust_info';
        TRUNCATE TABLE bronze.crm_cust_info;
        PRINT '>> Inserting Data Into: bronze.crm_cust_info';
        
        BULK INSERT bronze.crm_cust_info
        FROM '/var/opt/mssql/datasets/source_crm/cust_info.csv'
        WITH (
            FIRSTROW = 2,
            FIELDTERMINATOR = ',',
            ROWTERMINATOR = '0x0a',
            TABLOCK
        );

        SET @rows = @@ROWCOUNT;
        SET @end_time = GETDATE();

        EXEC audit.sp_log_success 
            @log_id        = @log_id, 
            @rows_inserted = @rows;

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '>> -------------';

        -- ====================================================================
        -- 2. Table Load: bronze.crm_prd_info
        -- ====================================================================
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Bronze',
            @procedure_name     = 'bronze.load_bronze',
            @target_table       = 'bronze.crm_prd_info',
            @log_id             = @log_id OUTPUT;

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: bronze.crm_prd_info';
        TRUNCATE TABLE bronze.crm_prd_info;
        PRINT '>> Inserting Data Into: bronze.crm_prd_info';
        
        BULK INSERT bronze.crm_prd_info
        FROM '/var/opt/mssql/datasets/source_crm/prd_info.csv'
        WITH (
            FIRSTROW = 2,
            FIELDTERMINATOR = ',',
            ROWTERMINATOR = '0x0a',
            TABLOCK
        );

        SET @rows = @@ROWCOUNT;
        SET @end_time = GETDATE();

        EXEC audit.sp_log_success 
            @log_id        = @log_id, 
            @rows_inserted = @rows;

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '>> -------------';

        -- ====================================================================
        -- 3. Table Load: bronze.crm_sales_details
        --    Incremental: CSV -> staging (truncate/reload) -> history (append new/changed rows only)
        -- ====================================================================
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Bronze',
            @procedure_name     = 'bronze.load_bronze',
            @target_table       = 'bronze.crm_sales_details',
            @log_id             = @log_id OUTPUT;

        SET @start_time = GETDATE();
        PRINT '>> Truncating Staging Table: bronze.crm_sales_details_stg';
        TRUNCATE TABLE bronze.crm_sales_details_stg;
        PRINT '>> Inserting Data Into: bronze.crm_sales_details_stg';

        BULK INSERT bronze.crm_sales_details_stg
        FROM '/var/opt/mssql/datasets/source_crm/sales_details.csv'
        WITH (
            FIRSTROW = 2,
            FIELDTERMINATOR = ',',
            ROWTERMINATOR = '0x0a',
            TABLOCK
        );
        SET @staged = @@ROWCOUNT;

        PRINT '>> Appending new/changed rows to: bronze.crm_sales_details';
        INSERT INTO bronze.crm_sales_details
               (sls_ord_num, sls_prd_key, sls_cust_id,
                sls_order_dt, sls_ship_dt, sls_due_dt,
                sls_sales, sls_quantity, sls_price,
                batch_execution_id, row_hash)
        SELECT s.sls_ord_num,
               s.sls_prd_key,
               s.sls_cust_id,
               s.sls_order_dt,
               s.sls_ship_dt,
               s.sls_due_dt,
               s.sls_sales,
               s.sls_quantity,
               s.sls_price,
               @batch_execution_id,
               h.row_hash
          FROM bronze.crm_sales_details_stg AS s
               CROSS APPLY (
                   SELECT HASHBYTES('SHA2_256', CONCAT_WS('|',
                              ISNULL(s.sls_ord_num, '~'),
                              ISNULL(s.sls_prd_key, '~'),
                              ISNULL(CAST(s.sls_cust_id  AS NVARCHAR(20)), '~'),
                              ISNULL(CAST(s.sls_order_dt AS NVARCHAR(20)), '~'),
                              ISNULL(CAST(s.sls_ship_dt  AS NVARCHAR(20)), '~'),
                              ISNULL(CAST(s.sls_due_dt   AS NVARCHAR(20)), '~'),
                              ISNULL(CAST(s.sls_sales    AS NVARCHAR(20)), '~'),
                              ISNULL(CAST(s.sls_quantity AS NVARCHAR(20)), '~'),
                              ISNULL(CAST(s.sls_price    AS NVARCHAR(20)), '~')
                          )) AS row_hash
               ) AS h
         WHERE NOT EXISTS
               (SELECT 1
                  FROM bronze.crm_sales_details AS b
                 WHERE b.sls_ord_num = s.sls_ord_num
                   AND b.sls_prd_key = s.sls_prd_key
                   AND b.row_hash    = h.row_hash);

        SET @rows = @@ROWCOUNT;
        SET @end_time = GETDATE();

        EXEC audit.sp_log_success 
            @log_id        = @log_id, 
            @rows_inserted = @rows;

        PRINT '>> Rows staged: ' + CAST(@staged AS NVARCHAR(20)) + ' | New/changed rows appended: ' + CAST(@rows AS NVARCHAR(20));
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '>> -------------';

        PRINT '------------------------------';
        PRINT 'Loading ERP Tables';
        PRINT '------------------------------';

        -- ====================================================================
        -- 4. Table Load: bronze.erp_loc_a101
        -- ====================================================================
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Bronze',
            @procedure_name     = 'bronze.load_bronze',
            @target_table       = 'bronze.erp_loc_a101',
            @log_id             = @log_id OUTPUT;

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: bronze.erp_loc_a101';
        TRUNCATE TABLE bronze.erp_loc_a101;
        PRINT '>> Inserting Data Into: bronze.erp_loc_a101';
        
        BULK INSERT bronze.erp_loc_a101
        FROM '/var/opt/mssql/datasets/source_erp/loc_a101.csv'
        WITH (
            FIRSTROW = 2,
            FIELDTERMINATOR = ',',
            ROWTERMINATOR = '0x0a',
            TABLOCK
        );

        SET @rows = @@ROWCOUNT;
        SET @end_time = GETDATE();

        EXEC audit.sp_log_success 
            @log_id        = @log_id, 
            @rows_inserted = @rows;

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '>> -------------';

        -- ====================================================================
        -- 5. Table Load: bronze.erp_cust_az12
        -- ====================================================================
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Bronze',
            @procedure_name     = 'bronze.load_bronze',
            @target_table       = 'bronze.erp_cust_az12',
            @log_id             = @log_id OUTPUT;

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: bronze.erp_cust_az12';
        TRUNCATE TABLE bronze.erp_cust_az12;
        PRINT '>> Inserting Data Into: bronze.erp_cust_az12';
        
        BULK INSERT bronze.erp_cust_az12
        FROM '/var/opt/mssql/datasets/source_erp/cust_az12.csv'
        WITH (
            FIRSTROW = 2,
            FIELDTERMINATOR = ',',
            ROWTERMINATOR = '0x0a',
            TABLOCK
        );

        SET @rows = @@ROWCOUNT;
        SET @end_time = GETDATE();

        EXEC audit.sp_log_success 
            @log_id        = @log_id, 
            @rows_inserted = @rows;

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '>> -------------';

        -- ====================================================================
        -- 6. Table Load: bronze.erp_px_cat_g1v2
        -- ====================================================================
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Bronze',
            @procedure_name     = 'bronze.load_bronze',
            @target_table       = 'bronze.erp_px_cat_g1v2',
            @log_id             = @log_id OUTPUT;

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: bronze.erp_px_cat_g1v2';
        TRUNCATE TABLE bronze.erp_px_cat_g1v2;
        PRINT '>> Inserting Data Into: bronze.erp_px_cat_g1v2';
        
        BULK INSERT bronze.erp_px_cat_g1v2
        FROM '/var/opt/mssql/datasets/source_erp/px_cat_g1v2.csv'
        WITH (
            FIRSTROW = 2,
            FIELDTERMINATOR = ',',
            ROWTERMINATOR = '0x0a',
            TABLOCK
        );

        SET @rows = @@ROWCOUNT;
        SET @end_time = GETDATE();

        EXEC audit.sp_log_success 
            @log_id        = @log_id, 
            @rows_inserted = @rows;

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '>> -------------';

        SET @batch_end_time = GETDATE();
        PRINT '==============================================';
        PRINT 'Bronze Layer Loading Completed Successfully';
        PRINT 'Total Load Duration: ' + CAST(DATEDIFF(second, @batch_start_time, @batch_end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '==============================================';

    END TRY
    BEGIN CATCH
        -- Capture error details into local variables
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorState INT = ERROR_STATE();

        -- Log failure dynamically to active log ID if it exists
        EXEC audit.sp_log_error
            @log_id        = @log_id,
            @error_message = @ErrorMessage,
            @error_number  = @ErrorNumber,
            @error_state   = @ErrorState;

        PRINT '==========================================';
        PRINT 'ERROR OCCURRED DURING LOADING BRONZE LAYER';
        PRINT '------------------------------------------';
        PRINT 'Error Message: ' + ISNULL(@ErrorMessage, 'No error message available.');
        PRINT 'Error Number:  ' + CAST(@ErrorNumber AS NVARCHAR(15));
        PRINT 'Error State:   ' + CAST(@ErrorState AS NVARCHAR(15));
        PRINT '==========================================';

        THROW;
    END CATCH
END;
GO

EXEC bronze.load_bronze;
GO