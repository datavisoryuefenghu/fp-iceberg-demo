#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

WORK_DIR="/tmp/auditloader-setup"
CONTAINER_PATH="/tmp/auditloader.zip"

echo "=== Setting up StarRocks AuditLoader Plugin ==="

# 1. Create audit database and table
echo "[1/4] Creating audit database and table..."
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root -e \
  "CREATE DATABASE IF NOT EXISTS starrocks_audit_db__;"

docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root -e "
CREATE TABLE IF NOT EXISTS starrocks_audit_db__.starrocks_audit_tbl__ (
  queryId         VARCHAR(64),
  timestamp       DATETIME NOT NULL,
  queryType       VARCHAR(12),
  clientIp        VARCHAR(32),
  user            VARCHAR(64),
  authorizedUser  VARCHAR(64),
  resourceGroup   VARCHAR(64),
  catalog         VARCHAR(32),
  db              VARCHAR(96),
  state           VARCHAR(8),
  errorCode       VARCHAR(512),
  queryTime       BIGINT,
  scanBytes       BIGINT,
  scanRows        BIGINT,
  returnRows      BIGINT,
  cpuCostNs       BIGINT,
  memCostBytes    BIGINT,
  stmtId          INT,
  isQuery         TINYINT,
  feIp            VARCHAR(128),
  stmt            VARCHAR(1048576),
  digest          VARCHAR(32),
  planCpuCosts    DOUBLE,
  planMemCosts    DOUBLE,
  pendingTimeMs   BIGINT,
  candidateMVs    VARCHAR(65533) NULL,
  hitMvs          VARCHAR(65533) NULL,
  warehouse       VARCHAR(32) NULL
) ENGINE = OLAP
DUPLICATE KEY (queryId, timestamp, queryType)
PARTITION BY date_trunc('day', timestamp)
PROPERTIES (
  'replication_num' = '1',
  'partition_live_number' = '30'
);"

# 2. Download AuditLoader, configure plugin.conf, re-zip
echo "[2/4] Downloading and configuring AuditLoader..."
rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR"
curl -sL -o "$WORK_DIR/auditloader.zip" \
  https://releases.starrocks.io/resources/auditloader.zip
cd "$WORK_DIR" && unzip -q auditloader.zip

cat > "$WORK_DIR/plugin.conf" << 'CONF'
frontend_host_port=127.0.0.1:8030
database=starrocks_audit_db__
table=starrocks_audit_tbl__
user=root
password=
secret_key=
filter=

# Flush audit entries every 5 seconds — suitable for demo/testing so results
# appear quickly in the audit table after running a query.
# In production, the default of 60 seconds is sufficient since audit data
# is used for post-analysis, not real-time monitoring.
max_batch_interval_sec=5
CONF

rm auditloader.zip
zip -qj auditloader.zip auditloader.jar plugin.conf plugin.properties

# 3. Copy into container and install
echo "[3/4] Installing plugin..."
docker cp "$WORK_DIR/auditloader.zip" starrocks:"$CONTAINER_PATH"
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root -e \
  "INSTALL PLUGIN FROM '$CONTAINER_PATH';"

# 4. Verify
echo "[4/4] Verifying installation..."
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root --table -e "SHOW PLUGINS;"

rm -rf "$WORK_DIR"
echo ""
echo "AuditLoader installed. All queries are now recorded in:"
echo "  starrocks_audit_db__.starrocks_audit_tbl__"
echo ""
echo "Run ./query-audit.sh after executing some queries to see metrics."
