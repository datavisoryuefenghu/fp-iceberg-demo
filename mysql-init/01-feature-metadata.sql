-- Simulates the FP Feature table. In real FP, Feature has id, name, return_type.
-- The SMT reads this to resolve featureMap integer keys → named, typed columns.

USE iceberg_catalog;

CREATE TABLE IF NOT EXISTS feature (
    id          INT PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    status      VARCHAR(20)  NOT NULL DEFAULT 'PUBLISHED',
    return_type VARCHAR(50)  NOT NULL DEFAULT 'String'
);

INSERT INTO feature (id, name, status, return_type) VALUES
    (1,   'time',              'PUBLISHED', 'Long'),
    (6,   'gender',            'PUBLISHED', 'Integer'),
    (7,   'country',           'PUBLISHED', 'String'),
    (8,   'amount',            'PUBLISHED', 'Double'),
    (9,   'user_id',           'PUBLISHED', 'String'),
    (13,  'event_type',        'PUBLISHED', 'String'),
    (34,  'is_new_user',       'PUBLISHED', 'Boolean'),
    (35,  'email',             'PUBLISHED', 'String'),
    (39,  'float_feature',     'PUBLISHED', 'Float'),
    (40,  'weight',            'PUBLISHED', 'Double'),
    (90,  'ip',                'PUBLISHED', 'String'),
    (108, 'device_id',         'PUBLISHED', 'String'),
    (111, 'member_seq',        'PUBLISHED', 'Integer'),
    (120, 'height_float',      'PUBLISHED', 'Float'),
    (476, 'transaction_amount','PUBLISHED', 'Double'),
    (591, 'card_number',       'PUBLISHED', 'String'),
    (593, 'merchant_id',       'PUBLISHED', 'String'),
    (595, 'kg_window',         'PUBLISHED', 'Long')
ON DUPLICATE KEY UPDATE name=VALUES(name), status=VALUES(status), return_type=VALUES(return_type);
