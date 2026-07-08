terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    key    = "jobs/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  prefix        = "${var.project_name}-${var.env}"
  scripts_s3    = "s3://${var.config_bucket}/glue_jobs"
  lib_zip_s3    = "${local.scripts_s3}/lib.zip"
  handlers_zip_s3 = "${local.scripts_s3}/handlers.zip"
  common_args = {
    "--extra-py-files"                   = "${local.lib_zip_s3},${local.handlers_zip_s3}"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--TempDir"                          = "s3://${var.config_bucket}/glue-temp/"
  }
}


# Glue Job — ingest (Python Shell: solo copia S3→Bronze, no necesita Spark)
resource "aws_glue_job" "ingest" {
  name         = "${local.prefix}-ingest-job"
  role_arn     = var.glue_role_arn
  glue_version = "4.0"
  max_capacity = 0.0625

  command {
    name            = "pythonshell"
    script_location = "${local.scripts_s3}/ingest.py"
    python_version  = "3.9"
  }

  default_arguments = merge(local.common_args, {
    "--JOB_NAME"    = "${local.prefix}-ingest-job"
    "--SOURCE_NAME" = "transacciones"
    "--BRONZE_BUCKET" = var.bronze_bucket
  })
}


# Glue Job — bronze_to_silver (PySpark)
resource "aws_glue_job" "silver" {
  name             = "${local.prefix}-silver-job"
  role_arn         = var.glue_role_arn
  glue_version     = "4.0"
  number_of_workers = 2
  worker_type      = "G.1X"

  command {
    name            = "glueetl"
    script_location = "${local.scripts_s3}/bronze_to_silver.py"
    python_version  = "3"
  }

  default_arguments = merge(local.common_args, {
    "--JOB_NAME"           = "${local.prefix}-silver-job"
    "--SOURCE_NAME"        = "transacciones"
    "--BRONZE_BUCKET"      = var.bronze_bucket
    "--SILVER_BUCKET"      = var.silver_bucket
    "--SCHEMA_BUCKET"      = var.config_bucket
    "--SCHEMA_KEY"         = "schema/transacciones_v1.json"
    "--REDSHIFT_WORKGROUP" = var.redshift_workgroup
    "--REDSHIFT_DATABASE"  = var.redshift_database
  })
}


# Glue Job — gold_job (PySpark genérico — recibe --PROCESS_TYPE)
resource "aws_glue_job" "gold" {
  name             = "${local.prefix}-gold-job"
  role_arn         = var.glue_role_arn
  glue_version     = "4.0"
  number_of_workers = 2
  worker_type      = "G.1X"

  command {
    name            = "glueetl"
    script_location = "${local.scripts_s3}/gold_job.py"
    python_version  = "3"
  }

  default_arguments = merge(local.common_args, {
    "--JOB_NAME"           = "${local.prefix}-gold-job"
    "--SILVER_BUCKET"      = var.silver_bucket
    "--GOLD_BUCKET"        = var.gold_bucket
    "--CONFIG_BUCKET"      = var.config_bucket
    "--CONFIG_PREFIX"      = "process_configs"
    "--REDSHIFT_WORKGROUP" = var.redshift_workgroup
    "--REDSHIFT_DATABASE"  = var.redshift_database
    "--REDSHIFT_IAM_ROLE"  = var.glue_role_arn
    "--AWS_REGION"         = var.aws_region
  })
}


# IAM Role — Step Functions
resource "aws_iam_role" "step_functions" {
  name = "${local.prefix}-sfn-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "step_functions" {
  role = aws_iam_role.step_functions.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns", "glue:BatchStopJobRun"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.sns_topic_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery",
                    "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutLogEvents",
                    "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"]
        Resource = "*"
      }
    ]
  })
}

# Step Functions State Machine
# El ASL usa templatefile para sustituir nombres de jobs y buckets en build time.
resource "aws_sfn_state_machine" "banking_pipeline" {
  name     = "${local.prefix}-pipeline"
  role_arn = aws_iam_role.step_functions.arn

  definition = templatefile(
    "${path.module}/../../step_functions/banking_pipeline.asl.json",
    {
      GlueIngestJobName  = aws_glue_job.ingest.name
      GlueSilverJobName  = aws_glue_job.silver.name
      GlueGoldJobName    = aws_glue_job.gold.name
      BronzeBucket       = var.bronze_bucket
      SilverBucket       = var.silver_bucket
      GoldBucket         = var.gold_bucket
      ConfigBucket       = var.config_bucket
      ConfigPrefix       = "process_configs"
      SchemaKey          = "schema/transacciones_v1.json"
      RedshiftWorkgroup  = var.redshift_workgroup
      RedshiftDatabase   = var.redshift_database
      RedshiftIamRole    = var.glue_role_arn
      AwsRegion          = var.aws_region
      SnsTopicArn        = var.sns_topic_arn
      Env                = var.env
    }
  )
}
