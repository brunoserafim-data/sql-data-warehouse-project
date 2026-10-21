/*
===============================================================================
Stored Procedure: Load Silver Layer (Bronze -> Silver)
===============================================================================
Script Name:    proc_load_silver.sql
Description:    This stored procedure transforms and loads data from the 'bronze' 
                schema into the 'silver' layer tables. It performs data cleansing, 
                standardisation, deduplication, and watermarked incremental loads, 
                integrating with the central audit framework for execution telemetry.

Parameters:
    @full_refresh BIT = 0  -- 1 = rebuild silver.crm_sales_details from ALL bronze history
                           --     (resets the watermark window to start from 0).
    @batch_execution_id UNIQUEIDENTIFIER = NULL
                           -- Optional. Supplied by dbo.run_pipeline so all layers share one
                           --     batch id. A new id is generated when NULL.

Usage Example:
    EXEC silver.load_silver;
===============================================================================
*/

USE DataWarehouse;
GO

CREATE OR ALTER PROCEDURE silver.load_silver
    @full_refresh BIT = 0,   -- 1 = rebuild silver sales from ALL bronze history
    @batch_execution_id UNIQUEIDENTIFIER = NULL
AS
BEGIN
    -- Ensure consistent environment settings to prevent query hangs
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- any run-time error dooms the open transaction, so it can never be left open

    -- Declare auditing control variables
    SET @batch_execution_id = ISNULL(@batch_execution_id, NEWID());
    DECLARE @log_id INT;
    DECLARE @rows INT;

    -- Declare duration tracking variables
    DECLARE @start_time DATETIME, @end_time DATETIME, @batch_start_time DATETIME, @batch_end_time DATETIME;

    -- Declare incremental loading / watermark variables
    DECLARE @wm_low  BIGINT;   -- last bronze load_id already processed
    DECLARE @wm_high BIGINT;   -- highest bronze load_id available for this run
    DECLARE @updated INT = 0;  -- existing silver rows updated this run

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
        --    Reads only bronze rows newer than the watermark (bronze.load_id), keeps the
        --    latest version per business key, upserts into silver and advances the
        --    watermark in ONE transaction (all-or-nothing).
        -- ====================================================================
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Silver',
            @procedure_name     = 'silver.load_silver',
            @target_table       = 'silver.crm_sales_details',
            @log_id             = @log_id OUTPUT;

        SET @start_time = GETDATE();

        -- Retrieve current watermark (latest processed bronze load_id)
        SELECT @wm_low = last_load_id
          FROM audit.etl_watermark
         WHERE target_table = 'silver.crm_sales_details';

        SET @wm_low = ISNULL(@wm_low, 0);

        IF @full_refresh = 1
           OR NOT EXISTS (SELECT 1 FROM silver.crm_sales_details)
            SET @wm_low = 0;

        -- Freeze the upper bound up front so rows landing mid-run are picked up next time
        SELECT @wm_high = ISNULL(MAX(load_id), @wm_low)
          FROM bronze.crm_sales_details;

        -- Guard: if bronze history was reset (identity restarted) while the watermark persisted,
        -- the old watermark would silently skip every new row. Detect it and rebuild instead.
        IF @wm_low > 0
           AND (@wm_high < @wm_low
                OR (EXISTS (SELECT 1 FROM bronze.crm_sales_details)
                    AND NOT EXISTS (SELECT 1 FROM bronze.crm_sales_details WHERE load_id = @wm_low)))
        BEGIN
            PRINT '>> WARNING: watermark (' + CAST(@wm_low AS VARCHAR(20)) + ') is not found in bronze history; forcing a full refresh.';
            SET @full_refresh = 1;
            SET @wm_low = 0;
        END;

        PRINT '>> Incremental Load Watermark Threshold: ' + CAST(@wm_low AS VARCHAR(20)) 
            + ' < bronze.load_id <= ' + CAST(@wm_high AS VARCHAR(20));
        PRINT '>> Inserting Delta Data Into: silver.crm_sales_details';

        BEGIN TRANSACTION;

        IF @full_refresh = 1
        BEGIN
            PRINT '>> Full refresh requested: truncating silver.crm_sales_details';
            DELETE FROM silver.crm_sales_details;   -- DELETE so it can be rolled back with the rest
        END;

        -- Transform the delta; keep only the LATEST bronze version of each business key
        SELECT d.sls_ord_num,
               d.sls_prd_key,
               d.sls_cust_id,
               d.sls_order_dt,
               d.sls_ship_dt,
               d.sls_due_dt,
               d.sls_sales,
               d.sls_quantity,
               d.sls_price,
               d.load_id
          INTO #sales_delta
          FROM (SELECT b.sls_ord_num,
                       b.sls_prd_key,
                       b.sls_cust_id,
                       CASE
                           WHEN b.sls_order_dt = 0
                             OR LEN(CAST(b.sls_order_dt AS VARCHAR(20))) != 8 THEN NULL
                           ELSE TRY_CAST(CAST(b.sls_order_dt AS VARCHAR(20)) AS DATE)
                       END AS sls_order_dt,
                       CASE
                           WHEN b.sls_ship_dt = 0
                             OR LEN(CAST(b.sls_ship_dt AS VARCHAR(20))) != 8 THEN NULL
                           ELSE TRY_CAST(CAST(b.sls_ship_dt AS VARCHAR(20)) AS DATE)
                       END AS sls_ship_dt,
                       CASE
                           WHEN b.sls_due_dt = 0
                             OR LEN(CAST(b.sls_due_dt AS VARCHAR(20))) != 8 THEN NULL
                           ELSE TRY_CAST(CAST(b.sls_due_dt AS VARCHAR(20)) AS DATE)
                       END AS sls_due_dt,
                       -- Sales is rebuilt from the cleansed price, so sales = quantity * price always holds
                       CASE
                           WHEN b.sls_sales IS NULL
                             OR b.sls_sales <= 0
                             OR b.sls_sales != b.sls_quantity * p.sls_price
                                THEN b.sls_quantity * p.sls_price
                           ELSE b.sls_sales
                       END AS sls_sales,
                       b.sls_quantity,
                       p.sls_price,
                       b.load_id,
                       ROW_NUMBER() OVER (
                           PARTITION BY b.sls_ord_num, b.sls_prd_key
                           ORDER BY b.load_id DESC
                       ) AS rn
                  FROM bronze.crm_sales_details AS b
                       -- Cleansed price: derived from sales when missing or non-positive
                       CROSS APPLY (SELECT CASE
                                               WHEN b.sls_price IS NULL
                                                 OR b.sls_price <= 0
                                                    THEN ABS(b.sls_sales) / NULLIF(b.sls_quantity, 0)
                                               ELSE b.sls_price
                                           END AS sls_price) AS p
                 WHERE b.load_id >  @wm_low
                   AND b.load_id <= @wm_high
                   AND b.sls_ord_num IS NOT NULL      -- business key columns are NOT NULL in silver
                   AND b.sls_prd_key IS NOT NULL) AS d
         WHERE d.rn = 1;

        -- 3a. Update keys that already exist in silver (changed source rows)
        UPDATE t
           SET t.sls_cust_id     = d.sls_cust_id,
               t.sls_order_dt    = d.sls_order_dt,
               t.sls_ship_dt     = d.sls_ship_dt,
               t.sls_due_dt      = d.sls_due_dt,
               t.sls_sales       = d.sls_sales,
               t.sls_quantity    = d.sls_quantity,
               t.sls_price       = d.sls_price,
               t.bronze_load_id  = d.load_id,
               t.dwh_update_date = SYSDATETIME()
          FROM silver.crm_sales_details AS t
               INNER JOIN #sales_delta AS d
               ON t.sls_ord_num = d.sls_ord_num
              AND t.sls_prd_key = d.sls_prd_key;

        SET @updated = @@ROWCOUNT;

        -- 3b. Insert brand-new keys
        INSERT INTO silver.crm_sales_details
               (sls_ord_num, 
               sls_prd_key, 
               sls_cust_id,
                sls_order_dt, 
                sls_ship_dt, 
                sls_due_dt,
                sls_sales, 
                sls_quantity, 
                sls_price,
                bronze_load_id)
        SELECT d.sls_ord_num,
               d.sls_prd_key,
               d.sls_cust_id,
               d.sls_order_dt,
               d.sls_ship_dt,
               d.sls_due_dt,
               d.sls_sales,
               d.sls_quantity,
               d.sls_price,
               d.load_id
          FROM #sales_delta AS d
         WHERE NOT EXISTS
               (SELECT 1
                  FROM silver.crm_sales_details AS t
                 WHERE t.sls_ord_num = d.sls_ord_num
                   AND t.sls_prd_key = d.sls_prd_key);

        SET @rows = @@ROWCOUNT;

        -- 3c. Advance the watermark (same transaction as the data change)
        UPDATE audit.etl_watermark
           SET last_load_id  = @wm_high,
               last_run_ts   = SYSDATETIME(),
               last_batch_id = @batch_execution_id
         WHERE target_table = 'silver.crm_sales_details';

        IF @@ROWCOUNT = 0
            INSERT INTO audit.etl_watermark
                   (target_table, last_load_id, last_run_ts, last_batch_id)
            VALUES ('silver.crm_sales_details', @wm_high, SYSDATETIME(), @batch_execution_id);

        COMMIT TRANSACTION;

        DROP TABLE #sales_delta;

        SET @end_time = GETDATE();

        EXEC audit.sp_log_success 
            @log_id        = @log_id, 
            @rows_inserted = @rows;

        PRINT '>> Inserted: ' + CAST(@rows AS VARCHAR(20)) + ' | Updated: ' + CAST(@updated AS VARCHAR(20));
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
            -- Catch both future dates and impossibly old dates (< 1924-01-01)
            CASE 
                WHEN bdate < '1924-01-01' OR bdate > GETDATE() THEN NULL 
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
                WHEN TRIM(CHAR(9) + CHAR(10) + CHAR(13) + ' ' FROM UPPER(cntry)) IN ('US', 'USA') THEN 'United States'
                WHEN TRIM(CHAR(9) + CHAR(10) + CHAR(13) + ' ' FROM UPPER(cntry)) = 'DE' THEN 'Germany'
                WHEN TRIM(CHAR(9) + CHAR(10) + CHAR(13) + ' ' FROM cntry) = '' OR cntry IS NULL THEN 'n/a'
                ELSE TRIM(CHAR(9) + CHAR(10) + CHAR(13) + ' ' FROM cntry)
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
            TRIM(CHAR(9) + CHAR(10) + CHAR(13) + ' ' FROM maintenance) AS maintenance   -- last CSV column: strip stray CR from CRLF files
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
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;   -- undo partial silver sales load + watermark move

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