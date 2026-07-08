from __future__ import annotations

from datetime import datetime
from typing import Dict, List, Tuple

from pyspark.sql import DataFrame
from pyspark.sql import functions as F
from pyspark.sql.types import BooleanType

from schema_loader import SchemaConfig


def _null_pk_filter(config: SchemaConfig) -> F.Column:
    conditions = [F.col(k).isNotNull() for k in config.primary_key]
    combined = conditions[0]
    for c in conditions[1:]:
        combined = combined & c
    return combined


def _valid_values_filter(config: SchemaConfig) -> F.Column:
    condition = F.lit(True)
    for col_def in config.columns:
        if col_def.valid_values:
            condition = condition & F.col(col_def.name).isin(col_def.valid_values)
    return condition


def _min_value_filter(config: SchemaConfig) -> F.Column:
    condition = F.lit(True)
    for col_def in config.columns:
        if col_def.min_value is not None:
            condition = condition & (F.col(col_def.name) >= col_def.min_value)
    return condition


def _date_range_filter(config: SchemaConfig) -> F.Column:
    condition = F.lit(True)
    qr = config.quality_rules
    for col_name in qr.date_columns:
        if qr.reject_date_before:
            floor = datetime.fromisoformat(qr.reject_date_before)
            condition = condition & (
                F.col(col_name).isNull() | (F.col(col_name) >= F.lit(floor))
            )
        if qr.reject_future_dates:
            condition = condition & (
                F.col(col_name).isNull() | (F.col(col_name) <= F.current_timestamp())
            )
    return condition


def validate(
    df: DataFrame,
    config: SchemaConfig,
) -> Tuple[DataFrame, DataFrame, Dict[str, int]]:
    """
    Separa df en (valid, rejected) aplicando las reglas del schema.
    Retorna también un dict con conteos.
    """
    qr = config.quality_rules

    is_valid = F.lit(True)
    if qr.reject_on_null_pk:
        is_valid = is_valid & _null_pk_filter(config)
    is_valid = is_valid & _valid_values_filter(config)
    is_valid = is_valid & _min_value_filter(config)
    is_valid = is_valid & _date_range_filter(config)

    df_flagged = df.withColumn("_is_valid", is_valid.cast(BooleanType()))

    valid_df    = df_flagged.filter(F.col("_is_valid")).drop("_is_valid")
    rejected_df = df_flagged.filter(~F.col("_is_valid")).drop("_is_valid")

    total     = df.count()
    n_valid   = valid_df.count()
    n_rejected = rejected_df.count()

    valid_rate = n_valid / total if total > 0 else 0.0
    if valid_rate < qr.min_valid_rate:
        raise ValueError(
            f"Tasa de registros válidos {valid_rate:.2%} por debajo del mínimo "
            f"requerido {qr.min_valid_rate:.2%}"
        )

    metrics = {
        "registros_leidos":     total,
        "registros_validos":    n_valid,
        "registros_rechazados": n_rejected,
    }
    return valid_df, rejected_df, metrics
