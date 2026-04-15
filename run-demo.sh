#!/usr/bin/env bash
set -euo pipefail

echo "=== FP Iceberg Demo: Integer-keyed events → SMT (MySQL JDBC) → Iceberg → StarRocks ==="
echo ""

# 1. Build & start
echo "[1/8] Building SMT JAR & starting services..."
docker compose up -d --build
echo ""

# 2. Wait for health
echo "[2/8] Waiting for services to be healthy..."
for svc in kafka-connect starrocks; do
  printf "  waiting for $svc..."
  until docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null | grep -q healthy; do
    sleep 5
  done
  echo " ready"
done
echo ""

# 3. Register connector with SMT
echo "[3/8] Registering Iceberg sink connector (with Feature Resolver SMT → MySQL)..."
./register-connector.sh
echo ""

# 4. Register StarRocks catalog
echo "[4/8] Registering StarRocks Iceberg catalog..."
./register-starrocks-catalog.sh
echo ""

# 5. Install AuditLoader plugin (before queries so all are captured)
echo "[5/8] Installing StarRocks AuditLoader plugin..."
./setup-audit-loader.sh
echo ""

# 6. Produce events
echo "[6/8] Producing 200 test events..."
./produce-events.sh 200
echo "Waiting 45s for Iceberg commit..."
sleep 45
echo ""

# 7. Query
echo "[7/8] Querying via StarRocks..."
./query-iceberg.sh
echo ""

# 8. Show audit results
echo "[8/8] Query audit log — resource usage of demo queries..."
./query-audit.sh

echo ""
echo "=== Demo complete ==="
echo ""
echo "What just happened:"
echo "  1. MySQL was seeded with feature_metadata table (id→name mappings) on startup"
echo "  2. Events with integer-keyed featureMap (e.g. {\"42\": 100.50}) were sent to 'velocity-al'"
echo "  3. Custom SMT in Kafka Connect queried MySQL to resolve integer keys → named columns"
echo "  4. Iceberg Sink wrote Parquet files with human-readable column names to MinIO"
echo "  5. StarRocks can query: SELECT txn_amount, country FROM event_result"
echo "  6. AuditLoader recorded all query metrics in starrocks_audit_db__.starrocks_audit_tbl__"
echo ""
echo "Next: run ./benchmark.sh 10000 then ./query-audit.sh to see full resource metrics"
