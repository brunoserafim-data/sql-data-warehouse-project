/*
Running SQL Server from Docker. Bash command required to add dataset to Docker:
docker cp "F:\DWH_project\datasets" sqlserver:/var/opt/mssql/
*/

TRUNCATE TABLE bronze.crm_cust_info;
BULK INSERT bronze.crm_cust_info
FROM '/var/opt/mssql/datasets/source_crm/cust_info.csv'
WITH (
	FIRSTROW = 2,
	FIELDTERMINATOR = ',',
	TABLOCK
);
