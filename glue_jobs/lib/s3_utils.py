from __future__ import annotations

from typing import List
from urllib.parse import urlparse

import boto3
import botocore.exceptions
from pyspark.sql import DataFrame, SparkSession


def parse_s3_uri(uri: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    return parsed.netloc, parsed.path.lstrip("/")


def file_exists(uri: str) -> bool:
    bucket, key = parse_s3_uri(uri)
    s3 = boto3.client("s3")
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except botocore.exceptions.ClientError:
        return False


def copy_object(source_uri: str, dest_uri: str) -> None:
    s3 = boto3.client("s3")
    src_bucket, src_key = parse_s3_uri(source_uri)
    dst_bucket, dst_key = parse_s3_uri(dest_uri)
    s3.copy_object(
        CopySource={"Bucket": src_bucket, "Key": src_key},
        Bucket=dst_bucket,
        Key=dst_key,
    )


def read_csv(
    spark: SparkSession,
    uri: str,
    delimiter: str = ",",
    encoding: str = "utf-8",
    infer_schema: bool = False,
) -> DataFrame:
    return (
        spark.read.format("csv")
        .option("header", "true")
        .option("sep", delimiter)
        .option("encoding", encoding)
        .option("inferSchema", str(infer_schema).lower())
        .load(uri)
    )


def write_parquet(
    df: DataFrame,
    base_uri: str,
    partition_keys: List[str],
    mode: str = "overwrite",
) -> int:
    (
        df.write.format("parquet")
        .mode(mode)
        .partitionBy(*partition_keys)
        .save(base_uri)
    )
    return df.count()


def read_parquet(spark: SparkSession, uri: str) -> DataFrame:
    return spark.read.format("parquet").load(uri)
