"""
silver_to_gold.py — Carga dimensional Silver → Gold → Redshift
Responsabilidad única: construir el modelo dimensional, escribir a Gold (Parquet)
y ejecutar COPY + SQL de merge en Redshift Serverless.
"""
import calendar
import sys
from datetime import date, datetime

from awsglue.context import GlueContext
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import DataFrame
from pyspark.sql import functions as F
from pyspark.sql.types import BooleanType, IntegerType, StringType

import control
import redshift_utils
import s3_utils
from control import PipelineRun
from schema_loader import load_from_s3

REQUIRED_ARGS = [
    "JOB_NAME",
    "SOURCE_NAME",
    "SILVER_BUCKET",
    "GOLD_BUCKET",
    "SCHEMA_BUCKET",
    "SCHEMA_KEY",
    "EXECUTION_DATE",
    "REDSHIFT_WORKGROUP",
    "REDSHIFT_DATABASE",
    "REDSHIFT_IAM_ROLE",
    "AWS_REGION",
]

TRACKED_CLIENT_COLS = [
    "nombres", "ciudad", "direccion_cliente", "telefono_cliente",
    "correo_cliente", "fecha_de_nacimiento",
    "reporte_centrales_riesgo", "monto_reporte_riesgo", "tiempo_mora_dias",
]

sc    = SparkContext()
glue  = GlueContext(sc)
spark = glue.spark_session

args = getResolvedOptions(sys.argv, REQUIRED_ARGS)

source_name = args["SOURCE_NAME"]
exec_date   = args["EXECUTION_DATE"]
year, month, day = exec_date.split("-")
exec_dt     = datetime.strptime(exec_date, "%Y-%m-%d")

workgroup = args["REDSHIFT_WORKGROUP"]
database  = args["REDSHIFT_DATABASE"]
iam_role  = args["REDSHIFT_IAM_ROLE"]
region    = args["AWS_REGION"]

silver_uri     = f"s3://{args['SILVER_BUCKET']}/{source_name}/year={year}/month={month}/day={day}/"
gold_base_uri  = f"s3://{args['GOLD_BUCKET']}"

schema_config = load_from_s3(args["SCHEMA_BUCKET"], args["SCHEMA_KEY"])
watermark     = redshift_utils.get_watermark(workgroup, database, source_name)

run = PipelineRun(
    job_name=args["JOB_NAME"],
    source_name=source_name,
    workgroup=workgroup,
    database=database,
    watermark_inicio=watermark,
)
control.start_run(run)


def build_dim_tiempo(df: DataFrame) -> DataFrame:
    dates_df = df.select(
        F.to_date(F.col("fecha_hora")).alias("fecha")
    ).distinct()

    return dates_df.select(
        F.date_format(F.col("fecha"), "yyyyMMdd").cast(IntegerType()).alias("sk_tiempo"),
        F.col("fecha"),
        F.year("fecha").cast("smallint").alias("anio"),
        F.month("fecha").cast("smallint").alias("mes"),
        F.dayofmonth("fecha").cast("smallint").alias("dia"),
        F.quarter("fecha").cast("smallint").alias("trimestre"),
        F.date_format(F.col("fecha"), "MMMM").alias("nombre_mes"),
        F.date_format(F.col("fecha"), "EEEE").alias("dia_semana"),
        (F.dayofweek("fecha").isin([1, 7])).cast(BooleanType()).alias("es_fin_de_semana"),
    )


def build_stg_dim_cliente(df: DataFrame, load_ts: datetime) -> DataFrame:
    hash_expr = F.sha2(
        F.concat_ws("|", *[F.col(c).cast(StringType()) for c in TRACKED_CLIENT_COLS]),
        256,
    )
    return (
        df.select(
            "tipo_de_identificacion",
            "numero_de_identificacion",
            "nombres",
            "ciudad",
            "direccion_cliente",
            "telefono_cliente",
            "correo_cliente",
            F.to_date("fecha_de_nacimiento").alias("fecha_de_nacimiento"),
            "reporte_centrales_riesgo",
            "monto_reporte_riesgo",
            "tiempo_mora_dias",
        )
        .distinct()
        .withColumn("row_hash", hash_expr)
        .withColumn("fecha_inicio", F.lit(load_ts))
    )


def build_stg_fact(df: DataFrame) -> DataFrame:
    return df.select(
        "tipo_de_identificacion",
        "numero_de_identificacion",
        "tipo_de_producto",
        "numero_de_cuenta",
        "tipo_transaccion",
        "monto_transaccion",
        "fecha_hora",
    ).filter(F.col("fecha_hora") > F.lit(watermark))


def merge_scd2(workgroup: str, database: str, s3_path: str, iam_role: str, region: str) -> dict:
    redshift_utils.truncate_table(workgroup, database, "dw.stg_dim_cliente")
    redshift_utils.copy_from_s3(workgroup, database, "dw.stg_dim_cliente", s3_path, iam_role, region)

    redshift_utils.execute_sql(workgroup, database, """
        UPDATE dw.dim_cliente dc
        SET
            fecha_fin = stg.fecha_inicio - INTERVAL '1 second',
            es_activo = FALSE
        FROM dw.stg_dim_cliente stg
        WHERE dc.numero_de_identificacion = stg.numero_de_identificacion
          AND dc.tipo_de_identificacion   = stg.tipo_de_identificacion
          AND dc.es_activo = TRUE
          AND dc.row_hash != stg.row_hash
    """)

    redshift_utils.execute_sql(workgroup, database, """
        INSERT INTO dw.dim_cliente (
            tipo_de_identificacion, numero_de_identificacion, nombres, ciudad,
            direccion_cliente, telefono_cliente, correo_cliente, fecha_de_nacimiento,
            reporte_centrales_riesgo, monto_reporte_riesgo, tiempo_mora_dias,
            row_hash, fecha_inicio, fecha_fin, es_activo
        )
        SELECT
            stg.tipo_de_identificacion, stg.numero_de_identificacion, stg.nombres, stg.ciudad,
            stg.direccion_cliente, stg.telefono_cliente, stg.correo_cliente, stg.fecha_de_nacimiento,
            stg.reporte_centrales_riesgo, stg.monto_reporte_riesgo, stg.tiempo_mora_dias,
            stg.row_hash, stg.fecha_inicio, NULL, TRUE
        FROM dw.stg_dim_cliente stg
        WHERE NOT EXISTS (
            SELECT 1 FROM dw.dim_cliente dc
            WHERE dc.numero_de_identificacion = stg.numero_de_identificacion
              AND dc.tipo_de_identificacion   = stg.tipo_de_identificacion
              AND dc.es_activo = TRUE
              AND dc.row_hash  = stg.row_hash
        )
    """)

    rows = redshift_utils.query_rows(workgroup, database,
        "SELECT COUNT(*) FROM dw.stg_dim_cliente")
    return {"registros_actualizados": int(rows[0][0]["longValue"])}


def load_productos(workgroup: str, database: str, s3_path: str, iam_role: str, region: str) -> None:
    redshift_utils.truncate_table(workgroup, database, "dw.stg_dim_producto")
    redshift_utils.copy_from_s3(workgroup, database, "dw.stg_dim_producto", s3_path, iam_role, region)
    redshift_utils.execute_sql(workgroup, database, """
        INSERT INTO dw.dim_producto (tipo_de_producto)
        SELECT DISTINCT stg.tipo_de_producto
        FROM dw.stg_dim_producto stg
        WHERE NOT EXISTS (
            SELECT 1 FROM dw.dim_producto p WHERE p.tipo_de_producto = stg.tipo_de_producto
        )
    """)


def load_tiempo(workgroup: str, database: str, s3_path: str, iam_role: str, region: str) -> None:
    redshift_utils.truncate_table(workgroup, database, "dw.stg_dim_tiempo")
    redshift_utils.copy_from_s3(workgroup, database, "dw.stg_dim_tiempo", s3_path, iam_role, region)
    redshift_utils.execute_sql(workgroup, database, """
        INSERT INTO dw.dim_tiempo
        SELECT stg.*
        FROM dw.stg_dim_tiempo stg
        WHERE NOT EXISTS (
            SELECT 1 FROM dw.dim_tiempo t WHERE t.sk_tiempo = stg.sk_tiempo
        )
    """)


def load_fact(workgroup: str, database: str, s3_path: str, iam_role: str, region: str) -> int:
    redshift_utils.truncate_table(workgroup, database, "dw.stg_fact_transacciones")
    redshift_utils.copy_from_s3(workgroup, database, "dw.stg_fact_transacciones", s3_path, iam_role, region)
    redshift_utils.execute_sql(workgroup, database, """
        INSERT INTO dw.fact_transacciones (
            sk_cliente, sk_producto, sk_tiempo,
            numero_de_cuenta, tipo_transaccion, monto_transaccion, fecha_hora
        )
        SELECT
            c.sk_cliente,
            p.sk_producto,
            CAST(TO_CHAR(f.fecha_hora, 'YYYYMMDD') AS INTEGER),
            f.numero_de_cuenta,
            f.tipo_transaccion,
            f.monto_transaccion,
            f.fecha_hora
        FROM dw.stg_fact_transacciones f
        JOIN dw.dim_cliente c
            ON  c.numero_de_identificacion = f.numero_de_identificacion
            AND c.tipo_de_identificacion   = f.tipo_de_identificacion
            AND c.es_activo = TRUE
        JOIN dw.dim_producto p
            ON p.tipo_de_producto = f.tipo_de_producto
    """)
    rows = redshift_utils.query_rows(workgroup, database,
        "SELECT COUNT(*) FROM dw.stg_fact_transacciones")
    return int(rows[0][0]["longValue"])


try:
    silver_df = s3_utils.read_parquet(spark, silver_uri)
    new_watermark = silver_df.agg(F.max("fecha_hora")).collect()[0][0]

    # dim_tiempo
    dim_tiempo_df = build_dim_tiempo(silver_df)
    gold_tiempo_uri = f"{gold_base_uri}/stg_dim_tiempo/exec={exec_date}/"
    s3_utils.write_parquet(dim_tiempo_df, gold_tiempo_uri, [])
    load_tiempo(workgroup, database, gold_tiempo_uri, iam_role, region)

    # stg_dim_producto
    prod_df = silver_df.select("tipo_de_producto").distinct()
    gold_prod_uri = f"{gold_base_uri}/stg_dim_producto/exec={exec_date}/"
    s3_utils.write_parquet(prod_df, gold_prod_uri, [])
    load_productos(workgroup, database, gold_prod_uri, iam_role, region)

    # stg_dim_cliente (SCD2)
    cliente_df = build_stg_dim_cliente(silver_df, exec_dt)
    gold_cli_uri = f"{gold_base_uri}/stg_dim_cliente/exec={exec_date}/"
    s3_utils.write_parquet(cliente_df, gold_cli_uri, [])
    scd2_metrics = merge_scd2(workgroup, database, gold_cli_uri, iam_role, region)
    run.registros_actualizados = scd2_metrics["registros_actualizados"]

    # stg_fact_transacciones
    fact_df = build_stg_fact(silver_df)
    gold_fact_uri = f"{gold_base_uri}/stg_fact_transacciones/exec={exec_date}/"
    s3_utils.write_parquet(fact_df, gold_fact_uri, [])
    run.registros_insertados = load_fact(workgroup, database, gold_fact_uri, iam_role, region)

    run.registros_leidos = silver_df.count()
    run.watermark_fin    = new_watermark
    run.status           = "SUCCESS"

    redshift_utils.set_watermark(workgroup, database, source_name, new_watermark)

except Exception as exc:
    run.status    = "FAILED"
    run.error_msg = str(exc)
    raise

finally:
    control.finish_run(run)
