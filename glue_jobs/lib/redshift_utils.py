from __future__ import annotations

import json
import time
from datetime import datetime
from typing import Any, Dict, List, Optional

import boto3

_rs = boto3.client("redshift-data")
_sm = boto3.client("secretsmanager")


def _get_secret(secret_arn: str) -> Dict[str, str]:
    raw = _sm.get_secret_value(SecretId=secret_arn)["SecretString"]
    return json.loads(raw)


def _wait_statement(statement_id: str) -> Dict[str, Any]:
    while True:
        resp = _rs.describe_statement(Id=statement_id)
        if resp["Status"] in ("FINISHED", "FAILED", "ABORTED"):
            return resp
        time.sleep(2)


def execute_sql(workgroup: str, database: str, sql: str) -> None:
    resp = _rs.execute_statement(
        WorkgroupName=workgroup,
        Database=database,
        Sql=sql,
    )
    result = _wait_statement(resp["Id"])
    if result["Status"] != "FINISHED":
        raise RuntimeError(
            f"SQL fallido [{result['Status']}]: {result.get('Error')}\n--- SQL ---\n{sql}"
        )


def query_rows(workgroup: str, database: str, sql: str) -> List[List[Dict]]:
    resp = _rs.execute_statement(
        WorkgroupName=workgroup,
        Database=database,
        Sql=sql,
    )
    result = _wait_statement(resp["Id"])
    if result["Status"] != "FINISHED":
        raise RuntimeError(f"Query fallido: {result.get('Error')}")
    return _rs.get_statement_result(Id=resp["Id"]).get("Records", [])


def get_watermark(workgroup: str, database: str, source_name: str) -> datetime:
    rows = query_rows(
        workgroup,
        database,
        f"SELECT last_processed_ts FROM control.watermark WHERE source_name = '{source_name}'",
    )
    if not rows:
        raise ValueError(f"Watermark no encontrado para source: {source_name}")
    return datetime.fromisoformat(rows[0][0]["stringValue"])


def set_watermark(workgroup: str, database: str, source_name: str, ts: datetime) -> None:
    ts_str = ts.strftime("%Y-%m-%d %H:%M:%S")
    execute_sql(
        workgroup,
        database,
        f"""
        UPDATE control.watermark
        SET last_processed_ts = '{ts_str}', updated_at = SYSDATE
        WHERE source_name = '{source_name}'
        """,
    )


def copy_from_s3(
    workgroup: str,
    database: str,
    table: str,
    s3_path: str,
    iam_role: str,
    region: str = "us-east-1",
) -> None:
    execute_sql(
        workgroup,
        database,
        f"""
        COPY {table}
        FROM '{s3_path}'
        IAM_ROLE '{iam_role}'
        FORMAT AS PARQUET
        REGION '{region}'
        """,
    )


def truncate_table(workgroup: str, database: str, table: str) -> None:
    # TRUNCATE requiere ownership; DELETE funciona con privilegio GRANT DELETE
    execute_sql(workgroup, database, f"DELETE FROM {table}")
