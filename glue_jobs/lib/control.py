from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

from redshift_utils import execute_sql, query_rows


@dataclass
class PipelineRun:
    job_name: str
    source_name: str
    workgroup: str
    database: str
    watermark_inicio: Optional[datetime] = None
    watermark_fin: Optional[datetime] = None
    registros_leidos: int = 0
    registros_validos: int = 0
    registros_rechazados: int = 0
    registros_insertados: int = 0
    registros_actualizados: int = 0
    run_id: Optional[int] = None
    status: str = "RUNNING"
    error_msg: Optional[str] = None


def start_run(run: PipelineRun) -> int:
    wi = f"'{run.watermark_inicio}'" if run.watermark_inicio else "NULL"
    execute_sql(
        run.workgroup,
        run.database,
        f"""
        INSERT INTO control.pipeline_run
            (job_name, source_name, watermark_inicio, status)
        VALUES
            ('{run.job_name}', '{run.source_name}', {wi}, 'RUNNING')
        """,
    )
    rows = query_rows(
        run.workgroup,
        run.database,
        f"""
        SELECT MAX(run_id) FROM control.pipeline_run
        WHERE job_name = '{run.job_name}' AND source_name = '{run.source_name}'
        """,
    )
    run_id = int(rows[0][0]["longValue"])
    run.run_id = run_id
    return run_id


def finish_run(run: PipelineRun) -> None:
    wi = f"'{run.watermark_inicio}'" if run.watermark_inicio else "NULL"
    wf = f"'{run.watermark_fin}'"    if run.watermark_fin    else "NULL"
    error_escaped = run.error_msg.replace("'", "''") if run.error_msg else None
    em = f"'{error_escaped[:1990]}'" if error_escaped        else "NULL"

    execute_sql(
        run.workgroup,
        run.database,
        f"""
        UPDATE control.pipeline_run SET
            ts_fin                 = SYSDATE,
            watermark_inicio       = {wi},
            watermark_fin          = {wf},
            registros_leidos       = {run.registros_leidos},
            registros_validos      = {run.registros_validos},
            registros_rechazados   = {run.registros_rechazados},
            registros_insertados   = {run.registros_insertados},
            registros_actualizados = {run.registros_actualizados},
            status                 = '{run.status}',
            error_msg              = {em}
        WHERE run_id = {run.run_id}
        """,
    )
