/*
===============================================================================
DDL Script: Create Gold Layer Views
===============================================================================
Script Name:     ddl_gold.sql
Description:     This script transforms and models cleaned data from the Silver layer 
                 into a classic Star Schema architecture consisting of two core 
                 dimensions (dim_customers, dim_products) and one transactional 
                 fact table (fact_sales) for business intelligence reporting and analytics.
===============================================================================
*/

USE DataWarehouse;
GO

-- ============================================================================
-- 1. Create Customer Dimension (gold.dim_customers)
-- Strategy: Consolidated Star Schema Dimension
-- Notes: Builds a unified customer profile by merging CRM core customer 
--        details with demographic and geographic data from ERP sources.
-- ============================================================================

IF OBJECT_ID('gold.dim_customers', 'V') IS NOT NULL
    DROP VIEW gold.dim_customers;
GO

CREATE OR ALTER VIEW gold.dim_customers AS
SELECT
       ROW_NUMBER() OVER (ORDER BY ci.cst_id) AS customer_key, -- Surrogate key
       ci.cst_id AS customer_id,
       ci.cst_key AS customer_number,
       ci.cst_firstname AS first_name,
       ci.cst_lastname AS last_name,
       el.cntry AS country,
       ci.cst_marital_status AS marital_status,
       CASE 
            WHEN ci.cst_gndr != 'n/a' THEN ci.cst_gndr -- CRM is the Master source for customer Info
            ELSE COALESCE(ec.gen, 'n/a')
       END AS gender,
       ec.bdate AS birthdate,
       ci.cst_create_date AS create_date       
FROM silver.crm_cust_info AS ci
LEFT JOIN silver.erp_cust_az12 AS ec 
ON ci.cst_key = ec.cid
LEFT JOIN silver.erp_loc_a101 AS el 
ON ci.cst_key = el.cid;

GO

-- ============================================================================
-- 2. Create Product Dimension (gold.dim_products)
-- Strategy: Consolidated Star Schema Dimension
-- Notes: Creates an enriched product catalogue view combining product 
--        specifications with category hierarchies, filtering for active items.
-- ============================================================================
IF OBJECT_ID('gold.dim_products', 'V') IS NOT NULL
    DROP VIEW gold.dim_products;
GO

CREATE OR ALTER VIEW gold.dim_products AS
SELECT
       ROW_NUMBER() OVER (ORDER BY pn.prd_start_dt, pn.prd_id) AS product_key, -- Surrogate key
       pn.prd_id AS product_id,
       pn.prd_key AS product_number,
       pn.prd_nm AS product_name,
       pn.cat_id AS category_id,
       pc.cat AS category,
       pc.subcat AS subcategory,
       pc.maintenance,
       pn.prd_cost AS cost,
       pn.prd_line AS product_line,
       pn.prd_start_dt AS start_date
FROM silver.crm_prd_info AS pn
LEFT JOIN silver.erp_px_cat_g1v2 AS pc 
ON pn.cat_id = pc.id
WHERE pn.prd_end_dt IS NULL; -- Filter for products that are still active and have no end date

GO

-- ============================================================================
-- 3. Create Sales Fact Table (gold.fact_sales)
-- Strategy: Star Schema Transactional Fact Table
-- Notes: Acts as the central transactional fact table containing business metrics 
--        (sales amounts, quantities, and prices) tied to customer and product dimensions.
-- ============================================================================
If OBJECT_ID('gold.fact_sales', 'V') IS NOT NULL
       DROP VIEW gold.fact_sales;
GO

CREATE OR ALTER VIEW gold.fact_sales AS
SELECT
    sd.sls_ord_num AS order_number,
    pr.product_key,
    cu.customer_key,
    sd.sls_order_dt AS order_date,
    sd.sls_ship_dt AS ship_date,
    sd.sls_due_dt AS due_date,
    sd.sls_sales AS sales_amount,
    sd.sls_quantity AS quantity,
    sd.sls_price AS price
FROM silver.crm_sales_details AS sd
LEFT JOIN gold.dim_products AS pr
ON sd.sls_prd_key = pr.product_number
LEFT JOIN gold.dim_customers AS cu
ON sd.sls_cust_id = cu.customer_id;

GO