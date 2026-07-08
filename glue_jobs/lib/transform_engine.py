from __future__ import annotations

import importlib
from datetime import datetime
from typing import Any, Dict, List, Optional

from pyspark.sql import DataFrame
from pyspark.sql import functions as F
from pyspark.sql.types import BooleanType, IntegerType, StringType


class TransformContext:
    """Valores de runtime que los transforms pueden necesitar."""
    def __init__(
        self,
        execution_dt: Optional[datetime] = None,
        watermark: Optional[datetime] = None,
    ):
        self.execution_dt = execution_dt
        self.watermark = watermark


def _select(df: DataFrame, t: Dict) -> DataFrame:
    return df.select(*t["columns"])


def _deduplicate(df: DataFrame, t: Dict) -> DataFrame:
    return df.dropDuplicates(t["keys"])


def _add_hash(df: DataFrame, t: Dict) -> DataFrame:
    cols_expr = F.concat_ws("|", *[F.col(c).cast(StringType()) for c in t["columns"]])
    return df.withColumn(t["output_col"], F.sha2(cols_expr, 256))


def _add_execution_timestamp(df: DataFrame, t: Dict, ctx: TransformContext) -> DataFrame:
    if ctx.execution_dt is None:
        raise ValueError("add_execution_timestamp requiere execution_dt en el contexto")
    return df.withColumn(t["output_col"], F.lit(ctx.execution_dt))


def _to_date(df: DataFrame, t: Dict) -> DataFrame:
    return df.withColumn(t["column"], F.to_date(F.col(t["column"])))


def _add_date_key(df: DataFrame, t: Dict) -> DataFrame:
    # genera entero YYYYMMDD desde una columna date/timestamp
    return df.withColumn(
        t["output_col"],
        F.date_format(F.col(t["from_column"]), "yyyyMMdd").cast(IntegerType()),
    )


def _generate_date_parts(df: DataFrame, t: Dict) -> DataFrame:
    col = t["from_column"]
    return (
        df.withColumn("anio",             F.year(col).cast("smallint"))
          .withColumn("mes",              F.month(col).cast("smallint"))
          .withColumn("dia",              F.dayofmonth(col).cast("smallint"))
          .withColumn("trimestre",        F.quarter(col).cast("smallint"))
          .withColumn("nombre_mes",       F.date_format(col, "MMMM"))
          .withColumn("dia_semana",       F.date_format(col, "EEEE"))
          .withColumn("es_fin_de_semana", F.dayofweek(col).isin([1, 7]).cast(BooleanType()))
    )


def _watermark_filter(df: DataFrame, t: Dict, ctx: TransformContext) -> DataFrame:
    if ctx.watermark is None:
        return df
    return df.filter(F.col(t["column"]) > F.lit(ctx.watermark))


def _cast(df: DataFrame, t: Dict) -> DataFrame:
    return df.withColumn(t["column"], F.col(t["column"]).cast(t["target_type"]))


def _rename(df: DataFrame, t: Dict) -> DataFrame:
    return df.withColumnRenamed(t["from"], t["to"])


_HANDLERS = {
    "select":                  lambda df, t, ctx: _select(df, t),
    "deduplicate":             lambda df, t, ctx: _deduplicate(df, t),
    "add_hash":                lambda df, t, ctx: _add_hash(df, t),
    "add_execution_timestamp": lambda df, t, ctx: _add_execution_timestamp(df, t, ctx),
    "to_date":                 lambda df, t, ctx: _to_date(df, t),
    "add_date_key":            lambda df, t, ctx: _add_date_key(df, t),
    "generate_date_parts":     lambda df, t, ctx: _generate_date_parts(df, t),
    "watermark_filter":        lambda df, t, ctx: _watermark_filter(df, t, ctx),
    "cast":                    lambda df, t, ctx: _cast(df, t),
    "rename":                  lambda df, t, ctx: _rename(df, t),
}


def apply_transformations(
    df: DataFrame,
    transformations: List[Dict[str, Any]],
    ctx: Optional[TransformContext] = None,
) -> DataFrame:
    if ctx is None:
        ctx = TransformContext()
    for t in transformations:
        t_type = t["type"]
        handler = _HANDLERS.get(t_type)
        if handler is None:
            raise ValueError(f"Tipo de transformacion no soportado: '{t_type}'")
        df = handler(df, t, ctx)
    return df


def invoke_custom_handler(
    handler_path: str,
    df: DataFrame,
    config: Dict[str, Any],
    ctx: TransformContext,
) -> DataFrame:
    """
    Importa dinámicamente handler_path (ej: 'handlers.dual_output') y llama run(df, config, ctx).
    El handler puede producir salidas adicionales (CSV, API calls, etc.) y debe retornar el df.
    """
    mod = importlib.import_module(handler_path)
    return mod.run(df, config, ctx)
