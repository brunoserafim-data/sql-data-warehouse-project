/*
===============================================================================
Framework: Centralised Logging and Audit Framework
Layer:     Audit / Cross-Layer Infrastructure
Purpose:   
    This script establishes a robust logging and auditing mechanism for the 
    Data Warehouse. It includes:
    - An audit schema and tracking table (`audit.pipeline_log`) to record 
      execution history, durations, row counts, and error diagnostics.
    - Helper procedures to log execution milestones: start, success, and failure.

Usage:
    - Run this script once to set up the audit framework infrastructure.
    - Safe to re-run: audit.pipeline_log is never dropped, so execution history
      (and the batch ids referenced by audit.etl_watermark) survives redeploys.
    - Integrate the logging calls within your ETL stored procedures.
===============================================================================
*/

USE DataWarehouse;
GO

-- ============================================================================
-- 1. Create Audit Schema
-- ============================================================================
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'audit')
BEGIN
    EXEC('CREATE SCHEMA audit;');
END;
GO

-- ============================================================================
-- 2. Create Central Audit Log Table
-- ============================================================================
IF OBJECT_ID('audit.pipeline_log', 'U') IS NULL
BEGIN
    CREATE TABLE audit.pipeline_log (
        log_id            INT IDENTITY(1,1) PRIMARY KEY,
        batch_execution_id UNIQUEIDENTIFIER NOT NULL,
        layer_name        NVARCHAR(50)      NOT NULL, -- e.g., 'Bronze', 'Silver', 'Orchestration'
        procedure_name    NVARCHAR(128)     NOT NULL, -- e.g., 'silver.load_silver'
        target_table      NVARCHAR(128)     NULL,     -- e.g., 'silver.crm_cust_info'
        status            NVARCHAR(20)      NOT NULL, -- 'RUNNING', 'SUCCESS', 'FAILED'
        rows_inserted     INT               NULL,     -- Row count affected/inserted
        start_time        DATETIME2         NOT NULL,
        end_time          DATETIME2         NULL,
        duration_seconds  INT               NULL,     -- Execution time in seconds
        error_message     NVARCHAR(4000)    NULL,     -- Captured error message
        error_number      INT               NULL,     -- SQL error number
        error_state       INT               NULL      -- SQL error state
    );
END;
GO

-- ============================================================================
-- 3. Helper Procedure: Log Pipeline Start
-- ============================================================================
CREATE OR ALTER PROCEDURE audit.sp_log_start
    @batch_execution_id UNIQUEIDENTIFIER,
    @layer_name        NVARCHAR(50),
    @procedure_name    NVARCHAR(128),
    @target_table      NVARCHAR(128) = NULL,
    @log_id            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO audit.pipeline_log (
        batch_execution_id,
        layer_name,
        procedure_name,
        target_table,
        status,
        start_time
    )
    VALUES (
        @batch_execution_id,
        @layer_name,
        @procedure_name,
        @target_table,
        'RUNNING',
        GETDATE()
    );

    -- Capture the identity of the newly created log entry
    SET @log_id = SCOPE_IDENTITY();
END;
GO

-- ============================================================================
-- 4. Helper Procedure: Log Pipeline Success
-- ============================================================================
CREATE OR ALTER PROCEDURE audit.sp_log_success
    @log_id        INT,
    @rows_inserted INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @end_time DATETIME2 = GETDATE();

    UPDATE audit.pipeline_log
    SET 
        status           = 'SUCCESS',
        rows_inserted    = @rows_inserted,
        end_time         = @end_time,
        duration_seconds = DATEDIFF(second, start_time, @end_time)
    WHERE log_id = @log_id;
END;
GO

-- ============================================================================
-- 5. Helper Procedure: Log Pipeline Failure
-- ============================================================================
CREATE OR ALTER PROCEDURE audit.sp_log_error
    @log_id        INT,
    @error_message NVARCHAR(4000),
    @error_number  INT,
    @error_state   INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @end_time DATETIME2 = GETDATE();

    UPDATE audit.pipeline_log
    SET 
        status           = 'FAILED',
        end_time         = @end_time,
        duration_seconds = DATEDIFF(second, start_time, @end_time),
        error_message    = @error_message,
        error_number     = @error_number,
        error_state      = @error_state
    WHERE log_id = @log_id;
END;
GO