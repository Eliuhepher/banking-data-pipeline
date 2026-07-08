"""
Ejemplo de custom_handler: genera salida dual (Parquet Gold + CSV para negocio).
Activar desde el JSON del proceso con:
    "custom_handler": "handlers.dual_output_example"
    "custom_output": { "csv_bucket": "banking-reports-prod", "csv_prefix": "daily/" }
"""
from __future__ import annotations

from typing import TYPE_CHECKING, Any, Dict

if TYPE_CHECKING:
    from pyspark.sql import DataFrame
    from transform_engine import TransformContext


def run(df: "DataFrame", config: Dict[str, Any], ctx: "TransformContext") -> "DataFrame":
    custom_output = config.get("custom_output", {})
    csv_bucket = custom_output.get("csv_bucket")
    csv_prefix = custom_output.get("csv_prefix", "")

    if csv_bucket:
        csv_uri = f"s3://{csv_bucket}/{csv_prefix}{config['process_type']}/"
        (
            df.coalesce(1)
              .write.mode("overwrite")
              .option("header", "true")
              .csv(csv_uri)
        )

    return df
