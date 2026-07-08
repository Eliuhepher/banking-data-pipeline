variable "project_name"            { type = string }
variable "env"                      { type = string }
variable "aws_region"               { type = string }
variable "aws_account_id"           { type = string }
variable "redshift_database"        { 
  type = string 
  default = "banking" 
}
variable "redshift_admin_password"  {
  type      = string
  sensitive = true
  description = "Se pasa via -var o TF_VAR_redshift_admin_password. Nunca hardcodear."
}
variable "tf_state_bucket"          { type = string }
