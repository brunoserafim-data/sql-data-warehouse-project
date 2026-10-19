/*
===============================================================================
Stored Procedure: Load Silver Layer (Bronze -> Silver)
===============================================================================
*/

USE DataWarehouse;
GO

CREATE OR ALTER PROCEDURE silver.load_silver AS
BEGIN
    -- Declare auditing control variables
    DECLARE @batch_execution_id UNIQUEIDENTIFIER = NEWID();
    DECLARE @log_id INT;
    DECLARE @rows INT;

    -- Declare duration tracking variables
    DECLARE @start_time DATETIME, @end_time DATETIME, @batch_start_time DATETIME, @batch_end_time DATETIME;

    -- Declare incremental loading / watermark variables
    DECLARE @last_order_dt DATE;

    BEGIN TRY
        SET @batch_start_time = GETDATE();
        PRINT '========================================';
        PRINT 'Loading Silver Layer';
        PRINT '========================================';

        PRINT '------------------------------';
        PRINT 'Loading CRM Tables';
        PRINT '------------------------------';

        -- ====================================================================
        -- 1. Table Load: silver.crm_cust_info
        -- ====================================================================
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Silver',
            @procedure_name     = 'silver.load_silver',
            @target_table       = 'silver.crm_cust_info',
            @log_id             = @log_id OUTPUT;

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.crm_cust_info';
        TRUNCATE TABLE silver.crm_cust_info;
        PRINT '>> Inserting Data Into: silver.crm_cust_info';

        INSERT INTO silver.crm_cust_info (
            cst_id,
            cst_key,
            cst_firstname,
            cst_lastname,
            cst_marital_status,
            cst_gndr,
            cst_create_date
        )
        SELECT
            cst_id,
            cst_key,
            CASE 
                WHEN cst_firstname IS NULL OR TRIM(cst_firstname) = '' THEN 'n/a'
                ELSE UPPER(LEFT(TRIM(cst_firstname), 1)) + LOWER(SUBSTRING(TRIM(cst_firstname), 2, LEN(cst_firstname)))
            END AS cst_firstname,
            CASE 
                WHEN cst_lastname IS NULL OR TRIM(cst_lastname) = '' THEN 'n/a'
                ELSE UPPER(LEFT(TRIM(cst_lastname), 1)) + LOWER(SUBSTRING(TRIM(cst_lastname), 2, LEN(cst_lastname)))
            END AS cst_lastname,
            CASE WHEN UPPER(TRIM(cst_marital_status)) = 'S' THEN 'Single' 
                 WHEN UPPER(TRIM(cst_marital_status)) = 'M' THEN 'Married' 
                 ELSE 'n/a' END AS cst_marital_status,
            CASE WHEN UPPER(TRIM(cst_gndr)) = 'M' THEN 'Male' 
                 WHEN UPPER(TRIM(cst_gndr)) = 'F' THEN 'Female' 
                 ELSE 'n/a' END AS cst_gndr,
            cst_create_date
        FROM (
            SELECT *,
                ROW_NUMBER() OVER (PARTITION BY cst_id ORDER BY cst_create_date DESC) AS rn
            FROM bronze.crm_cust_info 
            WHERE cst_id IS NOT NULL
        ) AS s
        WHERE rn = 1;

        SET @rows = @@ROWCOUNT;
        SET @end_time = GETDATE();

        EXEC audit.sp_log_success 
            @log_id        = @log_id, 
            @rows_inserted = @rows;

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '>> -------------';

        -- ====================================================================
        -- 2. Table Load: silver.crm_prd_info
        -- ====================================================================
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Silver',
            @procedure_name     = 'silver.load_silver',
            @target_table       = 'silver.crm_prd_info',
            @log_id             = @log_id OUTPUT;

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.crm_prd_info';
        TRUNCATE TABLE silver.crm_prd_info;
        PRINT '>> Inserting Data Into: silver.crm_prd_info';

        INSERT INTO silver.crm_prd_info (
            prd_id,
            cat_id,
            prd_key,
            prd_nm,
            prd_cost,
            prd_line,
            prd_start_dt,
            prd_end_dt
        )
        SELECT
            prd_id,
            REPLACE(SUBSTRING(prd_key, 1, 5), '-', '_') AS cat_id,
            SUBSTRING(prd_key, 7, LEN(prd_key)) AS prd_key,
            prd_nm,
            ISNULL(prd_cost, 0) AS prd_cost,
            CASE 
                WHEN UPPER(TRIM(prd_line)) = 'M' THEN 'Mountain'
                WHEN UPPER(TRIM(prd_line)) = 'R' THEN 'Road'
                WHEN UPPER(TRIM(prd_line)) = 'T' THEN 'Touring'
                WHEN UPPER(TRIM(prd_line)) = 'S' THEN 'Other Sales'
                ELSE 'n/a'
            END AS prd_line,
            CAST(prd_start_dt AS DATE) AS prd_start_dt,
            CAST(DATEADD(day, -1, LEAD(prd_start_dt) OVER (PARTITION BY prd_key ORDER BY prd_start_dt)) AS DATE) AS prd_end_dt
        FROM bronze.crm_prd_info;

        SET @rows = @@ROWCOUNT;
        SET @end_time = GETDATE();

        EXEC audit.sp_log_success 
            @log_id        = @log_id, 
            @rows_inserted = @rows;

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '>> -------------';

        -- ====================================================================
        -- 3. Table Load: silver.crm_sales_details (INCREMENTAL / WATERMARK LOAD)
        -- ====================================================================
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Silver',
            @procedure_name     = 'silver.load_silver',
            @target_table       = 'silver.crm_sales_details',
            @log_id             = @log_id OUTPUT;

        SET @start_time = GETDATE();

        -- Retrieve current watermark (latest loaded order date)
        SELECT @last_order_dt = MAX(sls_order_dt) FROM silver.crm_sales_details;
        SET @last_order_dt = ISNULL(@last_order_dt, '1900-01-01');

        PRINT '>> Incremental Load Watermark Threshold: ' + CAST(@last_order_dt AS VARCHAR(10));
        PRINT '>> Inserting Delta Data Into: silver.crm_sales_details';

        INSERT INTO silver.crm_sales_details (
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            sls_order_dt,
            sls_ship_dt,
            sls_due_dt,
            sls_sales,
            sls_quantity,
            sls_price
        )
        SELECT
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            sls_order_dt,
            sls_ship_dt,
            sls_due_dt,
            sls_sales,
            sls_quantity,
            sls_price
        FROM (
            SELECT
                sls_ord_num,
                sls_prd_key,
                sls_cust_id,
                CASE
                    WHEN sls_order_dt = 0 OR LEN(CAST(sls_order_dt AS VARCHAR)) != 8 THEN NULL
                    ELSE CAST(CAST(sls_order_dt AS VARCHAR) AS DATE)
                END AS sls_order_dt,
                CASE
                    WHEN sls_ship_dt = 0 OR LEN(CAST(sls_ship_dt AS VARCHAR)) != 8 THEN NULL
                    ELSE CAST(CAST(sls_ship_dt AS VARCHAR) AS DATE)
                END AS sls_ship_dt,
                CASE
                    WHEN sls_due_dt = 0 OR LEN(CAST(sls_due_dt AS VARCHAR)) != 8 THEN NULL
                    ELSE CAST(CAST(sls_due_dt AS VARCHAR) AS DATE)
                END AS sls_due_dt,
                CASE
                    WHEN sls_sales IS NULL OR sls_sales <= 0 OR sls_sales != sls_quantity * ABS(sls_price) THEN sls_quantity * ABS(sls_price)
                    ELSE sls_sales
                END AS sls_sales,
                sls_quantity,
                CASE
                    WHEN sls_price IS NULL OR sls_price <= 0 OR sls_sales != sls_quantity * ABS(sls_price) THEN ABS(sls_sales / NULLIF(sls_quantity, 0))
                    ELSE sls_price
                END AS sls_price
            FROM bronze.crm_sales_details
        ) AS src
        WHERE src.sls_order_dt > @last_order_dt;

        SET @rows = @@ROWCOUNT;
        SET @end_time = GETDATE();

        EXEC audit.sp_log_success 
            @log_id        = @log_id, 
            @rows_inserted = @rows;

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '>> -------------';

        PRINT '------------------------------';
        PRINT 'Loading ERP Tables';
        PRINT '------------------------------';

        -- ====================================================================
        -- 4. Table Load: silver.erp_cust_az12
        -- ====================================================================
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Silver',
            @procedure_name     = 'silver.load_silver',
            @target_table       = 'silver.erp_cust_az12',
            @log_id             = @log_id OUTPUT;

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.erp_cust_az12';
        TRUNCATE TABLE silver.erp_cust_az12;
        PRINT '>> Inserting Data Into: silver.erp_cust_az12';

        INSERT INTO silver.erp_cust_az12 (
            cid,
            bdate,
            gen
        )
        SELECT 
            CASE 
                WHEN cid LIKE 'NAS%' THEN SUBSTRING(cid, 4, LEN(cid)) 
                ELSE cid 
            END AS cid,
            CASE 
                WHEN bdate > GETDATE() THEN NULL 
                ELSE bdate 
            END AS bdate,
            CASE
                WHEN UPPER(TRIM(REPLACE(REPLACE(gen, CHAR(13), ''), CHAR(10), ''))) IN ('M', 'MALE') THEN 'Male'
                WHEN UPPER(TRIM(REPLACE(REPLACE(gen, CHAR(13), ''), CHAR(10), ''))) IN ('F', 'FEMALE') THEN 'Female'
                ELSE 'n/a'
            END AS gen
        FROM bronze.erp_cust_az12;

        SET @rows = @@ROWCOUNT;
        SET @end_time = GETDATE();

        EXEC audit.sp_log_success 
            @log_id        = @log_id, 
            @rows_inserted = @rows;

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '>> -------------';

        -- ====================================================================
        -- 5. Table Load: silver.erp_loc_a101
        -- ====================================================================
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Silver',
            @procedure_name     = 'silver.load_silver',
            @target_table       = 'silver.erp_loc_a101',
            @log_id             = @log_id OUTPUT;

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.erp_loc_a101';
        TRUNCATE TABLE silver.erp_loc_a101;
        PRINT '>> Inserting Data Into: silver.erp_loc_a101';

        INSERT INTO silver.erp_loc_a101 (
            cid, 
            cntry
        )
        SELECT 
            REPLACE(cid, '-', '') AS cid,
            CASE
                WHEN TRIM(UPPER(cntry)) IN ('US', 'USA') THEN 'United States'
                WHEN TRIM(UPPER(cntry)) = 'DE' THEN 'Germany'
                WHEN TRIM(cntry) = '' OR cntry IS NULL THEN 'n/a'
                ELSE TRIM(cntry)
            END AS cntry
        FROM bronze.erp_loc_a101;

        SET @rows = @@ROWCOUNT;
        SET @end_time = GETDATE();

        EXEC audit.sp_log_success 
            @log_id        = @log_id, 
            @rows_inserted = @rows;

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '>> -------------';

        -- ====================================================================
        -- 6. Table Load: silver.erp_px_cat_g1v2
        -- ====================================================================
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Silver',
            @procedure_name     = 'silver.load_silver',
            @target_table       = 'silver.erp_px_cat_g1v2',
            @log_id             = @log_id OUTPUT;

        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.erp_px_cat_g1v2';
        TRUNCATE TABLE silver.erp_px_cat_g1v2;
        PRINT '>> Inserting Data Into: silver.erp_px_cat_g1v2';

        INSERT INTO silver.erp_px_cat_g1v2 (
            id,
            cat, 
            subcat, 
            maintenance
        )
        SELECT 
            id,
            cat,
            subcat,
            maintenance
        FROM bronze.erp_px_cat_g1v2;

        SET @rows = @@ROWCOUNT;
        SET @end_time = GETDATE();

        EXEC audit.sp_log_success 
            @log_id        = @log_id, 
            @rows_inserted = @rows;

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '>> -------------';

        SET @batch_end_time = GETDATE();
        PRINT '==============================================';
        PRINT 'Silver Layer Loading Completed Successfully';
        PRINT 'Total Load Duration: ' + CAST(DATEDIFF(second, @batch_start_time, @batch_end_time) AS NVARCHAR(10)) + ' seconds';
        PRINT '==============================================';

    END TRY
    BEGIN CATCH
        -- 1. Capture error details into local variables first
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorState INT = ERROR_STATE();

        -- 2. Pass the local variables into the audit log procedure
        EXEC audit.sp_log_error
            @log_id        = @log_id,
            @error_message = @ErrorMessage,
            @error_number  = @ErrorNumber,
            @error_state   = @ErrorState;

        -- 3. Print diagnostics and rethrow
        PRINT '==========================================';
        PRINT 'ERROR OCCURRED DURING LOADING SILVER LAYER';
        PRINT '------------------------------------------';
        PRINT 'Error Message: ' + ISNULL(@ErrorMessage, 'No error message available.');
        PRINT 'Error Number:  ' + CAST(@ErrorNumber AS NVARCHAR(15));
        PRINT 'Error State:   ' + CAST(@ErrorState AS NVARCHAR(15));
        PRINT '==========================================';

        THROW;
    END CATCH
END;
GO