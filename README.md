# Iceberg Feature Platform Demo — Trino vs StarRocks

End-to-end demo that streams JSON events through Kafka into Apache Iceberg (on S3/MinIO), then queries the same data with **Trino** and **StarRocks** side by side.

```
produce-events.sh ──▶ Kafka ──▶ Kafka Connect (Iceberg Sink) ──▶ MinIO (S3)
                                        │                             │
                                   REST Catalog ◄─────────────────────┘
                                    (MySQL)
                                   ╱        ╲
                               Trino      StarRocks
```

## Prerequisites

| Requirement | Version |
|---|---|
| Docker Desktop (or Docker Engine + Compose) | 24+ recommended |
| RAM allocated to Docker | **8 GB minimum** (StarRocks alone needs ~2-4 GB) |
| python3 | 3.8+ (used by `produce-events.sh` and `benchmark.sh`) |
| curl | any (used by `register-connector.sh`) |

> **No other host dependencies.** All SQL clients run inside the containers via `docker exec`.

## Services (8 containers)

| Service | Ports | Purpose |
|---|---|---|
| **Kafka** (KRaft) | 9092 | Message broker (no ZooKeeper needed) |
| **MinIO** | 9000 (API), 9001 (Console) | S3-compatible object storage for Parquet files |
| **minio-init** | — | Creates the `warehouse` bucket, then exits |
| **MySQL** | 3306 | Persistent Iceberg catalog backend |
| **Iceberg REST Catalog** | 8181 | Apache Iceberg REST catalog server |
| **Kafka Connect** | 8083 | Iceberg sink connector (Kafka → Iceberg) |
| **Trino** | 8080 | SQL query engine (Java, widely adopted) |
| **StarRocks** | 9030 (SQL), 8030 (HTTP UI) | SQL query engine (C++ vectorized, MPP) |

## Quick Start

```bash
# 1. Clone and enter the project
git clone <repo-url> && cd fp-iceberg-demo

# 2. Create your .env file (defaults work out of the box)
cp .env.example .env

# 3. Start all services (first run pulls images + builds, ~5 min)
docker compose up -d --build

# 4. Wait for every service to be healthy
#    StarRocks takes 2-3 minutes — check with:
docker compose ps

# 5. Register the Kafka Connect Iceberg sink
./register-connector.sh

# 6. Register the StarRocks Iceberg catalog
./register-starrocks-catalog.sh

# 7. Produce sample events
./produce-events.sh 1000

# 8. Wait for the Iceberg commit (~10-30s)
sleep 30

# 9. Query from both engines
./query-iceberg.sh
```

All done — you should see the same data returned by both Trino and StarRocks.

## Benchmarking

Compare query performance between Trino and StarRocks on the same Iceberg table:

```bash
# Default: 10,000 events
./benchmark.sh

# Custom event count
./benchmark.sh 100000
```

Runs 4 queries (full scan, aggregation, filter, top-N) and reports **avg (min-max)** over 3 runs:

```
Query                                  Trino (ms)     StarRocks (ms)
-----                                  ----------     --------------
Full Scan (count)                  690 (676-710)          88 (83-95)
Aggregation (group by)             695 (686-712)          86 (82-91)
Filter (purchase > 200)            720 (710-735)          85 (80-92)
Top-N (top 10 users)               715 (700-730)          87 (83-94)
```

## Configuration

All credentials and settings are centralized in **`.env`** (copied from `.env.example`). The file is gitignored so you won't accidentally commit secrets.

| Variable | Default | Used by |
|---|---|---|
| `MINIO_ROOT_USER` | `admin` | MinIO, Iceberg REST, Kafka Connect, StarRocks catalog |
| `MINIO_ROOT_PASSWORD` | `password` | Same as above |
| `MINIO_BUCKET` | `warehouse` | minio-init, Iceberg REST, Kafka Connect |
| `MYSQL_ROOT_PASSWORD` | `password` | MySQL |
| `MYSQL_DATABASE` | `iceberg_catalog` | MySQL, Iceberg REST |
| `MYSQL_USER` / `MYSQL_PASSWORD` | `iceberg` / `iceberg` | Iceberg REST |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | `admin` / `password` | Iceberg REST, Kafka Connect |
| `AWS_REGION` | `us-east-1` | Iceberg REST, Kafka Connect |

> **Note:** The Trino catalog config (`trino/catalog/iceberg.properties`) is a static file mounted into the container. If you change S3 credentials in `.env`, update that file to match.

## Useful Commands

```bash
# Check connector health
curl -s localhost:8083/connectors/iceberg-sink/status | python3 -m json.tool

# Browse MinIO console (Parquet files under warehouse/demo/events/)
open http://localhost:9001   # login with MINIO_ROOT_USER / MINIO_ROOT_PASSWORD

# StarRocks web UI
open http://localhost:8030

# Query Trino directly
docker exec -it trino trino
# trino> SELECT count(*) FROM iceberg.demo.events;

# Query StarRocks directly
docker exec -it starrocks mysql -P 9030 -h 127.0.0.1 -u root
# mysql> SET CATALOG iceberg_catalog;
# mysql> SELECT count(*) FROM demo.events;
```

## Persistence

Iceberg data (MinIO) and catalog metadata (MySQL) are stored in Docker volumes. They survive `docker compose down` (without `-v`) and restarts:

```bash
# Restart — data survives, no need to re-register connector
docker compose down && docker compose up -d
./query-iceberg.sh   # still works
```

## Reset Everything

```bash
# Destroy containers AND all data (MinIO files + MySQL catalog)
docker compose down -v
```

## Troubleshooting

| Problem | Solution |
|---|---|
| StarRocks never becomes healthy | Increase Docker RAM to 8+ GB. Check `docker logs starrocks`. |
| `register-starrocks-catalog.sh` hangs | StarRocks FE takes 2-3 min to start. Just wait. |
| `query-iceberg.sh` returns no data | Wait 30s after producing events (Iceberg commit interval is 10s, but allow buffer). |
| Port conflict (e.g. 8080 already in use) | Change the **host** port in `docker-compose.yml` (e.g. `"18080:8080"`). |
| `produce-events.sh` fails with python error | Ensure `python3` is installed on your host (`python3 --version`). |
| Kafka Connect returns 409 on connector registration | Connector already exists — this is fine. Run `./query-iceberg.sh` to verify. |

## Project Structure

```
.
├── .env.example                  # Default configuration (copy to .env)
├── docker-compose.yml            # All 8 services
├── Dockerfile.connect            # Kafka Connect + Iceberg sink plugin
├── Dockerfile.iceberg-rest       # Iceberg REST catalog + MySQL JDBC driver
├── trino/catalog/
│   └── iceberg.properties        # Trino Iceberg catalog config
├── register-connector.sh         # Register Kafka Connect Iceberg sink
├── register-starrocks-catalog.sh # Register StarRocks Iceberg external catalog
├── produce-events.sh             # Generate random events → Kafka
├── query-iceberg.sh              # Query both engines
├── benchmark.sh                  # Timed benchmark comparison
└── README.md
```
