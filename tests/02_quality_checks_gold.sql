/*
===============================================================================
Data Quality Testing Suite: Gold Layer
===============================================================================
Script Purpose:
    This script executes a series of automated data quality and accuracy checks 
    against the 'gold' layer star schema views, validating all analytical model 
    rules, referential integrity, and business expectations:
    - Surrogate key and natural key integrity (no nulls or duplicates).
    - Referential integrity and data model connectivity between fact and dimensions.
    - Financial and quantity metric validations (no negative values).
    - Logical date integrity and chronological ordering in fact tables.

Usage:
    - Run these queries immediately after refreshing or querying the Gold Layer views.
    - Expected outcome: All queries should return zero rows (no results).
===============================================================================
*/

-- ====================================================================
-- 1. Testing 'gold.dim_customers'
-- ====================================================================

-- Check 1.1: Verify no NULLs or Duplicates exist in the Customer Surrogate Key
-- Expectation: No Results
SELECT
    customer_key,
    COUNT(*) AS duplicate_count
FROM gold.dim_customers
GROUP BY customer_key
HAVING COUNT(*) > 1 OR customer_key IS NULL;

-- Check 1.2: Verify no NULLs or Duplicates exist in the Customer Natural Key (Customer ID)
-- Expectation: No Results
SELECT
    customer_id,
    COUNT(*) AS duplicate_count
FROM gold.dim_customers
GROUP BY customer_id
HAVING COUNT(*) > 1 OR customer_id IS NULL;


-- ====================================================================
-- 2. Testing 'gold.dim_products'
-- ====================================================================

-- Check 2.1: Verify no NULLs or Duplicates exist in the Product Surrogate Key
-- Expectation: No Results
SELECT
    product_key,
    COUNT(*) AS duplicate_count
FROM gold.dim_products
GROUP BY product_key
HAVING COUNT(*) > 1 OR product_key IS NULL;

-- Check 2.2: Verify no NULLs or Duplicates exist in the Product Natural Key (Product ID)
-- Expectation: No Results
SELECT
    product_id,
    COUNT(*) AS duplicate_count
FROM gold.dim_products
GROUP BY product_id
HAVING COUNT(*) > 1 OR product_id IS NULL;


-- ====================================================================
-- 3. Testing 'gold.fact_sales'
-- ====================================================================

-- Check 3.1: Check Data Model Connectivity / Referential Integrity (Products)
-- Expectation: No Results (Every sales record must resolve to a valid product dimension key)
SELECT
    f.order_number,
    f.product_key
FROM gold.fact_sales AS f
LEFT JOIN gold.dim_products AS p
    ON f.product_key = p.product_key
WHERE f.product_key IS NOT NULL AND p.product_key IS NULL;

-- Check 3.2: Check Data Model Connectivity / Referential Integrity (Customers)
-- Expectation: No Results (Every sales record must resolve to a valid customer dimension key)
SELECT
    f.order_number,
    f.customer_key
FROM gold.fact_sales AS f
LEFT JOIN gold.dim_customers AS c
    ON f.customer_key = c.customer_key
WHERE f.customer_key IS NOT NULL AND c.customer_key IS NULL;

-- Check 3.3: Verify financial and quantity metric integrity in sales facts
-- Expectation: No Results (No negative sales, or negative/zero quantities and prices)
SELECT
    order_number,
    sales_amount,
    quantity,
    price
FROM gold.fact_sales
WHERE sales_amount < 0 
   OR quantity <= 0 
   OR price < 0;

-- Check 3.4: Verify chronological consistency of transactional dates (Order Date vs Ship/Due Dates)
-- Expectation: No Results (Order dates should not occur after shipping or due dates)
SELECT
    order_number,
    order_date,
    ship_date,
    due_date
FROM gold.fact_sales
WHERE order_date > ship_date
   OR order_date > due_date;