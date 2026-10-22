/*
===============================================================================
Database Initialisation Script
===============================================================================
Script Name:     init_database.sql
Description:     Initialises the DataWarehouse database by dropping it if it
                 exists, recreating it, and establishing the Medallion 
                 architecture schemas (bronze, silver, gold).

Purpose:         FIRST-TIME SETUP OR DELIBERATE FULL RESET ONLY.
                 Drops and recreates the DataWarehouse database.

WARNING:         This permanently deletes ALL data, including the append-only
                 bronze.crm_sales_details history, audit.pipeline_log and
                 audit.etl_watermark. The incremental load state is reset
                 together with the data.
                 For routine refreshes use: EXEC dbo.run_pipeline;
                 To redeploy a single layer without losing state, re-run that
                 layer's DDL and procedure scripts instead (not this script).
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