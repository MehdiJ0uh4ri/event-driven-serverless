output "api_endpoint" {
  description = "Base URL of the orders API."
  value       = aws_apigatewayv2_api.orders.api_endpoint
}

output "api_id" {
  description = "API Gateway HTTP API id."
  value       = aws_apigatewayv2_api.orders.id
}

output "event_bus_name" {
  description = "Custom EventBridge bus carrying the domain events."
  value       = aws_cloudwatch_event_bus.orders.name
}

output "event_bus_arn" {
  description = "ARN of the custom event bus."
  value       = aws_cloudwatch_event_bus.orders.arn
}

output "state_machine_arn" {
  description = "Order processing state machine ARN."
  value       = aws_sfn_state_machine.order_processing.arn
}

output "orders_table_name" {
  description = "Operational orders table."
  value       = aws_dynamodb_table.orders.name
}

output "audit_table_name" {
  description = "Append-only audit table."
  value       = aws_dynamodb_table.audit.name
}

output "queue_urls" {
  description = "All queue URLs, keyed by purpose."
  value = {
    audit           = aws_sqs_queue.audit.url
    audit_dlq       = aws_sqs_queue.audit_dlq.url
    eventbridge_dlq = aws_sqs_queue.eventbridge_dlq.url
    workflow_dlq    = aws_sqs_queue.workflow_dlq.url
  }
}

output "ops_alerts_topic_arn" {
  description = "SNS topic receiving SLO alarms and order.failed events."
  value       = aws_sns_topic.ops_alerts.arn
}

output "dashboard_url" {
  description = "Direct link to the CloudWatch dashboard."
  value       = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards:name=${aws_cloudwatch_dashboard.platform.dashboard_name}"
}

output "function_names" {
  description = "All application function names, for scripting and the cost model."
  value = {
    create_order   = module.fn_create_order.function_name
    get_order      = module.fn_get_order.function_name
    validate       = module.fn_validate.function_name
    enrich         = module.fn_enrich.function_name
    notify         = module.fn_notify.function_name
    handle_failure = module.fn_handle_failure.function_name
    audit_consumer = module.fn_audit_consumer.function_name
    dlq_processor  = module.fn_dlq_processor.function_name
  }
}

output "benchmark_functions" {
  description = "Cold-start benchmark subjects, keyed by runtime-memory."
  value       = { for k, m in module.fn_bench : k => m.function_name }
}

output "cost_model_inputs" {
  description = "Machine-readable stack shape consumed by tools/cost_model.py."
  value = {
    region       = local.region
    environment  = var.environment
    budget_usd   = var.monthly_cost_budget_usd
    architecture = var.lambda_architecture
    functions = {
      (module.fn_create_order.function_name)   = { memory_mb = 1024, runtime = "nodejs20.x" }
      (module.fn_get_order.function_name)      = { memory_mb = 512, runtime = "nodejs20.x" }
      (module.fn_validate.function_name)       = { memory_mb = 512, runtime = "nodejs20.x" }
      (module.fn_enrich.function_name)         = { memory_mb = 512, runtime = "nodejs20.x" }
      (module.fn_notify.function_name)         = { memory_mb = 512, runtime = "nodejs20.x" }
      (module.fn_handle_failure.function_name) = { memory_mb = 256, runtime = "nodejs20.x" }
      (module.fn_audit_consumer.function_name) = { memory_mb = 512, runtime = "python3.12" }
      (module.fn_dlq_processor.function_name)  = { memory_mb = 256, runtime = "nodejs20.x" }
    }
    dynamodb_tables = [aws_dynamodb_table.orders.name, aws_dynamodb_table.audit.name]
    state_machine   = aws_sfn_state_machine.order_processing.name
    api_id          = aws_apigatewayv2_api.orders.id
    api_rate_limit  = var.api_throttle_rate_limit
  }
}
