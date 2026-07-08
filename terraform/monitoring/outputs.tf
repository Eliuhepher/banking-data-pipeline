output "sns_topic_arn"             { value = aws_sns_topic.alerts.arn }
output "file_checker_lambda_arn"   { value = aws_lambda_function.file_checker.arn }
output "slack_notifier_lambda_arn" { value = aws_lambda_function.slack_notifier.arn }
