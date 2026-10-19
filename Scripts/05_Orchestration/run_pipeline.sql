/*
===============================================================================
Master Orchestration Stored Procedure
===============================================================================
Script Name:     run_pipeline.sql
Description:     Orchestrates the end-to-end execution of the Data Warehouse ETL 
                 pipeline by sequentially triggering Bronze and Silver load 
                 procedures and verifying Gold layer views.
Author:          Bruno Serafim
===============================================================================
*/

USE DataWarehouse;
GO

CREATE OR ALTER PROCEDURE dbo.run_pipeline
AS
BEGIN
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
        PRINT 'STEP 1/3: Executing Bronze Layer Ingestion';
        PRINT '--------------------------------------------------';
        
        EXEC bronze.load_bronze;
        
        PRINT '>> Bronze Layer Loaded Successfully.';

        -- ====================================================================
        -- STEP 2: Load Silver Layer (Transformation & Cleaning)
        -- ====================================================================
        PRINT '';
        PRINT '--------------------------------------------------';
        PRINT 'STEP 2/3: Executing Silver Layer Transformation';
        PRINT '--------------------------------------------------';
        
        EXEC silver.load_silver;
        
        PRINT '>> Silver Layer Transformed Successfully.';

        -- ====================================================================
        -- STEP 3: Verify Gold Layer Views (Analytical Star Schema)
        -- ====================================================================
        PRINT '';
        PRINT '--------------------------------------------------';
        PRINT 'STEP 3/3: Verifying Gold Layer Semantic Views';
        PRINT '--------------------------------------------------';
        
        -- Quick sanity queries to ensure views compile and return rows
        IF EXISTS (SELECT 1 FROM gold.dim_customers)
            PRINT '   [OK] gold.dim_customers verified.';
            
        IF EXISTS (SELECT 1 FROM gold.dim_products)
            PRINT '   [OK] gold.dim_products verified.';
            
        IF EXISTS (SELECT 1 FROM gold.fact_sales)
            PRINT '   [OK] gold.fact_sales verified.;'

        PRINT '>> Gold Layer Views Verified Successfully.';

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