"""
gold_job.py — Generic Gold loading job
Responsabilidad única: orquestar la carga dimensional para cualquier process_type.

Agregar un nuevo cubo de información = agregar un JSON en process_configs/gold/.
No se requieren cambios en este job.

Flujo: Read Silver → transforms[] → [custom_handler?] → Gold Parquet → TRUNCATE/COPY/sql_after_copy[]
"""
import json
import sys
from datetime import datetime
from typing import Any, Dict, Optional

import boto3
from awsglue.context import GlueContext
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import DataFrame
from pyspark.sql import functions as F

import control
import redshift_utils
import s3_utils
from control import PipelineRun
from transform_engine import TransformContext, apply_transformations, invoke_custom_handler

REQUIRED_ARGS = [
    "JOB_NAME",
    "PROCESS_TYPE",
    "SILVER_BUCKET",
    "GOLD_BUCKET",
    "CONFIG_BUCKET",
    "CONFIG_PREFIX",
    "EXECUTION_DATE",
    "REDSHIFT_WORKGROUP",
    "REDSHIFT_DATABASE",
    "REDSHIFT_IAM_ROLE",
    "AWS_REGION",
]

sc    = SparkContext()
glue  = GlueContext(sc)
spark = glue.spark_session

args         = getResolvedOptions(sys.argv, REQUIRED_ARGS)
process_type = args["PROCESS_TYPE"]
exec_date    = args["EXECUTION_DATE"]
workgroup    = args["REDSHIFT_WORKGROUP"]
database     = args["REDSHIFT_DATABASE"]
iam_role     = args["REDSHIFT_IAM_ROLE"]
region       = args["AWS_REGION"]

year, month, day = exec_date.split("-")
execution_dt     = datetime.strptime(exec_date, "%Y-%m-%d")


def load_process_config(bucket: str, prefix: str, ptype: str) -> Dict[str, Any]:
    key  = f"{prefix}/gold/{ptype}.json"
    body = boto3.client("s3").get_object(Bucket=bucket, Key=key)["Body"].read()
    return json.loads(body)


def resolve_silver_uri(config: Dict, silver_bucket: str) -> str:
    source_name = config["source"]["source_name"]
    return f"s3://{silver_bucket}/{source_name}/year={year}/month={month}/day={day}/"


def resolve_gold_uri(config: Dict, gold_bucket: str) -> str:
    gold_path = config["target"]["gold_path"]
    return f"s3://{gold_bucket}/{gold_path}/exec={exec_date}/"


def get_new_watermark(df: DataFrame, ts_column: str) -> Optional[datetime]:
    row = df.agg(F.max(ts_column)).collect()[0][0]
    return row


def execute_redshift_load(config: Dict, gold_uri: str) -> None:
    staging_table = config["target"]["staging_table"]
    redshift_utils.truncate_table(workgroup, database, staging_table)
    redshift_utils.copy_from_s3(workgroup, database, staging_table, gold_uri, iam_role, region)
    for sql in config["target"].get("sql_after_copy", []):
        redshift_utils.execute_sql(workgroup, database, sql)


config = load_process_config(args["CONFIG_BUCKET"], args["CONFIG_PREFIX"], process_type)

watermark_cfg = config.get("watermark")
watermark: Optional[datetime] = None
if watermark_cfg and watermark_cfg.get("apply_filter"):
    watermark = redshift_utils.get_watermark(workgroup, database, watermark_cfg["source_name"])

run = PipelineRun(
    job_name=args["JOB_NAME"],
    source_name=process_type,
    workgroup=workgroup,
    database=database,
    watermark_inicio=watermark,
)
control.start_run(run)

try:
    silver_uri = resolve_silver_uri(config, args["SILVER_BUCKET"])
    gold_uri   = resolve_gold_uri(config, args["GOLD_BUCKET"])

    df = s3_utils.read_parquet(spark, silver_uri)
    run.registros_leidos = df.count()

    ctx = TransformContext(execution_dt=execution_dt, watermark=watermark)
    df  = apply_transformations(df, config.get("transformations", []), ctx)

    if config.get("custom_handler"):
        df = invoke_custom_handler(config["custom_handler"], df, config, ctx)

    s3_utils.write_parquet(df, gold_uri, partition_keys=[])

    execute_redshift_load(config, gold_uri)
    run.registros_insertados = df.count()

    if watermark_cfg and watermark_cfg.get("update_after_load"):
        ts_col       = watermark_cfg["timestamp_column"]
        new_watermark = get_new_watermark(df, ts_col)
        if new_watermark:
            redshift_utils.set_watermark(workgroup, database, watermark_cfg["source_name"], new_watermark)
            run.watermark_fin = new_watermark

    run.status = "SUCCESS"

except Exception as exc:
    run.status    = "FAILED"
    run.error_msg = str(exc)
    raise

finally:
    control.finish_run(run)
