# 🚀 Enterprise SQL Data Warehouse & Pipeline Architecture
*A Medallion Data Warehouse Project inspired by Baraa's DW Architecture, enhanced with Incremental Watermarking, Automated Quality Suite, and Dockerised Workflows.*

---

## 📌 Executive Summary

This project demonstrates an end-to-end modern **SQL Data Warehouse** built on **Microsoft SQL Server**, implementing a 3-tier **Medallion Architecture (Bronze, Silver, Gold)**. 

While inspired by [DataWithBaraa's SQL Data Warehouse Project](https://github.com/DataWithBaraa/sql-data-warehouse-project), this repository represents a major production-oriented evolution. Key architectural enhancements include **incremental state management via dynamic watermarking**, an automated **Data Quality testing suite (`tests.run_dq_checks`)**, defensive T-SQL stored procedure orchestration, and a containerised local environment running in **Docker**.

---

## 🛠️ Key Architectural Enhancements (Beyond the Base Project)

| Architectural Feature | Original Project Baseline | My Production Enhancement |
| :--- | :--- | :--- |
| **Ingestion Pattern** | Full Truncate & Bulk Insert across all tables | **Hybrid Loading**: Full Load for lookup tables + **Incremental Watermark Ingestion** for transaction tables. |
| **Pipeline Metadata** | Basic execution logging | **`audit` Schema & State Tracking**: Maintains `audit.etl_watermark` for idempotent batch control and failure recovery. |
| **Data Quality Framework** | Manual ad-hoc queries | **Automated DQ Engine (`tests.run_dq_checks`)**: Stored procedures executing primary key, orphan, and logic validation checks. |
| **Deployment & Local Dev** | Standard SSMS local instance | **Docker Containerisation**: Fully reproducible SQL Server 2022 instance running inside Linux containers (Docker Desktop/WSL 2). |
| **Idempotency** | Basic table drops | Safe defensive compilation scripts using dynamic SQL (`EXEC()`) and transactional error handling. |

---

## 🏗️ Architecture & Data Pipeline Flow

![Pipeline Architecture](./docs/02_pipeline_architecture.jpg)

---

## 💻 Tech Stack & Tooling Mastery

Building this project provided hands-on engineering mastery across modern data tools and version control systems:

* **Database & Engine:** Microsoft SQL Server 2022 (T-SQL, Stored Procedures, Views, Dynamic SQL, Execution Plans).
* **Containerisation & OS:** **Docker Desktop** & **WSL 2 (Ubuntu)** for localised, isolated database server orchestration without host-level bloat.
* **Development Environment:** **Visual Studio Code** paired with T-SQL extensions, dark-mode workspace setup, and integrated terminal workflows.
* **Version Control:** **Git & GitHub** for branch management, commit hygiene, and structured documentation repository maintenance.

---

## 📁 Repository Structure

```text
├── docs/
│   ├── 01_data_catalogue.md       # Comprehensive Data Catalogue & Dictionary
│   └── 02_architecture_design.md   # Architectural Decisions & Pipeline Flow
├── Scripts/
│   ├── init_database.sql           # Database & Schema Initialisation (Master Script)
│   ├── bronze/                     # Bronze Raw Ingestion Stored Procedures
│   ├── silver/                     # Silver Transformation & Standardisation Procedures
│   ├── gold/                       # Gold Star Schema View/Table Creation Scripts
│   ├── audit/                      # Metadata Watermark & Audit Logging Scripts
│   └── tests/                      # Data Quality Check Suite (tests.run_dq_checks)
├── docker-compose.yml              # Local SQL Server Container Deployment Config
├── LICENSE                         # MIT License
└── README.md                       # Data Warehouse Project Documentation


### How to Initialise Database & Build Warehouse

Connect to your local SQL Server instance (`localhost,1433` | User: `sa`) and run the scripts in sequence:

```sql
-- 1. Recreates database & schemas (audit, bronze, silver, gold, tests)
Scripts/init_database.sql

-- 2. Ingests raw source data and initialises audit.etl_watermark
Scripts/bronze/proc_load_bronze.sql

-- 3. Cleanses and standardises data into Silver tables
Scripts/silver/proc_load_silver.sql

-- 4. Populates Gold star schema dimensions and fact tables
Scripts/gold/proc_load_gold.sql

-- 5. Executes the automated quality validation suite
EXEC tests.run_dq_checks;


🧪 Data Quality & Validation Engine

To ensure data reliability before downstream reporting, the pipeline includes an integrated testing procedure (tests.run_dq_checks):

• Uniqueness Constraints: Asserts zero primary key duplicates across Silver and Gold layers.
• Referential Integrity: Confirms no orphan transaction keys exist in gold.fact_sales.
• Business Rule Validation: Ensures logical temporal consistency (e.g., shipping_date >= order_date).
• Watermark Audit Integrity: Verifies audit.etl_watermark is updated correctly without time drift or skipped tables.

📌 Key Lessons & Practical Takeaways

1. Stateful Ingestion over Blanket Refreshes: Transitioning large tables from TRUNCATE AND INSERT to watermarking significantly reduced simulated load windows and network transfer volumes.

2. Defensive T-SQL Development: Using TRY...CATCH blocks, XACT_STATE() checks, and dynamic SQL (EXEC()) wrapper blocks ensures scripts compile safely and recover gracefully from runtime failures.

3. Environment Standardisation: Leveraging Docker containers ensured the entire pipeline could be built, destroyed, and rebuilt consistently without OS-level environment discrepancies.