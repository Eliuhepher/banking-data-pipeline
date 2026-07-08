/*
terraform/bootstrap/main.tf

Setup de UNA SOLA VEZ. Crea:
  1. Bucket S3 para Terraform remote state
  2. OIDC provider de GitHub Actions en AWS IAM
  3. IAM role temporal "iam-bootstrap" que usa deploy_iam.yml para crear el resto de roles

Ejecutar localmente con credenciales de administrador ANTES de configurar GitHub Actions.
Una vez que deploy_iam.yml corre exitosamente, este bootstrap role puede eliminarse
(o mantenerse para futuros cambios en el módulo iam/).

Uso:
  cd terraform/bootstrap
  terraform init
  terraform apply -var="github_org=TU_ORG" -var="github_repo=banking-data-pipeline" \
                  -var="aws_account_id=$(aws sts get-caller-identity --query Account --output text)"
*/

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  # estado LOCAL: este módulo es bootstrap, no puede usar el bucket que está creando
}

provider "aws" {
  region = var.aws_region
}

variable "project_name"   { 
  type = string 
  default = "banking-pipeline" 
}
variable "env"             { 
  type = string 
  default = "dev" 
}
variable "aws_region"      { 
  type = string 
  default = "us-east-1" 
}
variable "aws_account_id"  { type = string }
variable "github_org"      { 
  type = string 
}
variable "github_repo"     { 
  type = string 
  default = "banking-data-pipeline" 
}

# ── 1. Bucket para Terraform remote state ───────────────────────────────────
resource "aws_s3_bucket" "tf_state" {
  bucket        = "${var.project_name}-tf-state"
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── 2. OIDC provider de GitHub Actions ──────────────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ── 3. IAM role bootstrap (solo para deploy_iam.yml) ────────────────────────
# Trust scoped a main branch. Tiene permisos para crear/gestionar IAM roles
# y el OIDC provider. Una vez que terraform/iam/ quede estable, este rol
# puede eliminarse o restringirse.
resource "aws_iam_role" "bootstrap" {
  name = "${var.project_name}-github-iam-bootstrap"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "bootstrap" {
  role = aws_iam_role.bootstrap.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Crear/gestionar roles y el OIDC provider que terraform/iam/ define
        Effect   = "Allow"
        Action   = ["iam:*", "s3:GetObject", "s3:PutObject", "s3:ListBucket",
                    "s3:GetBucketVersioning", "s3:GetEncryptionConfiguration"]
        Resource = "*"
      }
    ]
  })
}

output "tf_state_bucket"    { value = aws_s3_bucket.tf_state.bucket }
output "oidc_provider_arn"  { value = aws_iam_openid_connect_provider.github.arn }
output "bootstrap_role_arn" { value = aws_iam_role.bootstrap.arn }
