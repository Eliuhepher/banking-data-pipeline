"""
bronze_to_silver.py — Transformación Bronze → Silver
Responsabilidad única: limpiar, tipar, normalizar y validar los datos.
No escribe a Redshift. Salida: Parquet particionado en Silver.
"""
import sys
from typing import Dict

from awsglue.context import GlueContext
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import DataFrame
from pyspark.sql import functions as F

import control
import s3_utils
import validation
from control import PipelineRun
from schema_loader import SchemaConfig, load_from_s3, to_spark_schema

REQUIRED_ARGS = [
    "JOB_NAME",
    "SOURCE_NAME",
    "BRONZE_BUCKET",
    "SILVER_BUCKET",
    "SCHEMA_BUCKET",
    "SCHEMA_KEY",
    "EXECUTION_DATE",
    "REDSHIFT_WORKGROUP",
    "REDSHIFT_DATABASE",
]

sc    = SparkContext()
glue  = GlueContext(sc)
spark = glue.spark_session

args = getResolvedOptions(sys.argv, REQUIRED_ARGS)

source_name  = args["SOURCE_NAME"]
exec_date    = args["EXECUTION_DATE"]
year, month, day = exec_date.split("-")

bronze_uri = (
    f"s3://{args['BRONZE_BUCKET']}/{source_name}"
    f"/year={year}/month={month}/day={day}/"
)
silver_uri = f"s3://{args['SILVER_BUCKET']}/{source_name}/"

schema_config: SchemaConfig = load_from_s3(args["SCHEMA_BUCKET"], args["SCHEMA_KEY"])

run = PipelineRun(
    job_name=args["JOB_NAME"],
    source_name=source_name,
    workgroup=args["REDSHIFT_WORKGROUP"],
    database=args["REDSHIFT_DATABASE"],
)
control.start_run(run)


def rename_columns(df: DataFrame, renames: Dict[str, str]) -> DataFrame:
    for old, new in renames.items():
        if old in df.columns:
            df = df.withColumnRenamed(old, new)
    return df


def normalize_strings(df: DataFrame, config: SchemaConfig) -> DataFrame:
    for col_name, mapping in config.normalizations.items():
        if col_name not in df.columns:
            continue
        expr = F.col(col_name)
        for bad, good in mapping.items():
            expr = F.when(F.col(col_name) == bad, good).otherwise(expr)
        df = df.withColumn(col_name, expr)
    return df


def cast_columns(df: DataFrame, config: SchemaConfig) -> DataFrame:
    spark_schema = to_spark_schema(config)
    for field in spark_schema.fields:
        df = df.withColumn(field.name, F.col(field.name).cast(field.dataType))
    return df


def add_partition_columns(df: DataFrame, year: str, month: str, day: str) -> DataFrame:
    return (
        df.withColumn("year",  F.lit(year))
          .withColumn("month", F.lit(month))
          .withColumn("day",   F.lit(day))
    )


try:
    raw_df = s3_utils.read_csv(
        spark,
        bronze_uri,
        delimiter=schema_config.delimiter,
        encoding=schema_config.encoding,
    )

    df = rename_columns(raw_df, schema_config.column_renames)
    df = normalize_strings(df, schema_config)
    df = cast_columns(df, schema_config)
    df = add_partition_columns(df, year, month, day)

    valid_df, rejected_df, metrics = validation.validate(df, schema_config)

    run.registros_leidos     = metrics["registros_leidos"]
    run.registros_validos    = metrics["registros_validos"]
    run.registros_rechazados = metrics["registros_rechazados"]

    if rejected_df.count() > 0:
        rejected_uri = f"s3://{args['SILVER_BUCKET']}/_rejected/{source_name}/year={year}/month={month}/day={day}/"
        s3_utils.write_parquet(rejected_df, rejected_uri, schema_config.partition_keys)

    s3_utils.write_parquet(valid_df, silver_uri, schema_config.partition_keys)

    run.status = "SUCCESS"

except Exception as exc:
    run.status    = "FAILED"
    run.error_msg = str(exc)
    raise

finally:
    control.finish_run(run)
