#!/usr/bin/env python3
"""
Exports one day from the demo ClickHouse event_result table to S3 staging as Parquet.
Mirrors what FP's IcebergMigrationService.exportDayToS3() does in production.

Uses ClickHouse's FORMAT Parquet over HTTP — no extra dependencies needed.
The Parquet bytes are streamed directly from CH to MinIO via s3fs.

Usage:
    python export.py --date 20240101
    python export.py --date 20240101 --date 20240102  (multiple days)
    python export.py --start-date 20240101 --end-date 20240102  (range)
"""

import argparse
import sys
import requests
import s3fs

CH_URL         = "http://localhost:8123/"
CH_USER        = "default"
CH_PASSWORD    = ""
S3_ENDPOINT    = "http://localhost:9000"
S3_ACCESS_KEY  = "admin"
S3_SECRET_KEY  = "password"
S3_BUCKET      = "warehouse"
STAGING_PREFIX = "migration-staging"
TENANT         = "demo"

# Mirrors the SELECT built by IcebergMigrationService.exportDayToS3().
# Fixed columns are aliased to camelCase; feature columns keep their original name.
EXPORT_SQL = """\
SELECT
    eventId                                         AS eventId,
    eventType                                       AS eventType,
    time                                            AS eventTime,
    timeInserted                                    AS processingTime,
    rules                                           AS rules,
    actions                                         AS actions,
    dv_reevaluate_entity                            AS reEvaluateEntity,
    toInt32(origin_id)                              AS originId,
    origin_category                                 AS originCategory,
    user_id                                         AS userId,
    if(dv_isDetection = 0, true, false)             AS fromUpdateAPI,
    amount,
    country,
    merchant_id,
    transaction_id,
    card_number
FROM demo.event_result FINAL
WHERE toYYYYMMDD(toDateTime(intDiv(timeInserted, 1000))) = {day}
FORMAT Parquet
"""


def export_day(day: int, fs: s3fs.S3FileSystem) -> int:
    """Export one day from ClickHouse to MinIO staging. Returns row count."""
    sql = EXPORT_SQL.format(day=day)
    s3_path = f"{S3_BUCKET}/{STAGING_PREFIX}/{TENANT}/{day}/data.parquet"

    print(f"  [{day}] Querying ClickHouse...", flush=True)
    resp = requests.post(
        CH_URL,
        data=sql.encode(),
        params={"user": CH_USER, "password": CH_PASSWORD},
        stream=True,
        timeout=120,
    )
    if resp.status_code != 200:
        print(f"  [{day}] ERROR from ClickHouse: {resp.text}", file=sys.stderr)
        return 0

    print(f"  [{day}] Streaming Parquet → s3://{s3_path}", flush=True)
    with fs.open(s3_path, "wb") as f:
        for chunk in resp.iter_content(chunk_size=65536):
            if chunk:
                f.write(chunk)

    # Quick row-count check via COUNT query
    count_resp = requests.post(
        CH_URL,
        data=f"SELECT count() FROM demo.event_result FINAL WHERE toYYYYMMDD(toDateTime(intDiv(timeInserted, 1000))) = {day}".encode(),
        params={"user": CH_USER, "password": CH_PASSWORD},
        timeout=30,
    )
    rows = int(count_resp.text.strip()) if count_resp.status_code == 200 else -1
    print(f"  [{day}] Done: {rows} rows exported", flush=True)
    return rows


def expand_range(start: int, end: int) -> list:
    """Expand YYYYMMDD range to list of dates."""
    import calendar
    days = []
    # start/end are YYYYMMDD — iterate month by month
    start_ym = start // 100
    end_ym   = end   // 100
    cur_ym   = start_ym
    while cur_ym <= end_ym:
        year, month = divmod(cur_ym, 100)
        days_in_month = calendar.monthrange(year, month)[1]
        for d in range(1, days_in_month + 1):
            day = cur_ym * 100 + d
            if start <= day <= end:
                days.append(day)
        cur_ym = (year + 1) * 100 + 1 if month == 12 else cur_ym + 1
    return days


def main():
    parser = argparse.ArgumentParser(description="Export ClickHouse demo data to MinIO staging (Parquet).")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--date",       type=int, nargs="+", metavar="YYYYMMDD",
                       help="One or more specific dates")
    group.add_argument("--start-date", type=int, metavar="YYYYMMDD",
                       help="Start of date range (requires --end-date)")
    parser.add_argument("--end-date",  type=int, metavar="YYYYMMDD",
                        help="End of date range (inclusive)")
    args = parser.parse_args()

    if args.start_date and not args.end_date:
        parser.error("--end-date is required when using --start-date")

    days = args.date if args.date else expand_range(args.start_date, args.end_date)

    fs = s3fs.S3FileSystem(
        key=S3_ACCESS_KEY,
        secret=S3_SECRET_KEY,
        client_kwargs={"endpoint_url": S3_ENDPOINT},
    )

    print(f"Exporting {len(days)} day(s) from ClickHouse → MinIO staging (s3://{S3_BUCKET}/{STAGING_PREFIX}/{TENANT}/)")
    total = 0
    failed = []
    for day in days:
        rows = export_day(day, fs)
        if rows >= 0:
            total += rows
        else:
            failed.append(day)

    print(f"\nExport complete: {total} total rows, {len(days) - len(failed)} days OK, {len(failed)} failed")
    if failed:
        print(f"Failed days: {failed}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
