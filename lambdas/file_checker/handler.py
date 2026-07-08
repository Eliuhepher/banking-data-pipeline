"""
file_checker — triggered by EventBridge at 08:30 AM
Verifica si el archivo esperado existe en S3 Bronze.
Si existe: inicia la Step Function con los parámetros de ejecución.
Si no existe: publica alerta en SNS (→ email, SMS, Slack).
"""
import json
import os
from datetime import datetime, timezone

import boto3
import botocore.exceptions

BRONZE_BUCKET  = os.environ["BRONZE_BUCKET"]
EXPECTED_KEY   = os.environ["EXPECTED_S3_KEY"]
SF_ARN         = os.environ["STEP_FUNCTIONS_ARN"]
SNS_TOPIC_ARN  = os.environ["SNS_TOPIC_ARN"]
SOURCE_NAME    = os.environ["SOURCE_NAME"]
ENV            = os.environ["ENV"]

s3  = boto3.client("s3")
sf  = boto3.client("stepfunctions")
sns = boto3.client("sns")

DIMENSION_CONFIGS = [
    {"process_type": "dim_cliente"},
    {"process_type": "dim_producto"},
    {"process_type": "dim_tiempo"},
]

HECHOS_CONFIGS = [
    {"process_type": "fact_transacciones"},
]


def _file_exists(bucket: str, key: str) -> bool:
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except botocore.exceptions.ClientError:
        return False


def handler(event, context):
    execution_date = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    if _file_exists(BRONZE_BUCKET, EXPECTED_KEY):
        sf.start_execution(
            stateMachineArn=SF_ARN,
            name=f"pipeline-{execution_date}-{context.aws_request_id[:8]}",
            input=json.dumps({
                "execution_date":     execution_date,
                "source_name":        SOURCE_NAME,
                "input_s3_uri":       f"s3://{BRONZE_BUCKET}/{EXPECTED_KEY}",
                "env":                ENV,
                "dimension_configs":  DIMENSION_CONFIGS,
                "hechos_configs":     HECHOS_CONFIGS,
            }),
        )
        return {"status": "PIPELINE_TRIGGERED", "execution_date": execution_date}

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[{ENV.upper()}] Archivo no encontrado en S3 Bronze",
        Message=(
            f"El archivo esperado no llegó a tiempo.\n\n"
            f"Ruta: s3://{BRONZE_BUCKET}/{EXPECTED_KEY}\n"
            f"Fecha: {execution_date}\n\n"
            f"Si el archivo no llega en los próximos 30 minutos, revisa el proceso fuente."
        ),
    )
    return {"status": "ALERT_SENT", "execution_date": execution_date}
