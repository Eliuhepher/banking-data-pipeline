from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

import boto3
from pyspark.sql.types import (
    BooleanType,
    DataType,
    DecimalType,
    IntegerType,
    LongType,
    StringType,
    StructField,
    StructType,
    TimestampType,
)


@dataclass
class ColumnDef:
    name: str
    spark_type: str
    nullable: bool
    valid_values: Optional[List[str]] = None
    min_value: Optional[float] = None
    precision: Optional[int] = None
    scale: Optional[int] = None


@dataclass
class QualityRules:
    min_valid_rate: float = 0.95
    reject_on_null_pk: bool = True
    reject_date_before: Optional[str] = None
    reject_future_dates: bool = False
    date_columns: List[str] = field(default_factory=list)


@dataclass
class SchemaConfig:
    source_name: str
    version: str
    file_format: str
    delimiter: str
    encoding: str
    partition_keys: List[str]
    primary_key: List[str]
    column_renames: Dict[str, str]
    columns: List[ColumnDef]
    normalizations: Dict[str, Dict[str, str]]
    quality_rules: QualityRules


_SIMPLE_TYPES: Dict[str, DataType] = {
    "StringType":    StringType(),
    "LongType":      LongType(),
    "IntegerType":   IntegerType(),
    "TimestampType": TimestampType(),
    "BooleanType":   BooleanType(),
}


def _resolve_spark_type(col: ColumnDef) -> DataType:
    if col.spark_type == "DecimalType":
        return DecimalType(col.precision or 18, col.scale or 2)
    return _SIMPLE_TYPES[col.spark_type]


def to_spark_schema(config: SchemaConfig) -> StructType:
    return StructType([
        StructField(c.name, _resolve_spark_type(c), c.nullable)
        for c in config.columns
    ])


def load_from_s3(bucket: str, key: str) -> SchemaConfig:
    body = boto3.client("s3").get_object(Bucket=bucket, Key=key)["Body"].read()
    raw: Dict[str, Any] = json.loads(body)

    columns = [ColumnDef(**c) for c in raw["columns"]]
    qr_raw = raw.get("quality_rules", {})
    quality_rules = QualityRules(
        min_valid_rate=qr_raw.get("min_valid_rate", 0.95),
        reject_on_null_pk=qr_raw.get("reject_on_null_pk", True),
        reject_date_before=qr_raw.get("reject_date_before"),
        reject_future_dates=qr_raw.get("reject_future_dates", False),
        date_columns=qr_raw.get("date_columns", []),
    )

    return SchemaConfig(
        source_name=raw["source_name"],
        version=raw["version"],
        file_format=raw["file_format"],
        delimiter=raw["delimiter"],
        encoding=raw["encoding"],
        partition_keys=raw["partition_keys"],
        primary_key=raw["primary_key"],
        column_renames=raw.get("column_renames", {}),
        columns=columns,
        normalizations=raw.get("normalizations", {}),
        quality_rules=quality_rules,
    )
