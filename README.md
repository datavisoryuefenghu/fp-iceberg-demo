# Iceberg Feature Platform Demo

End-to-end demo that simulates the Feature Platform's Iceberg storage pipeline. Events with **integer-keyed feature maps** flow through Kafka, get resolved to **named columns** by a Custom SMT (reading feature metadata from MySQL), and land in Iceberg on S3 — queryable by StarRocks.

```
                          MySQL (feature table)
                          id=42 → txn_amount
                          id=57 → country
                                ↑
                          JDBC lookup (cached, refreshed every 60s)
                                │
produce-events.sh ──▶ Kafka (velocity-al) ──▶ Kafka Connect
  {"featureMap":                                  │
    {"42":100.50,                           Custom SMT
     "57":"US"}}                    (resolves integer keys → named columns)
                                                  │
                                           Iceberg Sink ──▶ MinIO (S3)
                                                  │
                                           REST Catalog (MySQL)
                                                  │
                                            StarRocks
                                   SELECT txn_amount, country
                                   FROM demo.event_result
```

## What This Proves

This demo validates the CRE-6630 Iceberg storage design:

1. **Kafka Connect + Custom SMT** can subscribe to the existing `velocity-al` topic alongside `ConsumerForCH` — zero changes to the producer
2. **Integer ID → column name resolution** works via JDBC to the existing MySQL `feature` table (cached, refreshed every 60s)
3. **Iceberg auto-creates** the table with proper columns as the SMT resolves them
4. **StarRocks** can query the Iceberg table with human-readable column names

## Prerequisites

| Requirement | Version |
|---|---|
| Docker Desktop (or Docker Engine + Compose) | 24+ recommended |
| RAM allocated to Docker | **8 GB minimum** (StarRocks alone needs ~2-4 GB) |
| python3 | 3.8+ (used by `produce-events.sh` and `benchmark.sh`) |
| curl | any (used by `register-connector.sh`) |

> **No other host dependencies.** The SMT JAR is compiled inside Docker (multi-stage build). All SQL clients run inside the containers via `docker exec`.

## Services (7 containers)

| Service | Ports | Purpose |
|---|---|---|
| **Kafka** (KRaft) | 9092 | Message broker (no ZooKeeper needed) |
| **MinIO** | 9000 (API), 9001 (Console) | S3-compatible object storage for Parquet files |
| **minio-init** | — | Creates the `warehouse` bucket, then exits |
| **MySQL** | 3306 | Iceberg catalog backend + feature metadata (id→name) |
| **Iceberg REST Catalog** | 8181 | Apache Iceberg REST catalog server |
| **Kafka Connect** | 8083 | Iceberg sink connector + Custom SMT |
| **StarRocks** | 9030 (SQL), 8030 (HTTP UI) | SQL query engine (C++ vectorized, MPP) |

## Quick Start

```bash
# 1. Clone and enter the project
git clone <repo-url> && cd fp-iceberg-demo

# 2. Create your .env file (defaults work out of the box)
cp .env.example .env

# 3. Build SMT + start all services (first run pulls images + builds, ~5 min)
docker compose up -d --build

# 4. Wait for every service to be healthy
#    StarRocks takes 2-3 minutes — check with:
docker compose ps

# 5. Register the Iceberg sink connector (with Custom SMT)
./register-connector.sh

# 6. Register the StarRocks Iceberg catalog
./register-starrocks-catalog.sh

# 7. Install AuditLoader plugin (records query metrics automatically)
./setup-audit-loader.sh

# 8. Produce sample events (integer-keyed featureMap)
./produce-events.sh 200

# 9. Wait for the Iceberg commit (~45s)
sleep 45

# 10. Query — columns are resolved!
./query-iceberg.sh

# 11. View query resource metrics
./query-audit.sh
```

Or run everything at once:
```bash
./run-demo.sh
```

## How the Custom SMT Works

The `FeatureResolverTransform` is a Kafka Connect Single Message Transform that:

1. **On startup**: queries `SELECT id, name FROM feature` in MySQL, builds an in-memory `id → name` map
2. **Every 60s**: refreshes the map (picks up new features without restart)
3. **Per message**: takes `{"featureMap": {"42": 100.50, "57": "US"}}`, looks up each integer key, outputs a flat struct with named fields `{txn_amount: "100.50", country: "US"}`
4. **Schema evolution**: if new feature IDs appear in MySQL, the SMT rebuilds its schema — Iceberg auto-adds new columns

Source: `smt/src/main/java/com/datavisor/smt/FeatureResolverTransform.java`

## Query Audit Log

Every query executed against StarRocks is automatically recorded in a native OLAP table via the **AuditLoader plugin**. This enables post-execution analysis of resource usage without any overhead on query execution.

### Setup

Installed automatically by `run-demo.sh` (step 5) or manually:

```bash
./setup-audit-loader.sh
```

Creates `starrocks_audit_db__.starrocks_audit_tbl__` and installs the plugin. Queries appear in the table within **5 seconds** (demo setting — production default is 60s).

### Query the audit table

```bash
./query-audit.sh
```

Or interactively:

```sql
-- Recent Iceberg queries with resource metrics
SELECT
    DATE_FORMAT(timestamp, '%H:%i:%S') AS time,
    queryTime                          AS wall_ms,
    scanBytes                          AS scan_bytes,
    scanRows                           AS scan_rows,
    ROUND(cpuCostNs / 1e6, 2)         AS cpu_ms,
    ROUND(memCostBytes / 1024 / 1024, 2) AS mem_mb,
    stmt                               AS query
FROM starrocks_audit_db__.starrocks_audit_tbl__
WHERE isQuery = 1
  AND catalog = 'iceberg_catalog'
ORDER BY timestamp DESC
LIMIT 20\G

-- Top queries by CPU cost
SELECT ROUND(cpuCostNs / 1e6, 2) AS cpu_ms, scanBytes, scanRows, queryTime, stmt
FROM starrocks_audit_db__.starrocks_audit_tbl__
WHERE isQuery = 1 AND catalog = 'iceberg_catalog'
ORDER BY cpuCostNs DESC LIMIT 10;

-- Failed queries
SELECT timestamp, state, errorCode, stmt
FROM starrocks_audit_db__.starrocks_audit_tbl__
WHERE state != 'EOF'
ORDER BY timestamp DESC LIMIT 10;
```

### Key fields

| Field | Description |
|---|---|
| `queryTime` | Wall time in ms (end-to-end latency) |
| `scanBytes` | Bytes actually read from S3/MinIO |
| `scanRows` | Rows scanned from Parquet files |
| `returnRows` | Rows returned to the client |
| `cpuCostNs` | CPU time in nanoseconds |
| `memCostBytes` | Memory allocated for the query |
| `state` | `EOF` = success, `ERR` = failed |
| `planCpuCosts` | Planner cost units (abstract, for plan comparison) |

### Using audit data for resource scheduling

The correlation `scanBytes → wall_ms` is stable for a given cluster. Combine with `EXPLAIN COSTS` (pre-execution, ~20ms, no S3 reads) to predict resource needs before a query runs:

```
EXPLAIN COSTS   → scan_bytes (exact, from Iceberg manifests, free)
Audit history   → k = avg(wall_ms / scan_bytes)
Predicted cost  → wall_ms = scan_bytes × k
Recommended CNs → max(1, predicted_wall_ms / target_wall_ms)
```

---

## Benchmarking

Measure StarRocks query performance on the Iceberg table:

```bash
# Default: 10,000 events
./benchmark.sh

# Custom event count
./benchmark.sh 100000
```

Runs 4 queries (full scan, aggregation, filter, top-N) and reports **avg (min-max)** over 3 runs.

> **Note on cold start:** The first query against an Iceberg external catalog is slow because StarRocks must fetch table metadata from the REST catalog, read manifest files from S3, initialize the S3 client, and parse Parquet footers. All of this is cached after the first query — subsequent queries are significantly faster. The benchmark script runs a warmup query before timing to avoid skewed results.

## Interactive SQL

```bash
# StarRocks
docker exec -it starrocks mysql -P 9030 -h 127.0.0.1 -u root
# mysql> SET CATALOG iceberg_catalog;
# mysql> SELECT * FROM demo.event_result LIMIT 5;

# MySQL (feature metadata)
docker exec -it mysql mysql -u root -ppassword iceberg_catalog
# mysql> SELECT * FROM feature;

# Read raw Kafka messages
docker exec -it kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic velocity-al --from-beginning --max-messages 3
```

## Configuration

All credentials are centralized in **`.env`** (copied from `.env.example`, gitignored).

| Variable | Default | Used by |
|---|---|---|
| `MINIO_ROOT_USER` | `admin` | MinIO, Iceberg REST, Kafka Connect, StarRocks |
| `MINIO_ROOT_PASSWORD` | `password` | Same as above |
| `MINIO_BUCKET` | `warehouse` | minio-init, Iceberg REST, Kafka Connect |
| `MYSQL_ROOT_PASSWORD` | `password` | MySQL |
| `MYSQL_DATABASE` | `iceberg_catalog` | MySQL, Iceberg REST, SMT |
| `MYSQL_USER` / `MYSQL_PASSWORD` | `iceberg` / `iceberg` | Iceberg REST, SMT |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | `admin` / `password` | Iceberg REST, Kafka Connect |
| `AWS_REGION` | `us-east-1` | Iceberg REST, Kafka Connect |

## Persistence

Iceberg data (MinIO) and catalog metadata (MySQL) are stored in Docker volumes. They survive `docker compose down` (without `-v`):

```bash
docker compose down && docker compose up -d
./query-iceberg.sh   # data still there
```

## Reset Everything

```bash
docker compose down -v
```

## Troubleshooting

| Problem | Solution |
|---|---|
| `iceberg-rest` fails on first start | Race condition with MySQL init. Run `docker compose up -d` again. |
| StarRocks never becomes healthy | Increase Docker RAM to 8+ GB. Check `docker logs starrocks`. |
| `query-iceberg.sh` returns no data | Wait 30s after producing events (Iceberg commit interval is 10s). |
| `avg()` / `sum()` fails on feature columns | Feature values are stored as `varchar`. Use `CAST(column AS double)`. |
| Port conflict on 8030/9030 | Change the **host** port in `docker-compose.yml`. |
| `produce-events.sh` fails with python error | Ensure `python3` is installed on your host (`python3 --version`). |

## Project Structure

```
.
├── .env.example                    # Default configuration (copy to .env)
├── docker-compose.yml              # All 7 services
├── Dockerfile.connect              # Multi-stage: builds SMT JAR + Kafka Connect image
├── Dockerfile.iceberg-rest         # Iceberg REST catalog + MySQL JDBC driver
├── mysql-init/
│   └── 01-feature-metadata.sql     # Seeds the feature table (id→name mappings)
├── smt/
│   ├── pom.xml                     # Maven project for the Custom SMT
│   └── src/main/java/com/datavisor/smt/
│       └── FeatureResolverTransform.java  # The SMT: MySQL JDBC → resolve IDs → named columns
├── register-connector.sh           # Register Kafka Connect sink with SMT config
├── register-starrocks-catalog.sh   # Register StarRocks Iceberg external catalog
├── setup-audit-loader.sh           # Install StarRocks AuditLoader plugin
├── produce-events.sh               # Generate events with integer-keyed featureMap
├── query-iceberg.sh                # Query Iceberg data via StarRocks
├── query-audit.sh                  # Query audit table for resource metrics
├── benchmark.sh                    # Timed StarRocks benchmark
├── run-demo.sh                     # One-command end-to-end demo (8 steps)
└── README.md
```
