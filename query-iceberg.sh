#!/usr/bin/env bash
set -euo pipefail

echo "=== Schema (columns resolved by SMT with proper types) ==="
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --table -e "SET CATALOG iceberg_catalog; DESCRIBE demo.event_result;"

echo ""
echo "=== Total row count ==="
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --table -e "SET CATALOG iceberg_catalog; SELECT count(*) AS total_rows FROM demo.event_result;"

echo ""
echo "=== Sample rows ==="
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --table -e "SET CATALOG iceberg_catalog; SELECT eventId, eventType, userId, eventTime, processingTime, amount, country, transaction_id, merchant_id FROM demo.event_result ORDER BY eventId LIMIT 10;"

echo ""
echo "=== Aggregation by country ==="
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --table -e "SET CATALOG iceberg_catalog; SELECT country, count(*) AS cnt, round(avg(amount), 2) AS avg_amount FROM demo.event_result GROUP BY country ORDER BY cnt DESC;"
