# GitHub Repository Variables & Secrets

## Variables (Settings → Secrets and variables → Actions → Variables)

| Variable | Descripción | Ejemplo |
|---|---|---|
| `AWS_ACCOUNT_ID` | ID de la cuenta AWS | `123456789012` |
| `AWS_REGION` | Región AWS | `us-east-1` |
| `ENV` | Ambiente | `dev` |
| `TF_STATE_BUCKET` | Bucket para Terraform remote state | `banking-pipeline-tf-state` |
| `ORG` | Organización/usuario en GitHub | `Eliuhepher` |
| `REPO` | Nombre del repositorio | `banking-data-pipeline` |
| `CONFIG_BUCKET` | Bucket S3 para scripts y configs Glue | `banking-pipeline-config-dev` |
| `BRONZE_BUCKET` | Bucket S3 Bronze | `banking-pipeline-bronze-dev` |
| `SILVER_BUCKET` | Bucket S3 Silver | `banking-pipeline-silver-dev` |
| `GOLD_BUCKET` | Bucket S3 Gold | `banking-pipeline-gold-dev` |
| `GLUE_ROLE_ARN` | ARN del IAM role para Glue (output de infra) | `arn:aws:iam::123...` |
| `REDSHIFT_WORKGROUP` | Nombre del workgroup Redshift Serverless | `banking-pipeline-wg-dev` |
| `REDSHIFT_DATABASE` | Base de datos en Redshift | `banking` |
| `SNS_TOPIC_ARN` | ARN del SNS topic (output de monitoring) | `arn:aws:sns:us-east-1:...` |
| `STEP_FUNCTIONS_ARN` | ARN de la State Machine (output de jobs) | `arn:aws:states:us-east-1:...` |
| `ALERT_EMAIL` | Email para alertas SNS | `ops@dominio.com` |
| `ALERT_PHONE` | Teléfono para alertas SMS (vacío = deshabilitado) | `+57300...` |
| `SLACK_CHANNEL` | Canal de Slack para alertas | `#data-alerts` |

## Secrets (Settings → Secrets and variables → Actions → Secrets)

| Secret | Descripción |
|---|---|
| `REDSHIFT_ADMIN_PASSWORD` | Password del usuario admin de Redshift Serverless |
| `SLACK_WEBHOOK_URL` | Webhook URL de la app de Slack |

## Orden de deploy

```
iam → infra → monitoring → jobs
```

`monitoring` debe ejecutarse antes que `jobs` porque `jobs` necesita `SNS_TOPIC_ARN`
(output de monitoring) como variable de entrada.

## Bootstrap (solo primera vez)

Antes del primer push, crear manualmente en AWS:
1. El OIDC provider para GitHub (`token.actions.githubusercontent.com`)
2. Un rol IAM temporal `banking-pipeline-github-iam-bootstrap` con permisos para
   crear roles/policies — este rol se puede eliminar después de que `deploy_iam.yml`
   corra exitosamente por primera vez.
