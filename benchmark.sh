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
echo "=== Trino vs StarRocks Benchmark ==="
echo "Producing $EVENT_COUNT events..."
./produce-events.sh "$EVENT_COUNT"
echo "Waiting 30s for Iceberg commit..."
sleep 30

# --- Define queries ---
declare -a QUERY_NAMES=(
  "Full Scan (count)"
  "Aggregation (group by)"
  "Filter (purchase > 200)"
  "Top-N (top 10 users)"
)

declare -a TRINO_QUERIES=(
  "SELECT count(*) FROM iceberg.demo.events"
  "SELECT event_type, count(*) AS cnt, sum(amount) AS total FROM iceberg.demo.events GROUP BY event_type"
  "SELECT * FROM iceberg.demo.events WHERE event_type = 'purchase' AND amount > 200"
  "SELECT user_id, count(*) AS cnt FROM iceberg.demo.events GROUP BY user_id ORDER BY cnt DESC LIMIT 10"
)

declare -a SR_QUERIES=(
  "SELECT count(*) FROM demo.events"
  "SELECT event_type, count(*) AS cnt, sum(amount) AS total FROM demo.events GROUP BY event_type"
  "SELECT * FROM demo.events WHERE event_type = 'purchase' AND amount > 200"
  "SELECT user_id, count(*) AS cnt FROM demo.events GROUP BY user_id ORDER BY cnt DESC LIMIT 10"
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
