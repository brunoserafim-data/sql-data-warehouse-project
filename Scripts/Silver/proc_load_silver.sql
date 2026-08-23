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
    TRIM(cst_firstname) AS cst_firstname,
    TRIM(cst_lastname) AS cst_lastname,
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
    WHERE cst_id IS NOT NULL -- Exclude invalid null keys
) AS t
WHERE rn = 1; -- Keep only the latest record for each cst_id