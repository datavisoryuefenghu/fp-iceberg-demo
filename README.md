# Apache Iceberg + Kafka Connect + S3 (MinIO) Demo

End-to-end demo: JSON events flow from Kafka through the Iceberg sink connector into MinIO (S3-compatible storage), queryable via Trino and StarRocks.

```
produce-events.sh ──> Kafka ──> Kafka Connect (Iceberg Sink) ──> MinIO (S3)
                                       │                              │
                                  REST Catalog ◄──────────────────────┘
                                   (MySQL)                │
                                       │                  │
                                     Trino ───────────────┘
                                       │                  │
                                   StarRocks ─────────────┘
```

## Services (8 containers)

| Service | Port | Purpose |
|---------|------|---------|
| Kafka (KRaft) | 9092 | Message broker (no ZooKeeper) |
| MinIO | 9000, 9001 | S3-compatible object storage |
| minio-init | — | Creates `warehouse` bucket, then exits |
| MySQL | 3306 | Persistent catalog backend |
| Iceberg REST Catalog | 8181 | Table metadata catalog (JDBC/MySQL) |
| Kafka Connect | 8083 | Iceberg sink connector |
| Trino | 8080 | SQL query engine for Iceberg tables |
| StarRocks | 9030, 8030 | SQL query engine for Iceberg tables (MySQL protocol) |

## Quick Start

```bash
# 1. Start all services (first run builds custom images)
docker compose up -d --build

# 2. Wait for services to become healthy (~60s)
docker compose ps

# 3. Register the Iceberg sink connector
./register-connector.sh

# 4. Register the StarRocks Iceberg catalog (~2-3 min for StarRocks to start)
./register-starrocks-catalog.sh

# 5. Produce sample events to Kafka
./produce-events.sh

# 6. Wait ~30s for the connector commit interval
sleep 30

# 7. Query the Iceberg table via Trino and StarRocks
./query-iceberg.sh
```

## Verify

```bash
# Check connector status
curl -s localhost:8083/connectors/iceberg-sink/status | python3 -m json.tool

# Browse MinIO (Parquet files under warehouse/demo/events/)
open http://localhost:9001  # login: admin / password
```

## Verify Persistence

```bash
# Restart everything — catalog survives in MySQL
docker compose down && docker compose up -d
# Tables are still queryable without re-registering the connector
./query-iceberg.sh
```

## Benchmarking

Compare Trino and StarRocks query performance side by side:

```bash
# Run benchmark with 10000 events (default)
./benchmark.sh

# Or specify event count
./benchmark.sh 50000
```

Runs 4 queries (full scan, aggregation, filter, top-N) with best-of-3 timing.

## Cleanup

```bash
docker compose down -v
rm -rf warehouse-local/
```
