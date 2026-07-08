terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    key    = "infra/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  prefix = "${var.project_name}-${var.env}"
  common_tags = {
    Project     = var.project_name
    Environment = var.env
    ManagedBy   = "terraform"
  }
}

# -------------------------------------------------------------------------
# S3 — Medallion Architecture: Bronze / Silver / Gold / Config
# -------------------------------------------------------------------------
resource "aws_s3_bucket" "bronze" {
  bucket = "${local.prefix}-bronze"
  tags   = merge(local.common_tags, { Layer = "bronze" })
}

resource "aws_s3_bucket" "silver" {
  bucket = "${local.prefix}-silver"
  tags   = merge(local.common_tags, { Layer = "silver" })
}

resource "aws_s3_bucket" "gold" {
  bucket = "${local.prefix}-gold"
  tags   = merge(local.common_tags, { Layer = "gold" })
}

resource "aws_s3_bucket" "config" {
  bucket = "${local.prefix}-config"
  tags   = merge(local.common_tags, { Layer = "config" })
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id
  versioning_configuration { status = "Enabled" }
}

# -------------------------------------------------------------------------
# VPC — red privada para Redshift Serverless
# -------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.common_tags, { Name = "${local.prefix}-vpc" })
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.aws_region}a"
  tags              = merge(local.common_tags, { Name = "${local.prefix}-private-a" })
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}b"
  tags              = merge(local.common_tags, { Name = "${local.prefix}-private-b" })
}

resource "aws_security_group" "redshift" {
  name   = "${local.prefix}-redshift-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port = 5439
    to_port   = 5439
    protocol  = "tcp"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

# -------------------------------------------------------------------------
# Secrets Manager — credenciales admin de Redshift Serverless
# El valor real se setea manualmente o via CLI después del apply inicial.
# -------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "redshift_admin" {
  name                    = "${local.prefix}/redshift/admin"
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "redshift_admin" {
  secret_id = aws_secretsmanager_secret.redshift_admin.id
  secret_string = jsonencode({
    username = "admin"
    password = var.redshift_admin_password
    dbname   = var.redshift_database
  })
}

# -------------------------------------------------------------------------
# Redshift Serverless
# Sin nodos fijos: paga por RPU-hora solo durante queries activos.
# base_capacity = 8 RPU (mínimo recomendado para cargas ETL batch)
# -------------------------------------------------------------------------
resource "aws_redshiftserverless_namespace" "main" {
  namespace_name      = "${local.prefix}-ns"
  db_name             = var.redshift_database
  admin_username      = "admin"
  admin_user_password = var.redshift_admin_password
  tags                = local.common_tags
}

resource "aws_redshiftserverless_workgroup" "main" {
  namespace_name = aws_redshiftserverless_namespace.main.namespace_name
  workgroup_name = "${local.prefix}-wg"
  base_capacity  = 8

  subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  security_group_ids = [aws_security_group.redshift.id]

  publicly_accessible = false
  tags                = local.common_tags
}

# -------------------------------------------------------------------------
# IAM Role — Glue Jobs
# Los jobs usan este rol para acceder a S3, Redshift Data API y CloudWatch.
# No necesitan claves: el rol se asume automáticamente dentro del job.
# -------------------------------------------------------------------------
resource "aws_iam_role" "glue" {
  name = "${local.prefix}-glue-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy" "glue_s3" {
  role = aws_iam_role.glue.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.bronze.arn, "${aws_s3_bucket.bronze.arn}/*",
          aws_s3_bucket.silver.arn, "${aws_s3_bucket.silver.arn}/*",
          aws_s3_bucket.gold.arn,   "${aws_s3_bucket.gold.arn}/*",
          aws_s3_bucket.config.arn, "${aws_s3_bucket.config.arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["redshift-data:*", "redshift-serverless:GetCredentials"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.redshift_admin.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:/aws-glue/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}
