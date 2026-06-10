/*
==========================
Create Databse and Schemas
==========================
Script Name:    01_init_data_warehouse.sql
Description:    Initializes the DataWarehouse database by dropping it if it
                exists, recreating it, and establishing the Medallion 
                architecture schemas (Bronze, Silver, Gold).
Author:         Bruno Serafim
Date Created:   10/06/2026
Version:        1.0

WARNING:        Ensure there are backups before running script as all data in the 
                database will be permanetly deleted. 
*/

USE master;
GO

-- Drop and recreate the 'DataWarehouse' database
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'DataWarehouse')
BEGIN
	ALTER DATABASE DataWarehouse SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
	DROP DATABASE DataWarehouse
END;
GO

-- Create Database 'DataWarehouse'
CREATE DATABASE DataWarehouse;
USE DataWarehouse;
GO

-- Create Schemas
CREATE SCHEMA bronze;
GO
CREATE SCHEMA silver;
GO
CREATE SCHEMA gold;
