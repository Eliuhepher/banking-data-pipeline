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
# Creado en terraform/bootstrap. Aquí solo se lee el ARN via data source.
# -------------------------------------------------------------------------
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
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
        # Terraform backend: leer/escribir tfstate
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketVersioning"]
        Resource = [
          "arn:aws:s3:::${var.project_name}-tf-state",
          "arn:aws:s3:::${var.project_name}-tf-state/*"
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
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PassRole"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy",
          "iam:GetPolicyVersion", "iam:ListPolicyVersions"
        ]
        Resource = "arn:aws:iam::${var.aws_account_id}:policy/${var.project_name}-*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.project_name}-config-${var.env}",
          "arn:aws:s3:::${var.project_name}-config-${var.env}/*"
        ]
      },
      {
        # Terraform backend: leer/escribir tfstate
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketVersioning"]
        Resource = [
          "arn:aws:s3:::${var.project_name}-tf-state",
          "arn:aws:s3:::${var.project_name}-tf-state/*"
        ]
      }
    ]
  })
}
