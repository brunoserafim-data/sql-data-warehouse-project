# SQL Data Warehouse and Pipeline (SQL Server, Medallion Architecture)

*A medallion data warehouse built on Microsoft SQL Server, based on
[DataWithBaraa's SQL Data Warehouse Project](https://github.com/DataWithBaraa/sql-data-warehouse-project)
and extended with incremental loading, an audit framework, an orchestration procedure and an automated data quality suite.*

---

## Summary

This project consolidates CRM and ERP flat files into a single analytical model using a three-layer
**medallion architecture** (Bronze, Silver, Gold) on Microsoft SQL Server 2022.

### Credit to the base project

The following originate from Baraa's project and are used here under its MIT licence:

- the six source CSV files in `datasets/`
- the Bronze / Silver / Gold layering and the overall table design
- the Gold star-schema views and most of the cleansing rules
- the original standalone quality-check scripts in `tests/`

### What this repository adds

| Area | Base project | This project |
| :--- | :--- | :--- |
| Sales ingestion | Truncate and bulk insert | CSV is staged, then **new or changed rows are appended** to an append-only history table using a row hash. |
| Silver sales load | Truncate and reload | **Watermark-driven upsert** on the Bronze `load_id`, committed in the same transaction as the watermark update. |
| Pipeline metadata | `PRINT`-based timings | `audit.pipeline_log` (per-table status, row counts, errors) and `audit.etl_watermark`. |
| Orchestration | Run scripts manually | `dbo.run_pipeline` runs Bronze, Silver, a Gold check and the DQ suite under one batch ID, with an application lock against overlapping runs. |
| Data quality | Standalone check scripts | Standalone scripts **plus** `tests.run_dq_checks`, which raises an error on any failed assertion, including watermark reconciliation. |

Only `bronze.crm_sales_details` and `silver.crm_sales_details` use the incremental pattern. The other tables are fully reloaded on every run.

---

## Architecture

![Pipeline Architecture](docs/02_pipeline_architecture.jpg)

- **Bronze:** raw data loaded from CSV with `BULK INSERT`. Sales are staged (`bronze.crm_sales_details_stg`) and appended to a history table.
- **Silver:** cleansed and standardised tables. Sales are upserted incrementally; all other tables are truncated and reloaded.
- **Gold:** star-schema **views** (`gold.dim_customers`, `gold.dim_products`, `gold.fact_sales`) over Silver.

> **Scope note:** the model reflects the latest state of the data. Bronze retains versions of changed sales rows for change detection, but Gold does not provide historical (slowly changing dimension) analysis.

---

## Tech Stack

- **Database:** Microsoft SQL Server 2022 (T-SQL, stored procedures, views)
- **Runtime:** SQL Server in a Linux container (Docker Desktop with WSL 2)
- **Tooling:** Visual Studio Code with a T-SQL extension, Git and GitHub

---

## Repository Structure

```
├── datasets/
│   ├── source_crm/                  # cust_info, prd_info, sales_details
│   └── source_erp/                  # CUST_AZ12, LOC_A101, PX_CAT_G1V2
├── docs/
│   ├── 01_data_catalogue.md         # Data catalogue
│   └── 02_pipeline_architecture.jpg # Pipeline diagram
├── Scripts/
│   ├── init_database.sql            # Drops and recreates DataWarehouse; creates bronze, silver, gold schemas
│   ├── 01_Bronze/                   # ddl.bronze.sql, proc_load_bronze.sql
│   ├── 02_Silver/                   # ddl_silver.sql, proc_load_silver.sql
│   ├── 03_Gold/                     # ddl_gold.sql (views)
│   ├── 04_audit/                    # audit schema, pipeline log, watermark table
│   └── 05_Orchestration/            # run_pipeline.sql
├── tests/                           # Standalone quality checks and tests.run_dq_checks
├── .gitattributes
├── .gitignore
├── LICENSE                          # MIT licence (original and derivative copyright)
└── README.md
```

---

## Setup and Run Order

Source files are read from `/var/opt/mssql/datasets/` on the SQL Server host. For a Docker container named `sqlserver`:

```bash
docker cp ./datasets sqlserver:/var/opt/mssql/
```

File names are case-sensitive on Linux (for example `CUST_AZ12.csv`).

Connect to your SQL Server instance (for example `localhost,1433`) and run the scripts **in this order**:

| Step | Script | Purpose |
| :-: | :--- | :--- |
| 1 | `Scripts/init_database.sql` | **Destructive reset:** drops and recreates `DataWarehouse` and the bronze, silver and gold schemas. |
| 2 | `Scripts/04_audit/01_ddl_audit.sql` | Creates the `audit` schema, `audit.pipeline_log` and logging procedures. |
| 3 | `Scripts/04_audit/02_audit.etl_watermark.sql` | Creates `audit.etl_watermark`. |
| 4 | `Scripts/01_Bronze/ddl.bronze.sql` | Creates Bronze tables. |
| 5 | `Scripts/01_Bronze/proc_load_bronze.sql` | Creates `bronze.load_bronze`. |
| 6 | `Scripts/02_Silver/ddl_silver.sql` | Creates Silver tables. |
| 7 | `Scripts/02_Silver/proc_load_silver.sql` | Creates `silver.load_silver`. |
| 8 | `Scripts/03_Gold/ddl_gold.sql` | Creates Gold views. |
| 9 | `tests/03_tests.run_dq_checks.sql` | Creates the `tests` schema and `tests.run_dq_checks`. |
| 10 | `Scripts/05_Orchestration/run_pipeline.sql` | Creates `dbo.run_pipeline`. |

Only run init_database.sql for first-time set up or deliberate full reset. Then run the pipeline:

```sql
EXEC dbo.run_pipeline;                      -- normal run
EXEC dbo.run_pipeline @full_refresh = 1;    -- rebuild Silver sales from all Bronze history
```

To run the data quality suite on its own: `EXEC tests.run_dq_checks;`

> Re-running `init_database.sql` deletes everything, including the sales history and watermark. To redeploy individual layers without losing state, run only the relevant DDL and procedure scripts.

---

## Data Quality Suite

`tests.run_dq_checks` raises error 50001 on the first failed assertion. It covers:

- **Keys and uniqueness:** no `NULL` or duplicate keys in `silver.crm_cust_info`, `silver.crm_prd_info`, `gold.dim_customers` and `gold.dim_products`.
- **Standardisation:** permitted values for gender, marital status and product line; no unwanted whitespace, prefixes or hyphens in ERP identifiers.
- **Business rules:** sales equals quantity multiplied by price; positive metrics; order date not after ship or due date; birthdate range.
- **Referential integrity:** no orphan customer or product keys in `gold.fact_sales`, and fact row count equal to Silver sales.
- **Watermark reconciliation:** the watermark is not ahead of Bronze, Silver holds nothing newer than the watermark, and Silver sales match the latest Bronze version of every business key.

Because Gold objects are views, a failed check stops the pipeline but does not withdraw data that has already been loaded into Silver.

The standalone scripts `tests/01_quality_checks_silver.sql` and `tests/02_quality_checks_gold.sql` return rows only where a check is violated.

---

## Known Limitations

- Source deletions are not propagated; removed orders remain in Bronze history and Silver.
- Bronze sales history grows with every changed row and has no retention policy.
- Gold surrogate keys are generated with `ROW_NUMBER()` in views and are not stable across data changes.
- Gold is not materialised, and no analytics or dashboards are included.
- The pipeline is run manually; there is no scheduler. Paths and credentials are intended for local development only.

---

## Lessons Learned

1. **Incremental design:** comparing row hashes against the latest stored version, and advancing a watermark in the same transaction as the data change, makes reruns safe. The full CSV is still read on each run, so no performance gain has been measured.
2. **Defensive T-SQL:** `TRY…CATCH`, `XACT_ABORT`, rollback on failure and error logging to an audit table make failures traceable.
3. **Reproducible environments:** a containerised SQL Server instance can be rebuilt consistently without host-level configuration.

---

## Licence

Released under the MIT Licence. This project is derived from work by Baraa Khatib Salkini; see `LICENSE` for both copyright notices.
