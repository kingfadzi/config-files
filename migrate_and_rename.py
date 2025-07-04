#!/usr/bin/env python3
import decimal
import re
import time
from datetime import datetime, timedelta

import yaml
import pyodbc
import pandas as pd
from sqlalchemy import create_engine, text

# Adjust as needed
CHUNK_SIZE = 50_000

def sanitize(name: str) -> str:
    """
    Strip leading/trailing whitespace, replace internal spaces with underscores,
    and lowercase.
    """
    return re.sub(r'\s+', '_', name.strip()).lower()

def load_config(path: str) -> dict:
    """Load YAML configuration from file."""
    with open(path, 'r') as f:
        return yaml.safe_load(f)

def create_pg_engine(pg_cfg: dict):
    """Create SQLAlchemy engine for Postgres."""
    user = pg_cfg['user']
    pw   = pg_cfg['password']
    host = pg_cfg['host']
    port = pg_cfg.get('port', 5432)
    db   = pg_cfg['database']
    url = f'postgresql://{user}:{pw}@{host}:{port}/{db}'
    return create_engine(url)

def build_sql_server_conn_str(src_cfg: dict) -> str:
    """Compose ODBC connection string for SQL Server."""
    parts = [
        f"DRIVER={{{src_cfg['driver']}}}",
        f"SERVER={src_cfg['host']}\\{src_cfg['instance']},{src_cfg['port']}",
        f"DATABASE={src_cfg['database']}"
    ]
    if src_cfg.get('trusted_connection', False):
        parts.append("Trusted_Connection=yes")
    else:
        parts.append(f"UID={src_cfg['username']}")
        parts.append(f"PWD={src_cfg['password']}")
    return ';'.join(parts)

def fetch_column_info(sql_conn, schema: str, table_name: str) -> list:
    """
    Return list of column names for a given schema.table, excluding VARBINARY types by default.
    If no non-binary columns are found, fall back to all columns.
    """
    cursor = sql_conn.cursor()
    cursor.execute("""
        SELECT COLUMN_NAME, DATA_TYPE
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
    """, schema, table_name)
    filtered = [row[0] for row in cursor.fetchall()
                if 'binary' not in row[1].lower()]
    if filtered:
        cursor.close()
        return filtered

    cursor.execute("""
        SELECT COLUMN_NAME
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
    """, schema, table_name)
    all_cols = [row[0] for row in cursor.fetchall()]
    cursor.close()
    print(f"[{schema}.{table_name}] no non-binary columns found, falling back to all columns.")
    return all_cols

def drop_table_if_exists(pg_engine, table: str):
    """Drop the target table in Postgres if it already exists."""
    with pg_engine.begin() as conn:
        conn.execute(text(f'DROP TABLE IF EXISTS "{table}"'))
    print(f"Dropped PostgreSQL table if it existed: {table}")

def build_where_clause(tbl_cfg: dict) -> str:
    """
    Build a WHERE clause from tbl_cfg['where']:
      - If None: returns empty string
      - If list: wraps each element in () and ANDs them
      - If string: uses it verbatim
    """
    wc = tbl_cfg.get('where')
    if wc is None:
        return ""
    if isinstance(wc, list):
        joined = " AND ".join(f"({cond})" for cond in wc)
        return f"WHERE {joined}"
    return f"WHERE {wc}"

def build_order_clause(tbl_cfg: dict) -> str:
    """
    Build an ORDER BY clause from tbl_cfg['order_by']:
      - If None: returns empty string
      - If list: joins items with commas
      - If string: uses it verbatim
    """
    ob = tbl_cfg.get('order_by')
    if ob is None:
        return ""
    if isinstance(ob, list):
        joined = ", ".join(ob)
        return f"ORDER BY {joined}"
    return f"ORDER BY {ob}"

def transfer_table(sql_conn, pg_engine, tbl_cfg: dict):
    """Fetch from SQL Server and insert into Postgres using chunked DataFrame writes."""
    if not tbl_cfg.get('enabled', True):
        schema = tbl_cfg.get('schema', 'dbo')
        name = tbl_cfg['name']
        print(f"--> Skipping table {schema}.{name} (disabled)")
        return

    schema        = tbl_cfg.get('schema', 'dbo')
    orig_name     = tbl_cfg['name']
    sanitized_tbl = sanitize(orig_name)

    # get original column names
    cols = fetch_column_info(sql_conn, schema, orig_name)
    if not cols:
        print(f"[{schema}.{orig_name}] no columns found; skipping.")
        return

    # mapping for sanitized column names
    sanitized_cols = [sanitize(c) for c in cols]
    drop_table_if_exists(pg_engine, sanitized_tbl)

    cursor   = sql_conn.cursor()
    sel_cols = ", ".join(f"[{c}]" for c in cols)
    top      = f"TOP {tbl_cfg.get('limit')} " if tbl_cfg.get('limit') else ""
    where    = build_where_clause(tbl_cfg)
    order    = build_order_clause(tbl_cfg)

    sql = f"SELECT {top}{sel_cols} FROM [{schema}].[{orig_name}] {where} {order}"
    print(f"[{schema}.{orig_name}] Executing: {sql}")
    cursor.execute(sql)

    total = 0
    with pg_engine.begin() as pg_conn:
        while True:
            rows = cursor.fetchmany(CHUNK_SIZE)
            if not rows:
                break
            data = [
                [float(v) if isinstance(v, decimal.Decimal) else v for v in row]
                for row in rows
            ]
            df = pd.DataFrame(data, columns=sanitized_cols)
            if df.empty:
                break
            df.to_sql(sanitized_tbl, con=pg_conn, if_exists='append', index=False)
            total += len(df)
            print(f"[{sanitized_tbl}] inserted {len(df)} rows (total {total})")

    cursor.close()
    print(f"[{sanitized_tbl}] DONE: total {total} rows transferred.")

def main():
    import argparse
    parser = argparse.ArgumentParser(
        description="Bulk-copy from SQL Server to Postgres via YAML"
    )
    parser.add_argument(
        '--config', '-c',
        required=True,
        help="Path to YAML config file"
    )
    args = parser.parse_args()

    cfg = load_config(args.config)
    pg_engine = create_pg_engine(cfg['postgres'])

    for src in cfg.get('sources', []):
        if not src.get('enabled', True):
            print(f"--> Skipping source {src['name']} (disabled)")
            continue

        print(f"\n=== Source: {src['name']} ===")
        conn_str = build_sql_server_conn_str(src)
        sql_conn = pyodbc.connect(conn_str, autocommit=True)

        for tbl in src.get('tables', []):
            transfer_table(sql_conn, pg_engine, tbl)

        sql_conn.close()

    pg_engine.dispose()
    print("\nAll transfers complete.")

if __name__ == "__main__":
    main()
