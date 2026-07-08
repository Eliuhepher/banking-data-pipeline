# Banking Data Pipeline

Pipeline de datos para análisis del comportamiento de clientes bancarios en productos financieros. Implementado en AWS como equivalente funcional a la arquitectura original en GCP.

**Prueba Técnica — Senior Data Specialist · Marketing & Analytics**

---

## Arquitectura

```
CSV (origen)
    |
    v
[ingest.py]
    |
    v
S3 BRONZE          raw/ — dato como llegó, sin transformar
    |
[bronze_to_silver.py]  renombrado · cast · validación de calidad · normalización UTF-8
    |
    v
S3 SILVER          Parquet/snappy · particionado year/month/day
    |
[gold_job.py]      config-driven: un job para todos los procesos Gold
    |
    v
S3 GOLD            Parquet por proceso
    |
    v
Redshift Serverless  Star Schema: fact_transacciones + dim_cliente (SCD2) + dim_producto + dim_tiempo
```

**Orquestación:** AWS Step Functions con Map State (dims en paralelo, fact secuencial)

**Trigger:** EventBridge cron 8:30 AM → Lambda file_checker → Step Functions

**Alertas:** SNS fanout → email directo + SMS directo + Lambda → Slack webhook

**CI/CD:** GitHub Actions con OIDC (zero credenciales almacenadas)

---

## Stack

| Capa | Servicio |
|---|---|
| Data Lake | Amazon S3 (Bronze / Silver / Gold) |
| ETL | AWS Glue PySpark + Python Shell |
| Data Warehouse | Amazon Redshift Serverless (8 RPU) |
| Orquestación | AWS Step Functions |
| Monitoreo | Amazon EventBridge + SNS + CloudWatch |
| Alertas Slack | AWS Lambda (Python 3.12) |
| Infraestructura | Terraform 1.7+ |
| CI/CD | GitHub Actions + OIDC |
| Secretos | AWS Secrets Manager |

---

## Estructura del repositorio

```
banking-data-pipeline/
├── glue_jobs/
│   ├── ingest.py                  # Copia CSV a Bronze (Python Shell)
│   ├── bronze_to_silver.py        # Limpieza y tipado (PySpark)
│   ├── gold_job.py                # Job genérico config-driven (PySpark)
│   ├── lib/                       # Módulos reutilizables (SRP)
│   │   ├── schema_loader.py       # Deserialización de schema JSON
│   │   ├── validation.py          # Reglas de calidad de datos
│   │   ├── s3_utils.py            # I/O sobre S3
│   │   ├── redshift_utils.py      # Redshift Data API (boto3)
│   │   ├── control.py             # Tabla de auditoría pipeline_run
│   │   └── transform_engine.py    # Strategy pattern para transformaciones
│   ├── handlers/                  # custom_handler opcionales por proceso
│   ├── schema/                    # Contratos de calidad por fuente (JSON)
│   └── process_configs/gold/      # Config declarativa por proceso Gold (JSON)
├── lambdas/
│   ├── file_checker/              # Verifica archivo en Bronze, dispara Step Functions
│   └── slack_notifier/            # Traduce SNS → Slack webhook
├── sql/
│   ├── ddl/                       # DDL de Redshift (ejecutar en orden 01→03)
│   └── queries/                   # Consultas analíticas (Parte 3)
├── step_functions/
│   └── banking_pipeline.asl.json  # ASL con templatefile variables de Terraform
├── terraform/
│   ├── bootstrap/                 # Setup de una sola vez (ver Despliegue paso 0)
│   ├── _globals/                  # Variables compartidas
│   ├── iam/                       # OIDC provider + roles por workflow
│   ├── infra/                     # S3 buckets + VPC + Redshift Serverless
│   ├── jobs/                      # Glue jobs + Step Functions
│   └── monitoring/                # SNS + Lambdas + EventBridge + CloudWatch
└── .github/
    ├── workflows/                 # 4 workflows OIDC (deploy order: iam→infra→monitoring→jobs)
    └── GITHUB_VARS.md             # Lista completa de variables y secrets requeridos
```

---

## Despliegue

### Requisitos previos

- AWS CLI v2 configurado con un perfil con permisos de administrador
- Terraform >= 1.7.0
- Git

### Paso 0 — Bootstrap (una sola vez, local)

Crea el bucket de Terraform remote state, el OIDC provider de GitHub y el role temporal que usa el primer workflow.

```bash
cd terraform/bootstrap

terraform init

terraform apply \
  -var="github_org=TU_GITHUB_ORG" \
  -var="github_repo=banking-data-pipeline" \
  -var="aws_account_id=$(aws sts get-caller-identity --query Account --output text)"
```

Guarda los outputs:

```
tf_state_bucket    = "banking-pipeline-tf-state"
oidc_provider_arn  = "arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
bootstrap_role_arn = "arn:aws:iam::ACCOUNT:role/banking-pipeline-github-iam-bootstrap"
```

### Paso 1 — Configurar GitHub

En **Settings → Secrets and variables → Actions** del repositorio:

**Variables** (ver `.github/GITHUB_VARS.md` para la lista completa):

| Variable | Valor |
|---|---|
| `AWS_ACCOUNT_ID` | ID de la cuenta AWS |
| `AWS_REGION` | `us-east-1` |
| `ENV` | `dev` |
| `TF_STATE_BUCKET` | output del paso 0 |
| `GITHUB_ORG` | tu organización/usuario de GitHub |
| `GITHUB_REPO` | `banking-data-pipeline` |

Las variables `CONFIG_BUCKET`, `BRONZE_BUCKET`, `SILVER_BUCKET`, `GOLD_BUCKET`, `GLUE_ROLE_ARN`, `REDSHIFT_WORKGROUP`, `REDSHIFT_DATABASE` se obtienen de los outputs de `terraform/infra` (disponibles después del paso 2).

Las variables `SNS_TOPIC_ARN` y `STEP_FUNCTIONS_ARN` se obtienen de los outputs de `monitoring` y `jobs` respectivamente.

**Secrets:**

| Secret | Descripción |
|---|---|
| `REDSHIFT_ADMIN_PASSWORD` | Password para el admin de Redshift Serverless |
| `SLACK_WEBHOOK_URL` | Webhook URL de la app de Slack (opcional) |

### Paso 2 — Deploy con GitHub Actions

El deploy se dispara automáticamente con cada push a `main` en los paths correspondientes. Para el primer deploy, hacer un push con los archivos de terraform:

```bash
git add .
git commit -m "feat: initial deploy"
git push origin main
```

**Orden de ejecución de los workflows:**

```
deploy_iam.yml       crea OIDC roles
      |
deploy_infra.yml     crea S3 + VPC + Redshift Serverless
      |
deploy_monitoring.yml  crea SNS + Lambdas + EventBridge     <-- debe correr antes que jobs
      |
deploy_jobs.yml      sube scripts a S3 + crea Glue jobs + Step Functions
```

Después de que `deploy_infra` corra, actualizar las variables de GitHub con los bucket names y ARNs de los outputs (`terraform output` en el runner o desde la consola de AWS).

### Paso 3 — DDL en Redshift

Ejecutar los scripts DDL en orden contra el workgroup de Redshift Serverless (desde Query Editor v2 en la consola AWS o con el CLI):

```bash
# Usando Redshift Data API vía CLI
aws redshift-data execute-statement \
  --workgroup-name banking-pipeline-wg-dev \
  --database banking \
  --sql "$(cat sql/ddl/01_control.sql)"

aws redshift-data execute-statement \
  --workgroup-name banking-pipeline-wg-dev \
  --database banking \
  --sql "$(cat sql/ddl/02_dimensions.sql)"

aws redshift-data execute-statement \
  --workgroup-name banking-pipeline-wg-dev \
  --database banking \
  --sql "$(cat sql/ddl/03_fact.sql)"
```

### Paso 4 — Ejecutar el pipeline

Subir el archivo CSV de transacciones al path que espera el `file_checker`:

```bash
aws s3 cp transacciones.csv \
  s3://banking-pipeline-bronze-dev/transacciones/year=2025/month=06/day=30/transacciones.csv
```

El pipeline se dispara automáticamente a las 8:30 AM (EventBridge). Para ejecución inmediata, invocar el Lambda manualmente:

```bash
aws lambda invoke \
  --function-name banking-pipeline-file-checker-dev \
  --payload '{}' \
  response.json
```

O iniciar el Step Functions directamente:

```bash
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:us-east-1:ACCOUNT:stateMachine:banking-pipeline-dev \
  --input '{"execution_date":"2025-06-30"}'
```

---

## Monitoreo

- **CloudWatch Logs:** grupos `/aws/glue/banking-pipeline-*` y `/aws/lambda/banking-pipeline-*` (retención 30 y 14 días respectivamente)
- **CloudWatch Alarm:** `banking-pipeline-sf-failures` — alerta si Step Functions registra >= 1 ejecución fallida
- **Tabla de auditoría:** `control.pipeline_run` en Redshift — registra métricas por ejecución (registros leídos/válidos/rechazados/insertados, watermark, status, error)

```sql
-- Ver estado de las últimas ejecuciones
SELECT job_name, source_name, status,
       registros_leidos, registros_validos, registros_rechazados,
       watermark_inicio, watermark_fin, ts_inicio, ts_fin
FROM control.pipeline_run
ORDER BY ts_inicio DESC
LIMIT 20;
```

---

## Consultas analíticas (Parte 3)

```bash
# Clientes más rentables (top 100, penalización por riesgo crediticio)
cat sql/queries/clientes_rentables.sql
```

---

## Decisiones de diseño relevantes

- **Star Schema sobre Snowflake:** menos JOINs, mejor rendimiento en herramientas BI (QuickSight, Power BI)
- **Medallion Architecture:** Bronze reprocesable sin volver al origen; Silver como contrato de calidad; Gold como única fuente para el DWH
- **Config-driven ELT (gold_job.py):** agregar un nuevo proceso Gold = agregar un JSON, sin modificar código (Open/Closed Principle)
- **Watermark incremental:** costo proporcional al delta, no al histórico total; idempotente
- **Redshift Data API sobre JDBC:** compatible con Serverless sin NAT Gateway, sin gestión de drivers
- **SCD Type 2 con row_hash:** SHA-256 de atributos clave; detección de cambios sin comparar campo a campo
- **OIDC para CI/CD:** zero credenciales de larga duración; trust scoped a `refs/heads/main` (PRs de forks excluidos)
