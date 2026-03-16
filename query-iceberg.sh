#!/usr/bin/env bash
set -euo pipefail

echo "========== Trino =========="

echo "=== All events ==="
docker exec trino trino --execute "SELECT * FROM iceberg.demo.events"

echo ""
echo "=== Aggregated by event_type ==="
docker exec trino trino --execute "SELECT event_type, count(*) AS cnt, sum(amount) AS total_amount FROM iceberg.demo.events GROUP BY event_type"

echo ""
echo "========== StarRocks =========="

echo "=== All events ==="
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --batch -e "SET CATALOG iceberg_catalog; SELECT * FROM demo.events;"

echo ""
echo "=== Aggregated by event_type ==="
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --batch -e "SET CATALOG iceberg_catalog; SELECT event_type, count(*) AS cnt, sum(amount) AS total_amount FROM demo.events GROUP BY event_type;"
