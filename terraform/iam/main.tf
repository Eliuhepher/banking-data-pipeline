terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    key    = "iam/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# -------------------------------------------------------------------------
# OIDC Identity Provider — GitHub Actions
# Permite que los workflows de GitHub obtengan credenciales temporales via
# STS sin almacenar AWS_ACCESS_KEY_ID ni AWS_SECRET_ACCESS_KEY en ningún lugar.
# -------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # thumbprint de la CA raíz de GitHub Actions (verificar periódicamente)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  # scope a repo + branch main: un PR de fork no puede asumir el rol
  oidc_subject = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"

  trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.oidc_subject
        }
      }
    }]
  })
}

# -------------------------------------------------------------------------
# IAM Role — deploy_infra.yml
# Permisos: S3, Redshift Serverless, VPC, Secrets Manager, IAM (para crear roles de Glue/Lambda)
# -------------------------------------------------------------------------
resource "aws_iam_role" "github_infra" {
  name               = "${var.project_name}-github-infra-${var.env}"
  assume_role_policy = local.trust_policy
}

resource "aws_iam_role_policy" "github_infra" {
  role = aws_iam_role.github_infra.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = ["arn:aws:s3:::${var.project_name}-*"]
      },
      {
        Effect   = "Allow"
        Action   = ["redshift-serverless:*", "secretsmanager:*"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:*", "iam:*", "logs:*"]
        Resource = "*"
      }
    ]
  })
}

# -------------------------------------------------------------------------
# IAM Role — deploy_jobs.yml
# Permisos: Glue, Step Functions, S3 (solo para subir scripts)
# -------------------------------------------------------------------------
resource "aws_iam_role" "github_jobs" {
  name               = "${var.project_name}-github-jobs-${var.env}"
  assume_role_policy = local.trust_policy
}

resource "aws_iam_role_policy" "github_jobs" {
  role = aws_iam_role.github_jobs.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["glue:*", "states:*"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.project_name}-config-${var.env}",
          "arn:aws:s3:::${var.project_name}-config-${var.env}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:aws:iam::${var.aws_account_id}:role/${var.project_name}-*"
      }
    ]
  })
}

# -------------------------------------------------------------------------
# IAM Role — deploy_monitoring.yml
# Permisos: SNS, Lambda, EventBridge, CloudWatch
# -------------------------------------------------------------------------
resource "aws_iam_role" "github_monitoring" {
  name               = "${var.project_name}-github-monitoring-${var.env}"
  assume_role_policy = local.trust_policy
}

resource "aws_iam_role_policy" "github_monitoring" {
  role = aws_iam_role.github_monitoring.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sns:*", "lambda:*", "events:*", "cloudwatch:*", "logs:*"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:aws:iam::${var.aws_account_id}:role/${var.project_name}-*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.project_name}-config-${var.env}",
          "arn:aws:s3:::${var.project_name}-config-${var.env}/*"
        ]
      }
    ]
  })
}
