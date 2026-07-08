variable "project_name" {
  type        = string
  description = "Prefijo global para todos los recursos"
  default     = "banking-pipeline"
}

variable "env" {
  type        = string
  description = "Ambiente de despliegue: dev | staging | prod"
}

variable "aws_region" {
  type        = string
  description = "Región AWS principal"
  default     = "us-east-1"
}

variable "aws_account_id" {
  type        = string
  description = "ID de la cuenta AWS destino"
}
