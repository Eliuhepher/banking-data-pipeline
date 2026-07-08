terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    key    = "monitoring/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  prefix = "${var.project_name}-${var.env}"
}

# SNS Topic — canal central de alertas
# Suscripciones: Email + SMS (directas) + Lambda→Slack (via código)
resource "aws_sns_topic" "alerts" {
  name = "${local.prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "sms" {
  count     = var.alert_phone != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "sms"
  endpoint  = var.alert_phone
}

resource "aws_sns_topic_subscription" "slack" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notifier.arn
}


# IAM Role — Lambdas de monitoreo
resource "aws_iam_role" "lambda" {
  name = "${local.prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  role = aws_iam_role.lambda.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "arn:aws:logs:*:*:*"
        },
        {
          Effect   = "Allow"
          Action   = ["s3:HeadObject", "s3:GetObject"]
          Resource = ["arn:aws:s3:::${local.prefix}-bronze/*"]
        },
        {
          Effect   = "Allow"
          Action   = ["sns:Publish"]
          Resource = aws_sns_topic.alerts.arn
        }
      ],
      var.step_functions_arn != "" ? [{
        Effect   = "Allow"
        Action   = ["states:StartExecution"]
        Resource = var.step_functions_arn
      }] : []
    )
  })
}

# Lambda — file_checker
# EventBridge → verifica S3 Bronze → dispara Step Functions o alerta SNS
resource "aws_lambda_function" "file_checker" {
  function_name = "${local.prefix}-file-checker"
  role          = aws_iam_role.lambda.arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  timeout       = 30
  filename      = "${path.module}/../../lambdas/file_checker/handler.zip"

  environment {
    variables = {
      BRONZE_BUCKET      = "${local.prefix}-bronze"
      EXPECTED_S3_KEY    = "incoming/transacciones.csv"
      STEP_FUNCTIONS_ARN = var.step_functions_arn
      SNS_TOPIC_ARN      = aws_sns_topic.alerts.arn
      SOURCE_NAME        = "transacciones"
      ENV                = var.env
    }
  }
}


# Lambda — slack_notifier
# SNS → Lambda → Slack Incoming Webhook
resource "aws_lambda_function" "slack_notifier" {
  function_name = "${local.prefix}-slack-notifier"
  role          = aws_iam_role.lambda.arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  timeout       = 15
  filename      = "${path.module}/../../lambdas/slack_notifier/handler.zip"

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
      SLACK_CHANNEL     = var.slack_channel
      ENV               = var.env
    }
  }
}

resource "aws_lambda_permission" "sns_invoke_slack" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

# EventBridge — disparo diario a las 08:30 UTC
resource "aws_cloudwatch_event_rule" "daily_trigger" {
  name                = "${local.prefix}-daily-trigger"
  description         = "Dispara file_checker a las 08:30 UTC para verificar archivo en S3 Bronze"
  schedule_expression = "cron(30 8 * * ? *)"
}

resource "aws_cloudwatch_event_target" "file_checker" {
  rule      = aws_cloudwatch_event_rule.daily_trigger.name
  target_id = "FileCheckerLambda"
  arn       = aws_lambda_function.file_checker.arn
}

resource "aws_lambda_permission" "eventbridge_invoke_checker" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.file_checker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_trigger.arn
}


# EventBridge — alertas de fallo en Glue Jobs
# Captura cualquier job en estado FAILED/TIMEOUT/ERROR y publica en SNS.
resource "aws_cloudwatch_event_rule" "glue_failure" {
  name        = "${local.prefix}-glue-failure"
  description = "Captura fallos de Glue Jobs y los enruta a SNS"
  event_pattern = jsonencode({
    source      = ["aws.glue"]
    detail-type = ["Glue Job State Change"]
    detail = {
      state     = ["FAILED", "TIMEOUT", "ERROR"]
      jobName   = [{ prefix = local.prefix }]
    }
  })
}

resource "aws_cloudwatch_event_target" "glue_failure_sns" {
  rule      = aws_cloudwatch_event_rule.glue_failure.name
  target_id = "GlueFailureSNS"
  arn       = aws_sns_topic.alerts.arn
}

# CloudWatch Alarm — fallos en Step Functions
# Solo se crea si ya existe la State Machine (deploy_jobs corre después de monitoring)
resource "aws_cloudwatch_metric_alarm" "sfn_failures" {
  count               = var.step_functions_arn != "" ? 1 : 0
  alarm_name          = "${local.prefix}-sfn-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Una o más ejecuciones del pipeline fallaron"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    StateMachineArn = var.step_functions_arn
  }
}


# CloudWatch Log Groups — retención explícita
resource "aws_cloudwatch_log_group" "glue_silver" {
  name              = "/aws-glue/${local.prefix}-silver-job"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "glue_gold" {
  name              = "/aws-glue/${local.prefix}-gold-job"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "lambda_file_checker" {
  name              = "/aws/lambda/${local.prefix}-file-checker"
  retention_in_days = 14
}
