#!/usr/bin/env bash
set -euo pipefail

NUM_EVENTS="${1:-100}"

echo "Producing $NUM_EVENTS random events to 'events' topic..."

python3 -c "
import json, random, sys

schema = {'type':'struct','fields':[
    {'field':'user_id','type':'string'},
    {'field':'event_type','type':'string'},
    {'field':'amount','type':'double'},
    {'field':'timestamp','type':'string'}
]}

user_ids = [f'u{i:03d}' for i in range(1, 21)]
event_types = (['purchase']*4 + ['refund']*2 + ['signup']*2 + ['login']*2 +
               ['logout'] + ['page_view']*3 + ['add_to_cart'] + ['checkout'])
no_amount = {'signup','login','logout','page_view'}

n = int(sys.argv[1])
out = []
for _ in range(n):
    etype = random.choice(event_types)
    amt = 0.0 if etype in no_amount else round(random.uniform(0, 499.99), 2)
    ts = f'2026-03-{random.randint(1,12):02d}T{random.randint(0,23):02d}:{random.randint(0,59):02d}:{random.randint(0,59):02d}Z'
    payload = {'user_id': random.choice(user_ids), 'event_type': etype, 'amount': amt, 'timestamp': ts}
    out.append(json.dumps({'schema': schema, 'payload': payload}, separators=(',',':')))

sys.stdout.write('\n'.join(out) + '\n')
" "$NUM_EVENTS" | docker exec -i kafka kafka-console-producer \
  --bootstrap-server localhost:9092 \
  --topic events

echo "Done. $NUM_EVENTS events produced."
