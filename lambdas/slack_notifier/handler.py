"""
slack_notifier — suscriptor de SNS que reenvía alertas a un canal de Slack.
SNS → Lambda → Slack Incoming Webhook.
Usar junto con suscripciones de email y SMS en el mismo topic para cobertura completa.
"""
import json
import os
import urllib.request
from typing import Any, Dict

SLACK_WEBHOOK_URL = os.environ["SLACK_WEBHOOK_URL"]
SLACK_CHANNEL     = os.environ.get("SLACK_CHANNEL", "#data-alerts")
ENV               = os.environ.get("ENV", "prod")

COLOR_MAP = {
    "FAILED":  "danger",
    "WARNING": "warning",
    "INFO":    "good",
}


def _build_payload(subject: str, message: str) -> Dict[str, Any]:
    color = next((v for k, v in COLOR_MAP.items() if k in subject.upper()), "danger")
    return {
        "channel":    SLACK_CHANNEL,
        "username":   "Banking Pipeline",
        "attachments": [
            {
                "color":  color,
                "title":  subject,
                "text":   message,
                "footer": f"banking-pipeline | {ENV}",
            }
        ],
    }


def _post_to_slack(payload: Dict) -> None:
    data = json.dumps(payload).encode("utf-8")
    req  = urllib.request.Request(
        SLACK_WEBHOOK_URL,
        data=data,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        if resp.status != 200:
            raise RuntimeError(f"Slack respondió {resp.status}: {resp.read()}")


def handler(event, context):
    for record in event.get("Records", []):
        sns_msg = record["Sns"]
        subject = sns_msg.get("Subject", "Alerta sin título")
        message = sns_msg.get("Message", "")
        payload = _build_payload(subject, message)
        _post_to_slack(payload)
    return {"status": "OK"}
