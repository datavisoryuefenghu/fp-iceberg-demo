#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

echo "Waiting for StarRocks to be ready..."
until docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root -e "SELECT 1" &>/dev/null; do
  sleep 5
done
echo "StarRocks is ready."

echo "Registering Iceberg catalog in StarRocks..."
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root -e "
CREATE EXTERNAL CATALOG IF NOT EXISTS iceberg_catalog
PROPERTIES (
  \"type\" = \"iceberg\",
  \"iceberg.catalog.type\" = \"rest\",
  \"iceberg.catalog.uri\" = \"http://iceberg-rest:8181\",
  \"aws.s3.access_key\" = \"$AWS_ACCESS_KEY_ID\",
  \"aws.s3.secret_key\" = \"$AWS_SECRET_ACCESS_KEY\",
  \"aws.s3.endpoint\" = \"$MINIO_ENDPOINT\",
  \"aws.s3.enable_path_style_access\" = \"true\"
);
"

echo "Verifying catalogs:"
docker exec starrocks mysql -P 9030 -h 127.0.0.1 -u root -e "SHOW CATALOGS;"
echo "Done. StarRocks Iceberg catalog registered."
