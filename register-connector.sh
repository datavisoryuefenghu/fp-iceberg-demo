#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

CONNECT_URL="http://localhost:8083"

echo "Waiting for Kafka Connect to be ready..."
until curl -sf "$CONNECT_URL/connectors" > /dev/null 2>&1; do
  sleep 2
done
echo "Kafka Connect is ready."

echo "Registering Iceberg sink connector with Feature Resolver SMT..."
curl -s -X PUT "$CONNECT_URL/connectors/iceberg-sink/config" \
  -H "Content-Type: application/json" \
  -d '{
    "connector.class": "org.apache.iceberg.connect.IcebergSinkConnector",
    "tasks.max": "1",
    "topics": "velocity-al",
    "iceberg.tables": "demo.event_result",
    "iceberg.tables.auto-create-enabled": "true",
    "iceberg.catalog.type": "rest",
    "iceberg.catalog.uri": "http://iceberg-rest:8181",
    "iceberg.catalog.s3.endpoint": "http://minio:9000",
    "iceberg.catalog.s3.path-style-access": "true",
    "iceberg.catalog.s3.access-key-id": "'"$AWS_ACCESS_KEY_ID"'",
    "iceberg.catalog.s3.secret-access-key": "'"$AWS_SECRET_ACCESS_KEY"'",
    "iceberg.catalog.warehouse": "s3://'"$MINIO_BUCKET"'/",
    "iceberg.catalog.io-impl": "org.apache.iceberg.aws.s3.S3FileIO",
    "iceberg.control.commit.interval-ms": "10000",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",

    "transforms": "resolveFeatures",
    "transforms.resolveFeatures.type": "com.datavisor.demo.smt.FeatureResolverTransform",
    "transforms.resolveFeatures.metadata.jdbc.url": "jdbc:mysql://mysql:3306/'"$MYSQL_DATABASE"'",
    "transforms.resolveFeatures.metadata.jdbc.user": "'"$MYSQL_USER"'",
    "transforms.resolveFeatures.metadata.jdbc.password": "'"$MYSQL_PASSWORD"'",
    "transforms.resolveFeatures.metadata.refresh.interval.ms": "60000",
    "transforms.resolveFeatures.feature.map.field": "featureMap"
  }' | python3 -m json.tool

echo ""
echo "Connector registered. Checking status..."
sleep 5
curl -s "$CONNECT_URL/connectors/iceberg-sink/status" | python3 -m json.tool
