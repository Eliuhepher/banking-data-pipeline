variable "project_name"       { type = string }
variable "env"                { type = string }
variable "aws_region"         { type = string }
variable "aws_account_id"     { type = string }
variable "alert_email"        { type = string }
variable "alert_phone"        { type = string; default = "" }
variable "slack_webhook_url"  { type = string; sensitive = true }
variable "slack_channel"      { type = string; default = "#data-alerts" }
variable "step_functions_arn" { type = string }
variable "tf_state_bucket"    { type = string }
