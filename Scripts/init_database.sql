/*
===============================================================================
Database Initialisation Script
===============================================================================
Script Name:     init_database.sql
Description:     Initialises the DataWarehouse database by dropping it if it
                 exists, recreating it, and establishing the Medallion 
                 architecture schemas (bronze, silver, gold).

Usage Example:
    Execute the entire script using SQL Server Management Studio (SSMS) 
    or sqlcmd. Ensure no active connections exist to 'DataWarehouse' 
    before running.

WARNING:         Ensure there are backups before running script as all data in the 
                 database will be permanently deleted. This includes the append-only
                 bronze.crm_sales_details history and audit.etl_watermark, so the
                 incremental load state is reset together with the data.
===============================================================================
*/

USE master;
GO

-- Drop and recreate the 'DataWarehouse' database safely
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'DataWarehouse')
BEGIN
    ALTER DATABASE DataWarehouse SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DataWarehouse;
END;
GO

-- Create Database 'DataWarehouse'
CREATE DATABASE DataWarehouse;
GO

USE DataWarehouse;
GO

-- Create Schemas Safely
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'bronze')
BEGIN
    EXEC('CREATE SCHEMA bronze;');
END;
GO

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'silver')
BEGIN
    EXEC('CREATE SCHEMA silver;');
END;
GO

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'gold')
BEGIN
    EXEC('CREATE SCHEMA gold;');
END;