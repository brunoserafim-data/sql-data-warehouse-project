/*
===============================================================================
Stored Procedure: Automated Data Quality Testing Suite (Master - Silver & Gold Layers)
===============================================================================
Script Purpose:
    This script ensures the 'tests' schema exists and creates/updates 
    an automated data quality procedure that validates data integrity across 
    both the Silver and Gold layers (including cleaning rules, standardisation, 
    surrogate/natural keys, referential integrity, metrics, and chronological consistency).
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
        RAISERROR('DQ_ERROR: NULLs or duplicates found in silver.crm_cust_info.cst_id', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM silver.crm_cust_info WHERE cst_key != TRIM(cst_key))
    BEGIN
        RAISERROR('DQ_ERROR: Unwanted leading/trailing spaces found in silver.crm_cust_info.cst_key', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM silver.crm_cust_info WHERE cst_marital_status NOT IN ('Single', 'Married', 'n/a'))
    BEGIN
        RAISERROR('DQ_ERROR: Unstandardised marital status found in silver.crm_cust_info', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM silver.crm_cust_info WHERE cst_gndr NOT IN ('Male', 'Female', 'n/a'))
    BEGIN
        RAISERROR('DQ_ERROR: Unstandardised gender found in silver.crm_cust_info', 16, 1);
        RETURN;
    END

    -- --- 2. Testing 'silver.crm_prd_info' ---
    IF EXISTS (
        SELECT prd_id FROM silver.crm_prd_info GROUP BY prd_id HAVING COUNT(*) > 1 OR prd_id IS NULL
    )
    BEGIN
        RAISERROR('DQ_ERROR: NULLs or duplicates found in silver.crm_prd_info.prd_id', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM silver.crm_prd_info WHERE prd_cost < 0 OR prd_cost IS NULL)
    BEGIN
        RAISERROR('DQ_ERROR: Invalid negative or NULL costs found in silver.crm_prd_info', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM silver.crm_prd_info WHERE prd_end_dt < prd_start_dt)
    BEGIN
        RAISERROR('DQ_ERROR: Logical date error (end date before start date) in silver.crm_prd_info', 16, 1);
        RETURN;
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
        RAISERROR('DQ_ERROR: Mathematical integrity or negative metric violation in silver.crm_sales_details', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM silver.crm_sales_details WHERE sls_order_dt > sls_ship_dt OR sls_order_dt > sls_due_dt)
    BEGIN
        RAISERROR('DQ_ERROR: Chronological date violation in silver.crm_sales_details', 16, 1);
        RETURN;
    END

    -- --- 4. Testing 'silver.erp_cust_az12' ---
    IF EXISTS (SELECT 1 FROM silver.erp_cust_az12 WHERE cid LIKE 'NAS%')
    BEGIN
        RAISERROR('DQ_ERROR: Unremoved NAS prefix found in silver.erp_cust_az12.cid', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM silver.erp_cust_az12 WHERE bdate < '1924-01-01' OR bdate > GETDATE())
    BEGIN
        RAISERROR('DQ_ERROR: Out-of-range birthdate found in silver.erp_cust_az12', 16, 1);
        RETURN;
    END

    -- --- 5. Testing 'silver.erp_loc_a101' ---
    IF EXISTS (SELECT 1 FROM silver.erp_loc_a101 WHERE cid LIKE '%-%')
    BEGIN
        RAISERROR('DQ_ERROR: Unremoved hyphens found in silver.erp_loc_a101.cid', 16, 1);
        RETURN;
    END


    -- ====================================================================
    -- PART 2: GOLD LAYER DATA QUALITY CHECKS
    -- ====================================================================

    -- Check 1.1: Customer Surrogate Key Integrity
    IF EXISTS (
        SELECT customer_key FROM gold.dim_customers GROUP BY customer_key HAVING COUNT(*) > 1 OR customer_key IS NULL
    )
    BEGIN
        RAISERROR('DQ_ERROR: NULLs or duplicates found in gold.dim_customers.customer_key', 16, 1);
        RETURN;
    END

    -- Check 1.2: Customer Natural Key Integrity
    IF EXISTS (
        SELECT customer_id FROM gold.dim_customers GROUP BY customer_id HAVING COUNT(*) > 1 OR customer_id IS NULL
    )
    BEGIN
        RAISERROR('DQ_ERROR: NULLs or duplicates found in gold.dim_customers.customer_id', 16, 1);
        RETURN;
    END

    -- Check 2.1: Product Surrogate Key Integrity
    IF EXISTS (
        SELECT product_key FROM gold.dim_products GROUP BY product_key HAVING COUNT(*) > 1 OR product_key IS NULL
    )
    BEGIN
        RAISERROR('DQ_ERROR: NULLs or duplicates found in gold.dim_products.product_key', 16, 1);
        RETURN;
    END

    -- Check 2.2: Product Natural Key Integrity
    IF EXISTS (
        SELECT product_id FROM gold.dim_products GROUP BY product_id HAVING COUNT(*) > 1 OR product_id IS NULL
    )
    BEGIN
        RAISERROR('DQ_ERROR: NULLs or duplicates found in gold.dim_products.product_id', 16, 1);
        RETURN;
    END

    -- Check 3.1 & 3.2: Referential Integrity (Products & Customers)
    IF EXISTS (
        SELECT 1 FROM gold.fact_sales AS f
        LEFT JOIN gold.dim_products AS p ON f.product_key = p.product_key
        WHERE f.product_key IS NOT NULL AND p.product_key IS NULL
    )
    BEGIN
        RAISERROR('DQ_ERROR: Orphan records found in gold.fact_sales (missing product match).', 16, 1);
        RETURN;
    END

    IF EXISTS (
        SELECT 1 FROM gold.fact_sales AS f
        LEFT JOIN gold.dim_customers AS c ON f.customer_key = c.customer_key
        WHERE f.customer_key IS NOT NULL AND c.customer_key IS NULL
    )
    BEGIN
        RAISERROR('DQ_ERROR: Orphan records found in gold.fact_sales (missing customer match).', 16, 1);
        RETURN;
    END

    -- Check 3.3: Financial & Quantity Metric Integrity
    IF EXISTS (
        SELECT 1 FROM gold.fact_sales WHERE sales_amount < 0 OR quantity <= 0 OR price < 0
    )
    BEGIN
        RAISERROR('DQ_ERROR: Invalid negative or zero metrics detected in gold.fact_sales.', 16, 1);
        RETURN;
    END

    -- Check 3.4: Chronological Date Consistency
    IF EXISTS (
        SELECT 1 FROM gold.fact_sales WHERE order_date > ship_date OR order_date > due_date
    )
    BEGIN
        RAISERROR('DQ_ERROR: Chronological date violation in gold.fact_sales (order date after ship/due date).', 16, 1);
        RETURN;
    END

    PRINT '>> [SUCCESS] All Silver and Gold Layer Data Quality Checks Passed Successfully.';
END;
GO