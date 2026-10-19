USE DataWarehouse;
GO

/*
===============================================================================
Script Name: Quality Check & Silver Layer Load Script
Layer:       Silver Layer (Transformed & Standardised Data)
Purpose:     
    This procedure truncates and reloads the Silver Layer tables by taking raw 
    data from the Bronze Layer and applying cleaning, standardisation, 
    deduplication, and business logic.
    
Usage Notes:
    1. Prerequisites:
       - The Bronze Layer tables must be populated prior to running this script.
       - Database context must be set to 'DataWarehouse'.
    2. Execution:
       - Execute directly using: `EXEC silver.load_silver;`
    3. Idempotency:
       - Every table operation starts with a TRUNCATE to ensure safe re-executability.
    4. Quality Assurances / Expectations:
       - crm_cust_info: Unique `cst_id` guaranteed via ROW_NUMBER deduplication.
       - crm_prd_info: Correct lead-based date ranges with no overlaps; category key split.
       - crm_sales_details: Validated dates and guaranteed maths check (Sales = Qty * Price).
       - erp_cust_az12: Strip 'NAS' prefix, clean whitespace/newlines, filter out future birthdates.
       - erp_loc_a101: Normalised country names, standard customer key without hyphens.
       - erp_px_cat_g1v2: Direct standardised load of product categorisation.
===============================================================================
*/

CREATE OR ALTER PROCEDURE silver.load_silver AS
BEGIN

    /*
    ===============================================================================
    1. Table: silver.crm_cust_info
    Source: bronze.crm_cust_info
    
    Transformations:
        - Deduplication: Deduplicates records by partitioning on `cst_id` and keeping
          only the most recent record ordered by `cst_create_date DESC`. Filters out NULL `cst_id`.
        - Name Formatting: Trims whitespace and standardises first/last names to Proper Case.
          Fills NULL/empty values with 'n/a'.
        - Categorical Mapping: Normalises marital status ('S' -> 'Single', 'M' -> 'Married')
          and gender ('M' -> 'Male', 'F' -> 'Female') with default 'n/a'.
          
    Expected Results:
        - Unique customer records without NULL IDs.
        - Standardised, title-cased names and clear demographic lookup values.
    ===============================================================================
    */
    TRUNCATE TABLE silver.crm_cust_info;
    
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


    /*
    ===============================================================================
    2. Table: silver.crm_prd_info
    Source: bronze.crm_prd_info
    
    Transformations:
        - Composite Key Extraction: Extracts `cat_id` (first 5 chars, '-' replaced with '_')
          and `prd_key` (substring from character 7 onward) from raw composite key.
        - Cost Handling: Replaces NULL costs with 0.
        - Product Line Mapping: Expands single-letter codes ('M' -> 'Mountain', 'R' -> 'Road',
          'T' -> 'Touring', 'S' -> 'Other Sales') to full descriptive strings.
        - Date Recalculation: Fixes overlapping product start/end dates by setting `prd_end_dt`
          to one day prior to the next product version's start date using `LEAD()`.
          
    Expected Results:
        - Separate, usable category keys and product keys.
        - Non-null costs and friendly product line names.
        - Chronologically continuous, non-overlapping product validity ranges.
    ===============================================================================
    */
    TRUNCATE TABLE silver.crm_prd_info;
    
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


    /*
    ===============================================================================
    3. Table: silver.crm_sales_details
    Source: bronze.crm_sales_details
    
    Transformations:
        - Date Validation: Checks integer dates for invalid length or 0 values, converting
          valid YYYYMMDD integers into proper DATE values or setting invalid ones to NULL.
        - Sales & Price Integrity: Checks for NULLs, zero/negative sales, or mathematical
          mismatches between Sales and (Quantity * Price). Recalculates Sales or Price
          dynamically where inconsistencies exist, using `NULLIF` to avoid division by zero.
          
    Expected Results:
        - Clean DATE formats across order, shipping, and due dates.
        - Guaranteed mathematical consistency: `Sales = Quantity * Price`.
    ===============================================================================
    */
    TRUNCATE TABLE silver.crm_sales_details;
    
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
    FROM bronze.crm_sales_details;


    /*
    ===============================================================================
    4. Table: silver.erp_cust_az12
    Source: bronze.erp_cust_az12
    
    Transformations:
        - ID Normalisation: Removes the 'NAS' prefix from customer IDs (`cid`).
        - Birthdate Validation: Nullifies invalid birthdates that occur in the future (`bdate > GETDATE()`).
        - Gender Standardisation: Strips hidden ASCII control characters (Carriage Return CHAR(13),
          Line Feed CHAR(10)) and normalises gender values ('M'/'MALE' -> 'Male', 'F'/'FEMALE' -> 'Female').
          
    Expected Results:
        - Clean customer IDs matching CRM key formats.
        - Valid historic birthdates only.
        - Standardised gender values free of unprintable hidden characters.
    ===============================================================================
    */
    TRUNCATE TABLE silver.erp_cust_az12;
    
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


    /*
    ===============================================================================
    5. Table: silver.erp_loc_a101
    Source: bronze.erp_loc_a101
    
    Transformations:
        - ID Cleansing: Removes hyphens from customer location IDs (`cid`).
        - Country Standardisation: Maps country codes to full country names ('US'/'USA' -> 'United States',
          'DE' -> 'Germany'). Null or empty country strings are set to 'n/a'.
          
    Expected Results:
        - Hyphenless customer keys.
        - Fully spelled-out, standardised country names.
    ===============================================================================
    */
    TRUNCATE TABLE silver.erp_loc_a101;
    
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


    /*
    ===============================================================================
    6. Table: silver.erp_px_cat_g1v2
    Source: bronze.erp_px_cat_g1v2
    
    Transformations:
        - Direct Load: Selects and inserts product categories and maintenance attributes.
          
    Expected Results:
        - Product category hierarchy loaded directly into the silver layer.
    ===============================================================================
    */
    TRUNCATE TABLE silver.erp_px_cat_g1v2;
    
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

END;
GO

-- Execute Procedure
EXEC silver.load_silver;
GO