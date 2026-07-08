project_name       = "banking-pipeline"
env                = "dev"
aws_region         = "us-east-1"
aws_account_id     = "965085139900"
tf_state_bucket    = "banking-pipeline-tf-state"
alert_email        = "tu-email@dominio.com"
alert_phone        = "+57300000000"
slack_channel      = "#data-alerts"
# slack_webhook_url — setear via: export TF_VAR_slack_webhook_url=https://hooks.slack.com/...
# step_functions_arn se obtiene del output de terraform/jobs
step_functions_arn = ""
