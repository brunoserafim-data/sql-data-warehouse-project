/*
===============================================================================
Stored Procedure: Master Orchestration Pipeline
===============================================================================
Script Name:     run_pipeline.sql
Description:     Orchestrates the end-to-end execution of the Data Warehouse ETL 
                 pipeline by sequentially triggering Bronze and Silver load 
                 procedures, executing automated Data Quality (DQ) checks, 
                 and verifying Gold layer semantic views.

Parameters:
    None.

Usage Example:
    EXEC dbo.run_pipeline;
===============================================================================
*/

USE DataWarehouse;
GO

CREATE OR ALTER PROCEDURE dbo.run_pipeline
AS
BEGIN
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    SET NOCOUNT ON;

    DECLARE @pipeline_start_time DATETIME2 = GETDATE();
    
    PRINT '==================================================';
    PRINT 'STARTING END-TO-END DATA WAREHOUSE PIPELINE';
    PRINT 'Timestamp: ' + CAST(SYSDATETIME() AS VARCHAR(30));
    PRINT '==================================================';

    BEGIN TRY
        -- ====================================================================
        -- STEP 1: Load Bronze Layer (Raw Staging)
        -- ====================================================================
        PRINT '';
        PRINT '--------------------------------------------------';
        PRINT 'STEP 1/4: Executing Bronze Layer Ingestion';
        PRINT '--------------------------------------------------';
        
        EXEC bronze.load_bronze;
        
        PRINT '>> Bronze Layer Loaded Successfully.';

        -- ====================================================================
        -- STEP 2: Load Silver Layer (Transformation & Watermarked Delta Load)
        -- ====================================================================
        PRINT '';
        PRINT '--------------------------------------------------';
        PRINT 'STEP 2/4: Executing Silver Layer Transformation';
        PRINT '--------------------------------------------------';
        
        EXEC silver.load_silver;
        
        PRINT '>> Silver Layer Transformed Successfully.';

        -- ====================================================================
        -- STEP 3: Execute Automated Data Quality (DQ) Assertions (Fail-Fast)
        -- ====================================================================
        PRINT '';
        PRINT '--------------------------------------------------';
        PRINT 'STEP 3/4: Executing Automated Data Quality Asserts';
        PRINT '--------------------------------------------------';
        
        EXEC tests.run_dq_checks;
        
        PRINT '>> All Data Quality Checks Passed Successfully.';

        -- ====================================================================
        -- STEP 4: Verify Gold Layer Views (Analytical Star Schema)
        -- ====================================================================
        PRINT '';
        PRINT '--------------------------------------------------';
        PRINT 'STEP 4/4: Verifying Gold Layer Semantic Views';
        PRINT '--------------------------------------------------';
        
        -- Safe check: verify views exist in metadata before querying
        IF OBJECT_ID('gold.dim_customers', 'V') IS NOT NULL
            PRINT '   [OK] gold.dim_customers verified.';
        ELSE
            PRINT '   [WARNING] gold.dim_customers view does not exist!';
            
        IF OBJECT_ID('gold.dim_products', 'V') IS NOT NULL
            PRINT '   [OK] gold.dim_products verified.';
        ELSE
            PRINT '   [WARNING] gold.dim_products view does not exist!';
            
        IF OBJECT_ID('gold.fact_sales', 'V') IS NOT NULL
            PRINT '   [OK] gold.fact_sales verified.';
        ELSE
            PRINT '   [WARNING] gold.fact_sales view does not exist!';

        PRINT '>> Gold Layer Views Verification Completed.';

        -- ====================================================================
        -- PIPELINE SUCCESS SUMMARY
        -- ====================================================================
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
        PRINT '';
        PRINT '==================================================';
        PRINT 'ERROR: PIPELINE FAILED!';
        PRINT 'Error Message: ' + ERROR_MESSAGE();
        PRINT 'Error Number:  ' + CAST(ERROR_NUMBER() AS VARCHAR(10));
        PRINT '==================================================';
        
        -- Re-throw the error so calling environments/SSMS know it failed
        THROW;
    END CATCH
END;
GO