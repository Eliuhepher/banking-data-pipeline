"""
ingest.py — Bronze landing
Responsabilidad única: copiar el archivo fuente a la zona Bronze de S3
con particionamiento por fecha de ejecución, sin transformaciones.
"""
import sys

import boto3
from awsglue.utils import getResolvedOptions

REQUIRED_ARGS = [
    "JOB_NAME",
    "SOURCE_NAME",
    "INPUT_S3_URI",
    "BRONZE_BUCKET",
    "EXECUTION_DATE",
]

args = getResolvedOptions(sys.argv, REQUIRED_ARGS)

source_name    = args["SOURCE_NAME"]
input_uri      = args["INPUT_S3_URI"]
bronze_bucket  = args["BRONZE_BUCKET"]
execution_date = args["EXECUTION_DATE"]   # formato: YYYY-MM-DD

year, month, day = execution_date.split("-")

src_bucket = input_uri.replace("s3://", "").split("/")[0]
src_key    = "/".join(input_uri.replace("s3://", "").split("/")[1:])
dst_key    = f"{source_name}/year={year}/month={month}/day={day}/{source_name}.csv"

s3 = boto3.client("s3")

s3.head_object(Bucket=src_bucket, Key=src_key)

s3.copy_object(
    CopySource={"Bucket": src_bucket, "Key": src_key},
    Bucket=bronze_bucket,
    Key=dst_key,
)

print(f"Bronze landing OK: s3://{bronze_bucket}/{dst_key}")
