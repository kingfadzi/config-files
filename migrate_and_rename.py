#!/usr/bin/env python3
import decimal
import time
from datetime import datetime, timedelta

import yaml
import pyodbc
import pandas as pd
from sqlalchemy import create_engine, text

# Adjust as needed
CHUNK_SIZE = 50_000

def load_config(path):
    with open(path, 'r') as f:
        return yaml.safe_load(f)

def create_pg_engine(pg_cfg):
    user = pg_cfg['user']
    pw   = pg_cfg['password']
    host = pg_cfg['host']
    port = pg_cfg.get('port', 5432)
    db   = pg_cfg['database']
    url = f'postgresql://{user}:{pw}@{host}:{port}/{db}'
    return create_engine(url)

def build_sql_server_conn_str(src_cfg):
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

def fetch_column_info(sql_conn, table_name):
    cursor = sql_conn.cursor()
    cursor.execute(f"""
        SELECT COLUMN_NAME, DATA_TYPE
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_NAME = ?
    """, table_name)
    cols = [row[0] for row in cursor.fetchall() if 'binary' not in row[1].lower()]
    cursor.close()
    return cols

def drop_table_if_exists(pg_engine, table):
    with pg_engine.begin() as conn:
        conn.execute(text(f'DROP TABLE IF EXISTS "{table}"'))
        print(f"Dropped PostgreSQL table if it existed: {table}")

def transfer_table(sql_conn, pg_engine, tbl_cfg):
    tbl    = tbl_cfg['name']
    datecol = tbl_cfg['date_column']
    days   = tbl_cfg.get('lookback_days', 90)
    limit  = tbl_cfg.get('limit', None)

    cols = fetch_column_info(sql_conn, tbl)
    if not cols:
        print(f"[{tbl}] no non-binary columns found; skipping.")
        return

    drop_table_if_exists(pg_engine, tbl)

    cursor = sql_conn.cursor()
    cutoff = datetime.now() - timedelta(days=days)
    sel_cols = ', '.join(f'[{c}]' for c in cols)
    top = f"TOP {limit} " if limit else ""
    sql = (
        f"SELECT {top}{sel_cols} FROM [{tbl}] "
        f"WHERE [{datecol}] >= ?"
    )

    print(f"[{tbl}] Executing: {sql}")
    cursor.execute(sql, cutoff)

    inserted = 0
    with pg_engine.begin() as pg_conn:
        while True:
            chunk = cursor.fetchmany(CHUNK_SIZE)
            if not chunk:
                break
            # convert decimals
            data = [
                [float(x) if isinstance(x, decimal.Decimal) else x for x in row]
                for row in chunk
            ]
            df = pd.DataFrame(data, columns=cols)
            if df.empty:
                break
            df.to_sql(tbl, con=pg_conn, if_exists='append', index=False)
            inserted += len(df)
            print(f"[{tbl}] inserted {len(df)} rows (total {inserted})")

    cursor.close()
    print(f"[{tbl}] DONE: total {inserted} rows transferred.")

def main():
    import argparse
    p = argparse.ArgumentParser(
        description="Bulk-copy from SQL Server to Postgres via YAML"
    )
    p.add_argument(
        '--config', '-c',
        required=True,
        help="Path to YAML config"
    )
    args = p.parse_args()

    cfg = load_config(args.config)
    pg_engine = create_pg_engine(cfg['postgres'])

    for src in cfg['sources']:
        print(f"=== Source: {src['name']} ===")
        conn_str = build_sql_server_conn_str(src)
        sql_conn = pyodbc.connect(conn_str, autocommit=True)
        for tbl in src.get('tables', []):
            transfer_table(sql_conn, pg_engine, tbl)
        sql_conn.close()

    pg_engine.dispose()

if __name__ == "__main__":
    main()
