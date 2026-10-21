/*
===============================================================================
Stored Procedure: Master Orchestration Pipeline
===============================================================================
Script Name:     run_pipeline.sql
Description:     Orchestrates the end-to-end execution of the Data Warehouse ETL 
                 pipeline by sequentially triggering Bronze and Silver load 
                 procedures, verifying the Gold layer semantic views, and 
                 executing automated Data Quality (DQ) checks.

Parameters:
    @full_refresh BIT = 0
        1 = rebuild silver.crm_sales_details from ALL bronze history
            (passed through to silver.load_silver).

Behaviour:
    - One batch_execution_id is generated here and shared by every layer, so a
      run can be traced end to end in audit.pipeline_log.
    - An application lock stops two pipeline runs overlapping. Overlap is unsafe
      for the watermark: a bronze load that commits while silver is reading
      could be skipped permanently.

Usage Example:
    EXEC dbo.run_pipeline;
    EXEC dbo.run_pipeline @full_refresh = 1;
===============================================================================
*/

USE DataWarehouse;
GO

CREATE OR ALTER PROCEDURE dbo.run_pipeline
    @full_refresh BIT = 0
AS
BEGIN
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    SET NOCOUNT ON;

    DECLARE @pipeline_start_time DATETIME2 = GETDATE();
    DECLARE @batch_execution_id UNIQUEIDENTIFIER = NEWID();
    DECLARE @log_id INT;
    DECLARE @lock_result INT;
    DECLARE @lock_held BIT = 0;

    PRINT '==================================================';
    PRINT 'STARTING END-TO-END DATA WAREHOUSE PIPELINE';
    PRINT 'Timestamp: ' + CAST(SYSDATETIME() AS VARCHAR(30));
    PRINT '==================================================';

    BEGIN TRY
        EXEC audit.sp_log_start 
            @batch_execution_id = @batch_execution_id,
            @layer_name         = 'Orchestration',
            @procedure_name     = 'dbo.run_pipeline',
            @target_table       = NULL,
            @log_id             = @log_id OUTPUT;

        -- Prevent overlapping runs (session-level lock, released at the end or in CATCH)
        EXEC @lock_result = sys.sp_getapplock
            @Resource    = 'dwh_run_pipeline',
            @LockMode    = 'Exclusive',
            @LockOwner   = 'Session',
            @LockTimeout = 0;

        IF @lock_result < 0
            THROW 50010, 'Another pipeline run is already in progress.', 1;

        SET @lock_held = 1;

        -- ====================================================================
        -- STEP 1: Load Bronze Layer (Raw Staging)
        -- ====================================================================
        PRINT '';
        PRINT '--------------------------------------------------';
        PRINT 'STEP 1/4: Executing Bronze Layer Ingestion';
        PRINT '--------------------------------------------------';
        
        EXEC bronze.load_bronze @batch_execution_id = @batch_execution_id;
        
        PRINT '>> Bronze Layer Loaded Successfully.';

        -- ====================================================================
        -- STEP 2: Load Silver Layer (Transformation & Watermarked Delta Load)
        -- ====================================================================
        PRINT '';
        PRINT '--------------------------------------------------';
        PRINT 'STEP 2/4: Executing Silver Layer Transformation';
        PRINT '--------------------------------------------------';
        
        EXEC silver.load_silver 
            @full_refresh       = @full_refresh,
            @batch_execution_id = @batch_execution_id;
        
        PRINT '>> Silver Layer Transformed Successfully.';

        -- ====================================================================
        -- STEP 3: Verify Gold Layer Views (Analytical Star Schema)
        --         Runs before the DQ checks because those query the Gold views.
        -- ====================================================================
        PRINT '';
        PRINT '--------------------------------------------------';
        PRINT 'STEP 3/4: Verifying Gold Layer Semantic Views';
        PRINT '--------------------------------------------------';
        
        IF OBJECT_ID('gold.dim_customers', 'V') IS NULL
            THROW 50011, 'Gold view gold.dim_customers does not exist. Run Scripts/03_Gold/ddl_gold.sql.', 1;
        PRINT '   [OK] gold.dim_customers verified.';

        IF OBJECT_ID('gold.dim_products', 'V') IS NULL
            THROW 50011, 'Gold view gold.dim_products does not exist. Run Scripts/03_Gold/ddl_gold.sql.', 1;
        PRINT '   [OK] gold.dim_products verified.';

        IF OBJECT_ID('gold.fact_sales', 'V') IS NULL
            THROW 50011, 'Gold view gold.fact_sales does not exist. Run Scripts/03_Gold/ddl_gold.sql.', 1;
        PRINT '   [OK] gold.fact_sales verified.';

        PRINT '>> Gold Layer Views Verification Completed.';

        -- ====================================================================
        -- STEP 4: Execute Automated Data Quality (DQ) Assertions (Fail-Fast)
        -- ====================================================================
        PRINT '';
        PRINT '--------------------------------------------------';
        PRINT 'STEP 4/4: Executing Automated Data Quality Asserts';
        PRINT '--------------------------------------------------';
        
        EXEC tests.run_dq_checks;
        
        PRINT '>> All Data Quality Checks Passed Successfully.';

        -- ====================================================================
        -- PIPELINE SUCCESS SUMMARY
        -- ====================================================================
        EXEC audit.sp_log_success @log_id = @log_id, @rows_inserted = NULL;

        EXEC sys.sp_releaseapplock @Resource = 'dwh_run_pipeline', @LockOwner = 'Session';
        SET @lock_held = 0;

        PRINT '';
        PRINT '==================================================';
        PRINT 'PIPELINE COMPLETED SUCCESSFULLY!';
        PRINT 'Total Duration: ' + CAST(DATEDIFF(second, @pipeline_start_time, GETDATE()) AS VARCHAR(10)) + ' seconds.';
        PRINT '==================================================';

    END TRY
    BEGIN CATCH
        -- ====================================================================
        -- PIPELINE ERROR HANDLING
        -- ====================================================================
        -- Capture error details first: later statements would overwrite them
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorState INT = ERROR_STATE();

        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        IF @lock_held = 1
            EXEC sys.sp_releaseapplock @Resource = 'dwh_run_pipeline', @LockOwner = 'Session';

        EXEC audit.sp_log_error
            @log_id        = @log_id,
            @error_message = @ErrorMessage,
            @error_number  = @ErrorNumber,
            @error_state   = @ErrorState;

        PRINT '';
        PRINT '==================================================';
        PRINT 'ERROR: PIPELINE FAILED!';
        PRINT 'Error Message: ' + ISNULL(@ErrorMessage, 'No error message available.');
        PRINT 'Error Number:  ' + CAST(@ErrorNumber AS VARCHAR(10));
        PRINT '==================================================';
        
        -- Re-throw the error so calling environments/SSMS know it failed
        THROW;
    END CATCH
END;
GO
