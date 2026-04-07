#!/usr/bin/env python3
"""
Imports S3 Parquet staging files (exported by export.py) into Iceberg.
Demo version of tools/fp-starrocks-deployment/migration/import_iceberg.py —
extended with MinIO support (custom S3 endpoint + path-style access).

Processes one day at a time and streams each file in batches to avoid loading
full days into memory. Auto-creates the Iceberg table if it does not yet exist.

Usage:
    python import_iceberg.py \
        --tenant demo \
        --start-month 202401 \
        --end-month 202401 \
        --s3-staging s3://warehouse/migration-staging \
        --iceberg-catalog-url http://localhost:8181 \
        --s3-endpoint http://localhost:9000 \
        --s3-access-key admin \
        --s3-secret-key password

State file:
    migration_state_{tenant}.json — tracks DONE days so re-runs are safe.
    Delete a specific entry (or the whole file) to force re-import of a day.
"""

import argparse
import calendar
import json
import os
import sys

import pyarrow as pa
import pyarrow.parquet as pq
import s3fs
from pyiceberg.catalog import load_catalog
from pyiceberg.exceptions import NoSuchTableError, NoSuchNamespaceError
from pyiceberg.schema import Schema
from pyiceberg.types import (
    BooleanType,
    DoubleType,
    IntegerType,
    ListType,
    LongType,
    NestedField,
    StringType,
)

BATCH_SIZE = 100_000

# Schema that matches the export SELECT in export.py.
# Used only when auto-creating the table (first run with no live Kafka Connect data).
_DEMO_SCHEMA = Schema(
    NestedField(1,  "eventId",          StringType(),   required=False),
    NestedField(2,  "eventType",         StringType(),   required=False),
    NestedField(3,  "eventTime",         LongType(),     required=False),
    NestedField(4,  "processingTime",    LongType(),     required=False),
    NestedField(5,  "rules",    ListType(51, IntegerType(), element_required=False), required=False),
    NestedField(6,  "actions",  ListType(52, StringType(),  element_required=False), required=False),
    NestedField(7,  "reEvaluateEntity",  StringType(),   required=False),
    NestedField(8,  "originId",          IntegerType(),  required=False),
    NestedField(9,  "originCategory",    StringType(),   required=False),
    NestedField(10, "userId",            StringType(),   required=False),
    NestedField(11, "fromUpdateAPI",     BooleanType(),  required=False),
    NestedField(12, "amount",            DoubleType(),   required=False),
    NestedField(13, "country",           StringType(),   required=False),
    NestedField(14, "merchant_id",       StringType(),   required=False),
    NestedField(15, "transaction_id",    StringType(),   required=False),
    NestedField(16, "card_number",       StringType(),   required=False),
)


# ---------------------------------------------------------------------------
# Day range helpers
# ---------------------------------------------------------------------------

def expand_to_days(start_month: int, end_month: int) -> list[int]:
    """Expand YYYYMM range into an ordered list of YYYYMMDD values."""
    days = []
    current = start_month
    while current <= end_month:
        year, month = divmod(current, 100)
        days_in_month = calendar.monthrange(year, month)[1]
        for d in range(1, days_in_month + 1):
            days.append(current * 100 + d)
        current = (year + 1) * 100 + 1 if month == 12 else current + 1
    return days


# ---------------------------------------------------------------------------
# State persistence
# ---------------------------------------------------------------------------

def load_state(tenant: str) -> dict:
    path = f"migration_state_{tenant}.json"
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


def save_state(tenant: str, state: dict):
    path = f"migration_state_{tenant}.json"
    with open(path, "w") as f:
        json.dump(state, f, indent=2)


# ---------------------------------------------------------------------------
# Iceberg table auto-creation
# ---------------------------------------------------------------------------

def ensure_table(catalog, tenant: str):
    """Create namespace and table if they don't exist yet."""
    full_name = f"{tenant}.event_result"
    try:
        catalog.load_table(full_name)
        return  # already exists
    except NoSuchTableError:
        pass

    try:
        catalog.create_namespace(tenant)
    except Exception:
        pass  # namespace already exists

    catalog.create_table(full_name, schema=_DEMO_SCHEMA)
    print(f"  Auto-created Iceberg table {full_name}", flush=True)


# ---------------------------------------------------------------------------
# Per-day import with batch streaming
# ---------------------------------------------------------------------------

def import_day(tenant: str, yyyymmdd: int, s3_staging: str,
               catalog, fs: s3fs.S3FileSystem, dry_run: bool) -> bool:
    """Stream one day's Parquet file into the Iceberg table in batches."""
    s3_path = f"{s3_staging.rstrip('/')}/{tenant}/{yyyymmdd}/data.parquet"
    s3_path_bare = s3_path.replace("s3://", "")

    print(f"  Checking {s3_path} ...", flush=True)
    if not fs.exists(s3_path_bare):
        print(f"  ERROR: staging file not found: {s3_path}", file=sys.stderr)
        return False

    pf = pq.ParquetFile(s3_path_bare, filesystem=fs)
    total_rows = pf.metadata.num_rows
    print(f"  Rows: {total_rows:,}  Columns: {len(pf.schema_arrow.names)}  "
          f"Batches: {-(-total_rows // BATCH_SIZE)}", flush=True)

    if dry_run:
        print(f"  [dry-run] would stream {total_rows:,} rows → {tenant}.event_result")
        return True

    table = catalog.load_table(f"{tenant}.event_result")

    appended = 0
    for batch in pf.iter_batches(batch_size=BATCH_SIZE):
        table.append(pa.Table.from_batches([batch]))
        appended += len(batch)
        print(f"  ... {appended:,}/{total_rows:,} rows", flush=True)

    print(f"  Done: {appended:,} rows appended to {tenant}.event_result", flush=True)
    return True


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def run(args):
    days = expand_to_days(args.start_month, args.end_month)
    state = load_state(args.tenant)

    print(f"Tenant: {args.tenant}  Range: {args.start_month}–{args.end_month}  "
          f"({len(days)} days)  batch_size={BATCH_SIZE:,}  dry_run={args.dry_run}")

    catalog_kwargs = {"uri": args.iceberg_catalog_url}
    if args.s3_endpoint:
        catalog_kwargs["s3.endpoint"] = args.s3_endpoint
        catalog_kwargs["s3.path-style-access"] = "true"
    if args.s3_access_key:
        catalog_kwargs["s3.access-key-id"]     = args.s3_access_key
        catalog_kwargs["s3.secret-access-key"] = args.s3_secret_key

    catalog = load_catalog("rest", **catalog_kwargs)

    fs_kwargs: dict = {}
    if args.s3_endpoint:
        fs_kwargs["key"]            = args.s3_access_key or ""
        fs_kwargs["secret"]         = args.s3_secret_key or ""
        fs_kwargs["client_kwargs"]  = {"endpoint_url": args.s3_endpoint}
    else:
        fs_kwargs["anon"] = False   # use boto3 credential chain for real AWS

    fs = s3fs.S3FileSystem(**fs_kwargs)

    if not args.dry_run:
        ensure_table(catalog, args.tenant)

    ok = skipped = failed = 0

    for yyyymmdd in days:
        key = str(yyyymmdd)
        if state.get(key) == "DONE":
            print(f"[{yyyymmdd}] SKIP (already done)")
            skipped += 1
            continue

        print(f"[{yyyymmdd}] Importing ...", flush=True)
        try:
            success = import_day(
                args.tenant, yyyymmdd, args.s3_staging, catalog, fs, args.dry_run
            )
            if success:
                state[key] = "DONE"
                save_state(args.tenant, state)
                print(f"[{yyyymmdd}] OK")
                ok += 1
            else:
                state[key] = "FAILED"
                save_state(args.tenant, state)
                print(f"[{yyyymmdd}] FAILED (file missing)")
                failed += 1
        except Exception as e:
            state[key] = "FAILED"
            save_state(args.tenant, state)
            print(f"[{yyyymmdd}] FAILED: {e}", file=sys.stderr)
            failed += 1

    print(f"\nDone. ok={ok}  skipped={skipped}  failed={failed}")
    if failed:
        sys.exit(1)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Import migration Parquet (from S3 staging) into Iceberg (per day, streamed)."
    )
    parser.add_argument("--tenant",              required=True,  help="Tenant name (e.g. demo)")
    parser.add_argument("--start-month",         required=True,  type=int, help="Start month YYYYMM")
    parser.add_argument("--end-month",           required=True,  type=int, help="End month YYYYMM")
    parser.add_argument("--s3-staging",          required=True,  help="S3 staging base, e.g. s3://warehouse/migration-staging")
    parser.add_argument("--iceberg-catalog-url", required=True,  help="Iceberg REST catalog URL")
    parser.add_argument("--s3-endpoint",         default=None,   help="Custom S3 endpoint (for MinIO)")
    parser.add_argument("--s3-access-key",       default=None,   help="S3 access key (for MinIO)")
    parser.add_argument("--s3-secret-key",       default=None,   help="S3 secret key (for MinIO)")
    parser.add_argument("--dry-run",             action="store_true",
                        help="Read Parquet metadata but skip Iceberg append")
    args = parser.parse_args()

    if args.start_month > args.end_month:
        print("ERROR: --start-month must be <= --end-month", file=sys.stderr)
        sys.exit(1)

    run(args)


if __name__ == "__main__":
    main()
