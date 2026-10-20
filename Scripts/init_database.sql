/*
===============================================================================
Database Initialization Script
===============================================================================
Script Name:     01_init_data_warehouse.sql
Description:     Initialises the DataWarehouse database by dropping it if it
                 exists, recreating it, and establishing the Medallion 
                 architecture schemas (bronze, silver, gold).

Usage Example:
    Execute the entire script using SQL Server Management Studio (SSMS) 
    or sqlcmd. Ensure no active connections exist to 'DataWarehouse' 
    before running.

WARNING:         Ensure there are backups before running script as all data in the 
                 database will be permanently deleted.
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
GO