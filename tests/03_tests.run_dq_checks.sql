/*
===============================================================================
Stored Procedure: Automated Data Quality Testing Suite (Master - Silver & Gold Layers)
===============================================================================
Script Purpose:
    This script ensures the 'tests' schema exists and creates/updates 
    an automated data quality procedure that validates data integrity across 
    both the Silver and Gold layers (including cleaning rules, standardisation, 
    surrogate/natural keys, referential integrity, metrics, and chronological consistency)
    and the incremental watermark logic (silver sales reconcile to the latest bronze version).
    Any failed assertion raises error 50001 (THROW), so callers and dbo.run_pipeline stop.
===============================================================================
*/

USE DataWarehouse;
GO

-- 1. Ensure the 'tests' schema exists before creating procedures in it
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'tests')
BEGIN
    EXEC('CREATE SCHEMA tests;');
END
GO

-- 2. Create or Update the Data Quality Check Procedure
CREATE OR ALTER PROCEDURE tests.run_dq_checks
AS
BEGIN
    SET NOCOUNT ON;

    PRINT '--------------------------------------------------';
    PRINT 'RUNNING AUTOMATED DATA QUALITY (DQ) ASSERTS';
    PRINT '--------------------------------------------------';

    -- ====================================================================
    -- PART 1: SILVER LAYER DATA QUALITY CHECKS
    -- ====================================================================

    -- --- 1. Testing 'silver.crm_cust_info' ---
    IF EXISTS (
        SELECT cst_id FROM silver.crm_cust_info GROUP BY cst_id HAVING COUNT(*) > 1 OR cst_id IS NULL
    )
    BEGIN
        ;THROW 50001, 'DQ_ERROR: NULLs or duplicates found in silver.crm_cust_info.cst_id', 1;
    END

    IF EXISTS (SELECT 1 FROM silver.crm_cust_info WHERE cst_key != TRIM(cst_key))
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Unwanted leading/trailing spaces found in silver.crm_cust_info.cst_key', 1;
    END

    IF EXISTS (SELECT 1 FROM silver.crm_cust_info WHERE cst_marital_status NOT IN ('Single', 'Married', 'n/a'))
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Unstandardised marital status found in silver.crm_cust_info', 1;
    END

    IF EXISTS (SELECT 1 FROM silver.crm_cust_info WHERE cst_gndr NOT IN ('Male', 'Female', 'n/a'))
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Unstandardised gender found in silver.crm_cust_info', 1;
    END

    -- --- 2. Testing 'silver.crm_prd_info' ---
    IF EXISTS (
        SELECT prd_id FROM silver.crm_prd_info GROUP BY prd_id HAVING COUNT(*) > 1 OR prd_id IS NULL
    )
    BEGIN
        ;THROW 50001, 'DQ_ERROR: NULLs or duplicates found in silver.crm_prd_info.prd_id', 1;
    END

    IF EXISTS (SELECT 1 FROM silver.crm_prd_info WHERE prd_cost < 0 OR prd_cost IS NULL)
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Invalid negative or NULL costs found in silver.crm_prd_info', 1;
    END

    IF EXISTS (SELECT 1 FROM silver.crm_prd_info WHERE prd_line NOT IN ('Mountain', 'Road', 'Touring', 'Other Sales', 'n/a'))
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Unstandardised product line found in silver.crm_prd_info', 1;
    END

    IF EXISTS (SELECT 1 FROM silver.crm_prd_info WHERE prd_end_dt < prd_start_dt)
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Logical date error (end date before start date) in silver.crm_prd_info', 1;
    END

    -- --- 3. Testing 'silver.crm_sales_details' ---
    IF EXISTS (
    SELECT 1 FROM silver.crm_sales_details 
    WHERE sls_sales IS NULL 
       OR sls_quantity IS NULL 
       OR sls_price IS NULL
       OR sls_sales != sls_quantity * sls_price 
       OR sls_sales <= 0 
       OR sls_quantity <= 0 
       OR sls_price <= 0
    )
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Mathematical integrity or negative metric violation in silver.crm_sales_details', 1;
    END

    IF EXISTS (SELECT 1 FROM silver.crm_sales_details WHERE sls_order_dt > sls_ship_dt OR sls_order_dt > sls_due_dt)
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Chronological date violation in silver.crm_sales_details', 1;
    END

    -- --- 3b. Watermark integrity: silver.crm_sales_details must match the LATEST bronze version of every key ---
    IF EXISTS (
        SELECT 1
        FROM audit.etl_watermark AS w
        WHERE w.target_table = 'silver.crm_sales_details'
          AND w.last_load_id > ISNULL((SELECT MAX(load_id) FROM bronze.crm_sales_details), 0)
    )
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Watermark for silver.crm_sales_details is ahead of bronze.crm_sales_details.load_id', 1;
    END

    IF EXISTS (
        SELECT 1
        FROM silver.crm_sales_details AS s
        WHERE s.bronze_load_id > ISNULL((SELECT w.last_load_id FROM audit.etl_watermark AS w
                                         WHERE w.target_table = 'silver.crm_sales_details'), 0)
    )
    BEGIN
        ;THROW 50001, 'DQ_ERROR: silver.crm_sales_details holds rows newer than the recorded watermark', 1;
    END

    IF EXISTS (
        SELECT 1
        FROM (SELECT sls_ord_num, sls_prd_key, MAX(load_id) AS max_load_id
                FROM bronze.crm_sales_details
               WHERE sls_ord_num IS NOT NULL AND sls_prd_key IS NOT NULL
               GROUP BY sls_ord_num, sls_prd_key) AS l
        LEFT JOIN silver.crm_sales_details AS s
                ON s.sls_ord_num = l.sls_ord_num
               AND s.sls_prd_key = l.sls_prd_key
        WHERE s.sls_ord_num IS NULL              -- key missing from silver
           OR s.bronze_load_id <> l.max_load_id  -- silver is not on the latest bronze version
    )
    BEGIN
        ;THROW 50001, 'DQ_ERROR: silver.crm_sales_details is not in sync with the latest bronze.crm_sales_details versions (watermark gap)', 1;
    END

    -- --- 4. Testing 'silver.erp_cust_az12' ---
    IF EXISTS (SELECT 1 FROM silver.erp_cust_az12 WHERE cid LIKE 'NAS%')
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Unremoved NAS prefix found in silver.erp_cust_az12.cid', 1;
    END

    IF EXISTS (SELECT 1 FROM silver.erp_cust_az12 WHERE bdate < '1924-01-01' OR bdate > GETDATE())
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Out-of-range birthdate found in silver.erp_cust_az12', 1;
    END

    IF EXISTS (SELECT 1 FROM silver.erp_cust_az12 WHERE gen NOT IN ('Male', 'Female', 'n/a'))
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Unstandardised gender found in silver.erp_cust_az12', 1;
    END

    -- --- 5. Testing 'silver.erp_loc_a101' ---
    IF EXISTS (SELECT 1 FROM silver.erp_loc_a101 WHERE cid LIKE '%-%')
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Unremoved hyphens found in silver.erp_loc_a101.cid', 1;
    END

    -- --- 6. Testing 'silver.erp_px_cat_g1v2' ---
    IF EXISTS (
        SELECT 1 FROM silver.erp_px_cat_g1v2
        WHERE cat != TRIM(CHAR(9) + CHAR(10) + CHAR(13) + ' ' FROM cat)
           OR subcat != TRIM(CHAR(9) + CHAR(10) + CHAR(13) + ' ' FROM subcat)
           OR maintenance != TRIM(CHAR(9) + CHAR(10) + CHAR(13) + ' ' FROM maintenance)
    )
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Unwanted whitespace found in silver.erp_px_cat_g1v2', 1;
    END


    -- ====================================================================
    -- PART 2: GOLD LAYER DATA QUALITY CHECKS
    -- ====================================================================

    -- Check 1.1: Customer Primary Key Integrity
    IF EXISTS (
        SELECT customer_id FROM gold.dim_customers GROUP BY customer_id HAVING COUNT(*) > 1 OR customer_id IS NULL
    )
    BEGIN
        ;THROW 50001, 'DQ_ERROR: NULLs or duplicates found in gold.dim_customers.customer_id', 1;
    END

    -- Check 2.1: Product Surrogate/Primary Key Integrity
    IF EXISTS (
        SELECT product_key FROM gold.dim_products GROUP BY product_key HAVING COUNT(*) > 1 OR product_key IS NULL
    )
    BEGIN
        ;THROW 50001, 'DQ_ERROR: NULLs or duplicates found in gold.dim_products.product_key', 1;
    END

    -- Check 3.1 & 3.2: Referential Integrity (Products & Customers)
    IF EXISTS (
        SELECT 1 FROM gold.fact_sales AS f
        LEFT JOIN gold.dim_products AS p ON f.product_key = p.product_key
        WHERE f.product_key IS NULL OR p.product_key IS NULL
    )
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Orphan records found in gold.fact_sales (missing product match).', 1;
    END

    IF EXISTS (
        SELECT 1 FROM gold.fact_sales AS f
        LEFT JOIN gold.dim_customers AS c ON f.customer_key = c.customer_key
        WHERE f.customer_key IS NULL OR c.customer_key IS NULL
    )
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Orphan records found in gold.fact_sales (missing customer match).', 1;
    END

    -- Check 3.2b: Fact grain - dimension joins must neither drop nor duplicate sales rows
    IF (SELECT COUNT(*) FROM gold.fact_sales) <> (SELECT COUNT(*) FROM silver.crm_sales_details)
    BEGIN
        ;THROW 50001, 'DQ_ERROR: gold.fact_sales row count differs from silver.crm_sales_details (join fan-out or loss).', 1;
    END

    -- Check 3.3: Financial & Quantity Metric Integrity
    IF EXISTS (
        SELECT 1 FROM gold.fact_sales WHERE sales_amount < 0 OR quantity <= 0 OR price < 0
    )
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Invalid negative or zero metrics detected in gold.fact_sales.', 1;
    END

    -- Check 3.4: Chronological Date Consistency
    IF EXISTS (
        SELECT 1 FROM gold.fact_sales WHERE order_date > ship_date OR order_date > due_date
    )
    BEGIN
        ;THROW 50001, 'DQ_ERROR: Chronological date violation in gold.fact_sales (order date after ship/due date).', 1;
    END

    PRINT '>> [SUCCESS] All Silver and Gold Layer Data Quality Checks Passed Successfully.';
END;
GO