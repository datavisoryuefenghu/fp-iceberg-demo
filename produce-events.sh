#!/usr/bin/env bash
set -euo pipefail

NUM_EVENTS="${1:-100}"

echo "Producing $NUM_EVENTS events to 'velocity-al' topic..."

python3 -c "
import json, random, sys, time

# Feature IDs matching mysql-init/01-feature-metadata.sql
# id → (return_type, value_generator)
event_types = ['purchase', 'refund', 'signup', 'login', 'logout', 'page_view', 'checkout']
countries = ['US', 'CA', 'GB', 'DE', 'JP', 'AU', 'BR', 'IN']
emails = ['alice@gmail.com', 'bob@yahoo.com', 'carol@outlook.com', 'dave@company.com']
devices = ['dev_001', 'dev_002', 'dev_003', 'dev_004', 'dev_005']
merchants = ['m_electronics', 'm_grocery', 'm_travel', 'm_gaming', 'm_clothing']
cards = ['4111111111111111', '4242424242424242', '5555555555554444']
user_ids = [f'u{i:03d}' for i in range(1, 51)]

n = int(sys.argv[1])
base_time = int(time.time() * 1000)
out = []

for i in range(n):
    uid = random.choice(user_ids)
    etype = random.choice(event_types)
    evt_time = base_time - random.randint(0, 86400000)
    proc_time = evt_time + random.randint(1, 50)
    amount = round(random.uniform(0, 999.99), 2)
    country = random.choice(countries)
    txn_id = f'txn_{i:06d}'
    merchant = random.choice(merchants)
    card = random.choice(cards)
    direction = random.choice(['DEBIT', 'CREDIT'])
    category = random.choice(['electronics', 'grocery', 'travel', 'gaming', 'clothing'])

    # featureMap with integer keys matching the feature table
    feature_map = {
        '1':   evt_time,                                    # time (Long)
        '7':   country,                                     # country (String)
        '8':   amount,                                      # amount (Double)
        '9':   uid,                                         # user_id (String)
        '13':  etype,                                       # event_type (String)
        '34':  random.choice([True, False]),                 # is_new_user (Boolean)
        '35':  random.choice(emails),                       # email (String)
        '40':  round(random.uniform(50.0, 200.0), 2),       # weight (Double)
        '90':  f'{random.randint(1,255)}.{random.randint(0,255)}.{random.randint(0,255)}.{random.randint(1,254)}',  # ip (String)
        '108': random.choice(devices),                      # device_id (String)
        '476': round(random.uniform(0, 9999.99), 2),        # transaction_amount (Double)
    }

    # Randomly include optional features
    if random.random() > 0.3:
        feature_map['6'] = random.randint(0, 2)             # gender (Integer)
    if random.random() > 0.3:
        feature_map['39'] = round(random.uniform(0, 1.0), 4)  # float_feature (Float)
    if random.random() > 0.4:
        feature_map['111'] = random.randint(1000, 9999)      # member_seq (Integer)
    if random.random() > 0.4:
        feature_map['120'] = round(random.uniform(150.0, 200.0), 1)  # height_float (Float)
    if random.random() > 0.5:
        feature_map['591'] = card                            # card_number (String)
    if random.random() > 0.5:
        feature_map['593'] = merchant                        # merchant_id (String)
    if random.random() > 0.5:
        feature_map['595'] = random.randint(3600000, 86400000)  # kg_window (Long)

    # eventFields: event_attribute_info id keys, values always strings
    event_fields = {
        '4':  uid,                  # user_id
        '5':  str(evt_time),        # event_time
        '6':  etype,                # event_type
        '7':  card,                 # card_number
        '8':  str(amount),          # amount
        '9':  direction,            # direction
        '11': merchant,             # merchant_id
        '18': txn_id,               # transaction_id
        '19': category,             # category
        '25': country,              # country
    }

    record = {
        'userId': uid,
        'time': evt_time,
        'eventId': f'evt-{i:06d}',
        'eventType': etype,
        'processTime': proc_time,
        'rules': [1],
        'actions': ['REJECT'] if random.random() > 0.8 else ['APPROVE'],
        'actionMap': {'1': {'REJECT': 'test'}} if random.random() > 0.8 else {},
        'clusterName': 'demo',
        'originCategory': 'REALTIME',
        'synthetic': False,
        'originId': -1,
        'fromUpdateAPI': False,
        'pciEncryptionStatus': 0,
        'featureMap': feature_map,
        'eventFields': event_fields,
    }
    out.append(json.dumps(record, separators=(',',':')))

sys.stdout.write('\n'.join(out) + '\n')
" "$NUM_EVENTS" | docker exec -i kafka kafka-console-producer \
  --bootstrap-server localhost:9092 \
  --topic velocity-al

echo "Done. $NUM_EVENTS events produced."
