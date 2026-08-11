output "function_name" {
  description = "Fully-qualified function name."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "Function ARN ($LATEST, unqualified)."
  value       = aws_lambda_function.this.arn
}

output "invoke_arn" {
  description = "ARN used by API Gateway integrations."
  value       = aws_lambda_function.this.invoke_arn
}

output "qualified_arn" {
  description = "Alias ARN when an alias exists, otherwise the function ARN."
  value       = var.create_alias ? aws_lambda_alias.live[0].arn : aws_lambda_function.this.arn
}

output "role_arn" {
  description = "Execution role ARN."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Execution role name, for attaching extra policies from the caller."
  value       = aws_iam_role.this.name
}

output "log_group_name" {
  description = "CloudWatch log group name."
  value       = aws_cloudwatch_log_group.this.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN."
  value       = aws_cloudwatch_log_group.this.arn
}
