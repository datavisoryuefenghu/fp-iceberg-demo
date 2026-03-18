#!/usr/bin/env bash
set -euo pipefail

trino_query() {
  docker exec trino trino --execute "$1" 2>/dev/null
}

# Warmup: first query on each engine is slow (metadata fetch, S3 client init, Parquet cache)
echo "Warming up query engines..."
trino_query "SELECT 1 FROM iceberg.demo.event_result LIMIT 1" >/dev/null
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --batch -e "SET CATALOG iceberg_catalog; SELECT 1 FROM demo.event_result LIMIT 1;" >/dev/null 2>&1
echo ""

echo "========== Trino =========="

echo "=== Schema (columns resolved by SMT with proper types) ==="
trino_query "DESCRIBE iceberg.demo.event_result"

echo ""
echo "=== Sample rows ==="
trino_query "SELECT event_id, event_type, user_id, amount, country, is_new_user, transaction_amount FROM iceberg.demo.event_result LIMIT 5"

echo ""
echo "=== Aggregation by country ==="
trino_query "SELECT country, count(*) AS cnt, round(avg(amount), 2) AS avg_amount, round(avg(transaction_amount), 2) AS avg_txn FROM iceberg.demo.event_result GROUP BY country ORDER BY cnt DESC"

echo ""
echo "========== StarRocks =========="

echo "=== Schema ==="
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --table -e "SET CATALOG iceberg_catalog; DESCRIBE demo.event_result;"

echo ""
echo "=== Sample rows ==="
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --table -e "SET CATALOG iceberg_catalog; SELECT event_id, event_type, user_id, amount, country, is_new_user, transaction_amount FROM demo.event_result LIMIT 5;"

echo ""
echo "=== Aggregation by country ==="
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --table -e "SET CATALOG iceberg_catalog; SELECT country, count(*) AS cnt, round(avg(amount), 2) AS avg_amount, round(avg(transaction_amount), 2) AS avg_txn FROM demo.event_result GROUP BY country ORDER BY cnt DESC;"
