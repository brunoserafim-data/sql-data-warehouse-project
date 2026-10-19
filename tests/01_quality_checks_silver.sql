/*
===============================================================================
Data Quality Testing Suite: Silver Layer
===============================================================================
Script Purpose:
    This script executes a series of automated data quality and accuracy checks 
    against the 'silver' layer tables, validating all transformation rules 
    and expectations defined in the silver load procedure:
    - Primary key integrity (no nulls or duplicates).
    - String formatting, trimming, and prefix/hyphen removal.
    - Data standardisation and expected domain value mapping.
    - Logical date integrity (valid ranges and sequential ordering).
    - Mathematical consistency across financial and transactional metrics.

Usage:
    - Run these queries immediately after executing `EXEC silver.load_silver;`.
    - Expected outcome: All queries should return zero rows (no results).
===============================================================================
*/

-- ====================================================================
-- 1. Testing 'silver.crm_cust_info'
-- ====================================================================

-- Check 1.1: Verify no NULLs or Duplicates exist in the Customer ID primary key
-- Expectation: No Results
SELECT
    cst_id,
    COUNT(*) AS duplicate_count
FROM silver.crm_cust_info
GROUP BY cst_id
HAVING COUNT(*) > 1 OR cst_id IS NULL;

-- Check 1.2: Verify no unwanted leading or trailing spaces remain in customer keys
-- Expectation: No Results
SELECT
    cst_key
FROM silver.crm_cust_info
WHERE cst_key != TRIM(cst_key);

-- Check 1.3: Validate marital status standardisation (must only be 'Single', 'Married', or 'n/a')
-- Expectation: No Results
SELECT DISTINCT
    cst_marital_status
FROM silver.crm_cust_info
WHERE cst_marital_status NOT IN ('Single', 'Married', 'n/a');

-- Check 1.4: Validate gender standardisation (must only be 'Male', 'Female', or 'n/a')
-- Expectation: No Results
SELECT DISTINCT
    cst_gndr
FROM silver.crm_cust_info
WHERE cst_gndr NOT IN ('Male', 'Female', 'n/a');


-- ====================================================================
-- 2. Testing 'silver.crm_prd_info'
-- ====================================================================

-- Check 2.1: Verify no NULLs or Duplicates in the Product ID primary key
-- Expectation: No Results
SELECT
    prd_id,
    COUNT(*) AS duplicate_count
FROM silver.crm_prd_info
GROUP BY prd_id
HAVING COUNT(*) > 1 OR prd_id IS NULL;

-- Check 2.2: Verify no unwanted spaces in product names
-- Expectation: No Results
SELECT
    prd_nm
FROM silver.crm_prd_info
WHERE prd_nm != TRIM(prd_nm);

-- Check 2.3: Check for invalid negative costs or null cost values
-- Expectation: No Results
SELECT
    prd_cost
FROM silver.crm_prd_info
WHERE prd_cost < 0 OR prd_cost IS NULL;

-- Check 2.4: Validate product line standardisation
-- Expectation: No Results (Only allowed values or 'n/a')
SELECT DISTINCT
    prd_line
FROM silver.crm_prd_info
WHERE prd_line NOT IN ('Mountain', 'Road', 'Touring', 'Other Sales', 'n/a');

-- Check 2.5: Check for logical date errors (where start date is later than end date)
-- Expectation: No Results
SELECT
    *
FROM silver.crm_prd_info
WHERE prd_end_dt < prd_start_dt;


-- ====================================================================
-- 3. Testing 'silver.crm_sales_details'
-- ====================================================================

-- Check 3.1: Check for invalid dates in the raw source that failed parsing
-- Note: Queries bronze layer to isolate dates that were caught and converted to NULL in silver
-- Expectation: No invalid dates out of range
SELECT
    NULLIF(sls_due_dt, 0) AS sls_due_dt
FROM bronze.crm_sales_details
WHERE sls_due_dt <= 0
    OR LEN(CAST(sls_due_dt AS VARCHAR)) != 8
    OR sls_due_dt > 20500101
    OR sls_due_dt < 19000101;

-- Check 3.2: Verify chronological consistency of transactional dates (Order Date vs Ship/Due Dates)
-- Expectation: No Results
SELECT
    *
FROM silver.crm_sales_details
WHERE sls_order_dt > sls_ship_dt
   OR sls_order_dt > sls_due_dt;

-- Check 3.3: Verify mathematical integrity (Sales Amount = Quantity * Price)
-- Expectation: No Results
SELECT DISTINCT
    sls_sales,
    sls_quantity,
    sls_price
FROM silver.crm_sales_details
WHERE sls_sales != sls_quantity * sls_price
   OR sls_sales IS NULL
   OR sls_quantity IS NULL
   OR sls_price IS NULL
   OR sls_sales <= 0
   OR sls_quantity <= 0
   OR sls_price <= 0
ORDER BY sls_sales, sls_quantity, sls_price;


-- ====================================================================
-- 4. Testing 'silver.erp_cust_az12'
-- ====================================================================

-- Check 4.1: Verify 'NAS' prefix has been successfully removed from all customer IDs
-- Expectation: No Results
SELECT
    cid
FROM silver.erp_cust_az12
WHERE cid LIKE 'NAS%';

-- Check 4.2: Identify out-of-range or future birthdates
-- Expectation: No Results (Birthdates must be between 1924-01-01 and Today)
SELECT DISTINCT
    bdate
FROM silver.erp_cust_az12
WHERE bdate < '1924-01-01'
   OR bdate > GETDATE();

-- Check 4.3: Validate gender standardisation
-- Expectation: No Results
SELECT DISTINCT
    gen
FROM silver.erp_cust_az12
WHERE gen NOT IN ('Male', 'Female', 'n/a');


-- ====================================================================
-- 5. Testing 'silver.erp_loc_a101'
-- ====================================================================

-- Check 5.1: Verify all hyphens have been successfully removed from location customer IDs
-- Expectation: No Results
SELECT
    cid
FROM silver.erp_loc_a101
WHERE cid LIKE '%-%';

-- Check 5.2: Review distinct country values to confirm full standardisation
-- Expectation: Clean, fully spelled-out country names (e.g., 'United States', 'Germany')
SELECT DISTINCT
    cntry
FROM silver.erp_loc_a101
ORDER BY cntry;


-- ====================================================================
-- 6. Testing 'silver.erp_px_cat_g1v2'
-- ====================================================================

-- Check 6.1: Check for any leftover whitespace in product category hierarchies
-- Expectation: No Results
SELECT
    *
FROM silver.erp_px_cat_g1v2
WHERE cat != TRIM(cat)
   OR subcat != TRIM(subcat)
   OR maintenance != TRIM(maintenance);