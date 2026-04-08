#!/usr/bin/env bash
set -euo pipefail

echo "=== FP Iceberg Demo: Integer-keyed events → SMT (MySQL JDBC) → Iceberg → StarRocks ==="
echo ""

# 1. Build & start
echo "[1/6] Building SMT JAR & starting services..."
docker compose up -d --build
echo ""

# 2. Wait for health
echo "[2/6] Waiting for services to be healthy..."
for svc in kafka-connect starrocks; do
  printf "  waiting for $svc..."
  until docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null | grep -q healthy; do
    sleep 5
  done
  echo " ready"
done
echo ""

# 3. Register connector with SMT
echo "[3/6] Registering Iceberg sink connector (with Feature Resolver SMT → MySQL)..."
./register-connector.sh
echo ""

# 4. Register StarRocks catalog
echo "[4/6] Registering StarRocks Iceberg catalog..."
./register-starrocks-catalog.sh
echo ""

# 5. Produce events
echo "[5/6] Producing 200 test events..."
./produce-events.sh 200
echo "Waiting 30s for Iceberg commit..."
sleep 30
echo ""

# 6. Query
echo "[6/6] Querying via StarRocks..."
./query-iceberg.sh

echo ""
echo "=== Demo complete ==="
echo ""
echo "What just happened:"
echo "  1. MySQL was seeded with feature_metadata table (id→name mappings) on startup"
echo "  2. Events with integer-keyed featureMap (e.g. {\"42\": 100.50}) were sent to 'velocity-al'"
echo "  3. Custom SMT in Kafka Connect queried MySQL to resolve integer keys → named columns"
echo "  4. Iceberg Sink wrote Parquet files with human-readable column names to MinIO"
echo "  5. StarRocks can query: SELECT txn_amount, country FROM event_result"
echo ""
echo "Next: run ./benchmark.sh 10000 to benchmark StarRocks query performance"
