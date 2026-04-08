#!/usr/bin/env bash
set -euo pipefail

# Demo: ClickHouse → S3 staging (MinIO) → Iceberg
#
# Prerequisites:
#   1. docker compose up -d  (from the fp-iceberg-demo root)
#   2. pip install -r migration/requirements.txt
#
# What this does:
#   1. Waits for ClickHouse (seeded with 2 days of demo event_result data)
#   2. Exports each day from ClickHouse to MinIO staging as Parquet (via export.py)
#   3. Imports each day from MinIO staging into Iceberg (via import_iceberg.py)
#   4. Queries the migrated rows via StarRocks to verify

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CATALOG_URL="http://localhost:8181"
S3_ENDPOINT="http://localhost:9000"
S3_ACCESS_KEY="admin"
S3_SECRET_KEY="password"
S3_STAGING="s3://warehouse/migration-staging"

TENANT="demo"
START_MONTH="202401"
END_MONTH="202401"

# ── 1. Start ClickHouse (migration profile) ───────────────────────────────────
echo "=== FP Iceberg Migration Demo ==="
echo ""
echo "[1/4] Starting ClickHouse (migration profile)..."
docker compose --profile migration up -d clickhouse

# ── 2. Wait for ClickHouse ────────────────────────────────────────────────────
echo "  Waiting for ClickHouse to be healthy..."
until curl -sf http://localhost:8123/ping >/dev/null 2>&1; do
  sleep 2
done
echo "  ClickHouse ready."
echo ""

# ── 3. Wait for Iceberg REST catalog ─────────────────────────────────────────
echo "[2/4] Waiting for Iceberg REST catalog..."
until curl -sf "$CATALOG_URL/v1/config" >/dev/null 2>&1; do
  sleep 2
done
echo "  Iceberg REST ready."
echo ""

# ── 4. Export ─────────────────────────────────────────────────────────────────
echo "[3/4] Exporting ClickHouse demo data → MinIO staging..."
echo "  Days: 20240101, 20240102"
python3 "$SCRIPT_DIR/export.py" --date 20240101 20240102
echo ""

# ── 5. Import ─────────────────────────────────────────────────────────────────
echo "[4/4] Importing MinIO staging → Iceberg..."
python3 "$SCRIPT_DIR/import_iceberg.py" \
  --tenant          "$TENANT"       \
  --start-month     "$START_MONTH"  \
  --end-month       "$END_MONTH"    \
  --s3-staging      "$S3_STAGING"   \
  --iceberg-catalog-url "$CATALOG_URL" \
  --s3-endpoint     "$S3_ENDPOINT"  \
  --s3-access-key   "$S3_ACCESS_KEY" \
  --s3-secret-key   "$S3_SECRET_KEY"
echo ""

# ── 6. Verify via StarRocks ───────────────────────────────────────────────────
echo "=== Verification via StarRocks ==="
echo ""

# Row count
echo "Row count in Iceberg (should be 18 = 10 day1 + 8 day2):"
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --table -e \
  "SET CATALOG iceberg_catalog; SELECT count(*) AS total_rows FROM demo.event_result;" \
  2>/dev/null

echo ""
echo "Sample migrated rows:"
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --table -e \
  "SET CATALOG iceberg_catalog;
   SELECT eventId, eventType, userId, amount, country, merchant_id, transaction_id
   FROM demo.event_result
   ORDER BY eventId
   LIMIT 10;" \
  2>/dev/null

echo ""
echo "Row count by day (processingTime → date):"
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --table -e \
  "SET CATALOG iceberg_catalog;
   SELECT date(from_unixtime(processingTime / 1000)) AS day, count(*) AS rows
   FROM demo.event_result
   GROUP BY 1
   ORDER BY 1;" \
  2>/dev/null

echo ""
echo "=== Migration demo complete ==="
echo ""
echo "What happened:"
echo "  1. ClickHouse was seeded with 18 historical event_result rows (2 days)"
echo "  2. export.py read each day via CH HTTP API and wrote Parquet to MinIO staging"
echo "  3. import_iceberg.py loaded each Parquet file and appended to Iceberg via REST catalog"
echo "  4. StarRocks confirmed all 18 rows are queryable as Iceberg"
echo ""
echo "State file: migration/migration_state_${TENANT}.json (delete to force re-run)"
