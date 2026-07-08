output "github_infra_role_arn"      { value = aws_iam_role.github_infra.arn }
output "github_jobs_role_arn"       { value = aws_iam_role.github_jobs.arn }
output "github_monitoring_role_arn" { value = aws_iam_role.github_monitoring.arn }
output "oidc_provider_arn"          { value = aws_iam_openid_connect_provider.github.arn }
