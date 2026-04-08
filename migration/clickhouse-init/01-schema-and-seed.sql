-- Simulates the FP ClickHouse event_result table (ReplacingMergeTree).
-- Migration demo reads from this and exports to S3 staging, then imports to Iceberg.
--
-- Timestamps (pre-computed milliseconds):
--   time         = event time       — NOT used for day partitioning
--   timeInserted = CH insert time   — used for day filter in migration export
--
-- Day 1: timeInserted in 2024-01-01  (base = 1704067200000)
-- Day 2: timeInserted in 2024-01-02  (base = 1704153600000)

CREATE DATABASE IF NOT EXISTS demo;

CREATE TABLE IF NOT EXISTS demo.event_result (
    eventId              String,
    eventType            String,
    user_id              String,
    time                 UInt64,
    timeInserted         UInt64,
    rules                Array(Int32),
    actions              Array(String),
    dv_reevaluate_entity String   DEFAULT '',
    origin_id            Int32    DEFAULT 0,
    origin_category      String   DEFAULT '',
    dv_isDetection       UInt8    DEFAULT 0,
    amount               Float64  DEFAULT 0,
    country              String   DEFAULT '',
    merchant_id          String   DEFAULT '',
    transaction_id       String   DEFAULT '',
    card_number          String   DEFAULT ''
) ENGINE = ReplacingMergeTree()
ORDER BY (eventId);

-- ── Day 1: 2024-01-01 (timeInserted base = 1704067200000) ──────────────────
INSERT INTO demo.event_result VALUES ('evt-000001','purchase','u001',1704069000000,1704069000500,[1],['APPROVE'],'',0,'REALTIME',0, 199.99,'US','m_electronics','txn-000001','4111111111111111');
INSERT INTO demo.event_result VALUES ('evt-000002','refund',  'u002',1704070800000,1704070800800,[2],['REJECT'], '','0','REALTIME',0,  49.00,'CA','m_grocery',    'txn-000002','4242424242424242');
INSERT INTO demo.event_result VALUES ('evt-000003','purchase','u003',1704072600000,1704072600300,[1],['APPROVE'],'',0,'REALTIME',0, 349.50,'GB','m_travel',     'txn-000003','5555555555554444');
INSERT INTO demo.event_result VALUES ('evt-000004','login',   'u004',1704074400000,1704074400100,[],  [],        '',0,'REALTIME', 1,   0.00,'DE','',             'txn-000004','');
INSERT INTO demo.event_result VALUES ('evt-000005','purchase','u005',1704076200000,1704076200400,[1,3],['APPROVE'],'',0,'REALTIME',0,1299.00,'JP','m_gaming',    'txn-000005','4111111111111111');
INSERT INTO demo.event_result VALUES ('evt-000006','checkout','u001',1704078000000,1704078000600,[1],['APPROVE'],'',0,'REALTIME',0,  89.95,'US','m_clothing',   'txn-000006','4242424242424242');
INSERT INTO demo.event_result VALUES ('evt-000007','purchase','u006',1704081600000,1704081600200,[2],['REJECT'], '',0,'REALTIME',0,4999.00,'AU','m_electronics','txn-000007','5555555555554444');
INSERT INTO demo.event_result VALUES ('evt-000008','signup',  'u007',1704085200000,1704085200050,[],  [],        '',0,'REALTIME', 1,   0.00,'BR','',             'txn-000008','');
INSERT INTO demo.event_result VALUES ('evt-000009','purchase','u008',1704088800000,1704088800300,[1],['APPROVE'],'',0,'REALTIME',0, 159.00,'IN','m_grocery',    'txn-000009','4111111111111111');
INSERT INTO demo.event_result VALUES ('evt-000010','refund',  'u003',1704092400000,1704092400700,[2],['REJECT'], '',0,'REALTIME',0,  29.99,'GB','m_travel',     'txn-000010','5555555555554444');

-- ── Day 2: 2024-01-02 (timeInserted base = 1704153600000) ──────────────────
INSERT INTO demo.event_result VALUES ('evt-000011','purchase','u009',1704155400000,1704155400400,[1],['APPROVE'],'',0,'REALTIME',0, 249.00,'US','m_gaming',     'txn-000011','4111111111111111');
INSERT INTO demo.event_result VALUES ('evt-000012','purchase','u010',1704157200000,1704157200600,[1],['APPROVE'],'',0,'REALTIME',0,  79.99,'CA','m_grocery',    'txn-000012','4242424242424242');
INSERT INTO demo.event_result VALUES ('evt-000013','login',   'u001',1704159000000,1704159000100,[],  [],        '',0,'REALTIME', 1,   0.00,'US','',             'txn-000013','');
INSERT INTO demo.event_result VALUES ('evt-000014','purchase','u011',1704160800000,1704160800500,[1,2],['APPROVE'],'',0,'REALTIME',0,599.00,'DE','m_electronics','txn-000014','5555555555554444');
INSERT INTO demo.event_result VALUES ('evt-000015','refund',  'u005',1704164400000,1704164400800,[2],['REJECT'], '',0,'REALTIME',0, 100.00,'JP','m_gaming',     'txn-000015','4111111111111111');
INSERT INTO demo.event_result VALUES ('evt-000016','checkout','u012',1704168000000,1704168000200,[1],['APPROVE'],'',0,'REALTIME',0,  39.95,'AU','m_clothing',   'txn-000016','4242424242424242');
INSERT INTO demo.event_result VALUES ('evt-000017','purchase','u013',1704171600000,1704171600300,[1],['APPROVE'],'',0,'REALTIME',0, 899.00,'BR','m_travel',     'txn-000017','5555555555554444');
INSERT INTO demo.event_result VALUES ('evt-000018','signup',  'u014',1704175200000,1704175200050,[],  [],        '',0,'REALTIME', 1,   0.00,'IN','',             'txn-000018','');
