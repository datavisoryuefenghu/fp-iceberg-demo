#!/usr/bin/env bash
set -euo pipefail

EVENT_COUNT="${1:-10000}"
RUNS=3

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

run_trino() {
  docker exec trino trino --execute "$1" >/dev/null 2>&1
}

run_starrocks() {
  docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --batch -e "SET CATALOG iceberg_catalog; $1" >/dev/null 2>&1
}

# Returns "avg min max" in ms over $RUNS runs
bench() {
  local engine="$1" query="$2"
  local total=0 min=999999999 max=0
  for ((i = 1; i <= RUNS; i++)); do
    local start end elapsed
    start=$(now_ms)
    if [[ "$engine" == "trino" ]]; then
      run_trino "$query"
    else
      run_starrocks "$query"
    fi
    end=$(now_ms)
    elapsed=$(( end - start ))
    total=$(( total + elapsed ))
    (( elapsed < min )) && min=$elapsed
    (( elapsed > max )) && max=$elapsed
  done
  local avg=$(( total / RUNS ))
  echo "$avg $min $max"
}

# --- Produce events ---
echo "=== Trino vs StarRocks Benchmark (event_result with resolved features) ==="
echo "Producing $EVENT_COUNT events..."
./produce-events.sh "$EVENT_COUNT"
echo "Waiting 30s for Iceberg commit..."
sleep 30

# --- Warmup (cold start: metadata fetch, S3 client init, Parquet footer parse) ---
echo "Warming up engines (first query is slow due to metadata/S3 cache cold start)..."
run_trino "SELECT count(*) FROM iceberg.demo.event_result"
run_starrocks "SELECT count(*) FROM demo.event_result"
echo "Warmup complete."
echo ""

# --- Define queries ---
declare -a QUERY_NAMES=(
  "Full Scan (count)"
  "Aggregation (by country)"
  "Filter (new user + high txn)"
  "Top-N (top 10 users by txn)"
)

declare -a TRINO_QUERIES=(
  "SELECT count(*) FROM iceberg.demo.event_result"
  "SELECT country, count(*) AS cnt, sum(amount) AS total FROM iceberg.demo.event_result GROUP BY country"
  "SELECT * FROM iceberg.demo.event_result WHERE is_new_user = true AND transaction_amount > 5000"
  "SELECT user_id, count(*) AS cnt, sum(transaction_amount) AS total FROM iceberg.demo.event_result GROUP BY user_id ORDER BY total DESC LIMIT 10"
)

declare -a SR_QUERIES=(
  "SELECT count(*) FROM demo.event_result"
  "SELECT country, count(*) AS cnt, sum(amount) AS total FROM demo.event_result GROUP BY country"
  "SELECT * FROM demo.event_result WHERE is_new_user = true AND transaction_amount > 5000"
  "SELECT user_id, count(*) AS cnt, sum(transaction_amount) AS total FROM demo.event_result GROUP BY user_id ORDER BY total DESC LIMIT 10"
)

# --- Run benchmarks ---
echo ""
printf "%-30s %20s %20s\n" "Query" "Trino (ms)" "StarRocks (ms)"
printf "%-30s %20s %20s\n" "-----" "----------" "--------------"

for i in "${!QUERY_NAMES[@]}"; do
  name="${QUERY_NAMES[$i]}"
  read -r t_avg t_min t_max <<< "$(bench "trino" "${TRINO_QUERIES[$i]}")"
  read -r s_avg s_min s_max <<< "$(bench "starrocks" "${SR_QUERIES[$i]}")"
  printf "%-30s %20s %20s\n" "$name" "$t_avg ($t_min-$t_max)" "$s_avg ($s_min-$s_max)"
done

echo ""
echo "Avg (min-max) over $RUNS runs. Events: $EVENT_COUNT."
