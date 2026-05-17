output "api_endpoint" {
  description = "API Gateway endpoint — use this in your cron job"
  value       = "https://${aws_api_gateway_domain_name.api.domain_name}/update"
}

output "api_key_id" {
  description = "API key resource ID — retrieve the value with: aws apigateway get-api-key --api-key <id> --include-value"
  value       = aws_api_gateway_api_key.home_server.id
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.ddns.function_name
}

output "github_actions_role_arn" {
  description = "IAM role ARN to set as AWS_ROLE_ARN secret in GitHub"
  value       = aws_iam_role.github_actions.arn
}
