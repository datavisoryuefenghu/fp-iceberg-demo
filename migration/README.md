# Migration Demo — ClickHouse → Iceberg

This sub-demo tests the ClickHouse-to-Iceberg historical migration pipeline alongside the main demo stack.

## Prerequisites

**Run the main demo first.** The migration demo shares the same Docker Compose stack (MinIO, MySQL, Iceberg REST, StarRocks). Start everything from the repo root before running anything here:

```bash
# From fp-iceberg-demo/
docker compose up -d --build
./run-demo.sh          # wait for the main demo to complete and the Iceberg table to be created
```

Then install the Python dependencies for the migration scripts:

```bash
pip install -r migration/requirements.txt
```

## What This Demonstrates

The main demo shows the **live path**: events flow Kafka → Kafka Connect → Iceberg in real time.

This demo shows the **migration path**: historical data sitting in ClickHouse gets exported to S3 staging as Parquet, then imported into the same Iceberg table.

```
ClickHouse demo.event_result   (seeded on startup with 18 historical rows across 2 days)
    │  export.py  — reads via CH HTTP API (FORMAT Parquet), streams to MinIO staging
    ▼
MinIO: warehouse/migration-staging/demo/{YYYYMMDD}/data.parquet
    │  import_iceberg.py  — reads Parquet in 100k-row batches, appends to Iceberg
    ▼
Iceberg: demo.event_result  (same table the live Kafka pipeline writes to)
    │
    ▼
StarRocks / Trino  — migrated rows queryable alongside live rows
```

## Running the Migration Demo

```bash
./migration/run-migration-demo.sh
```

Expected output: 18 rows (10 from 2024-01-01, 8 from 2024-01-02) visible in StarRocks after the import.

## Files

| File | Purpose |
|---|---|
| `clickhouse-init/01-schema-and-seed.sql` | Creates `demo.event_result` in ClickHouse and seeds 18 rows across 2 days. Run automatically on container start. |
| `export.py` | Reads one day at a time from ClickHouse via HTTP API (`FORMAT Parquet`) and streams the output to MinIO staging. Mirrors what `IcebergMigrationService.exportDayToS3()` does in production FP. |
| `import_iceberg.py` | Reads each day's Parquet from MinIO and appends to Iceberg in 100k-row batches via PyIceberg REST catalog. Tracks completed days in `migration_state_demo.json` so re-runs are safe. |
| `run-migration-demo.sh` | End-to-end script: export both days, import, verify row counts via StarRocks. |

## Resumability

`import_iceberg.py` writes a state file after each completed day:

```json
{ "20240101": "DONE", "20240102": "DONE" }
```

Delete an entry (or the whole file) to force a re-import of that day.
