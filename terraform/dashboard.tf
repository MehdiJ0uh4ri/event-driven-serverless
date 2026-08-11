/**
 * The single dashboard an on-call engineer opens first.
 *
 * Ordered top-to-bottom as "is the customer affected?" -> "which component?"
 * -> "what is it costing?". Widgets deliberately mix the three SLIs on one row
 * so correlation is visible without switching views.
 */

resource "aws_cloudwatch_dashboard" "platform" {
  dashboard_name = "${local.name_prefix}-overview"

  dashboard_body = jsonencode({
    widgets = [
      # -- Row 0: headline SLIs ------------------------------------------
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = <<-EOM
            # ${upper(var.environment)} — Order Platform
            **SLOs:** availability ≥ ${var.slo_availability_target * 100}% · p99 latency ≤ ${var.slo_api_latency_p99_ms}ms · workflow success ≥ ${var.slo_workflow_success_target * 100}% · event freshness ≤ ${var.slo_event_freshness_seconds}s
            [Runbook](https://github.com/your-org/event-driven-serverless/blob/main/docs/runbook.md) · [SLO definitions](https://github.com/your-org/event-driven-serverless/blob/main/docs/slo.md)
          EOM
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 8
        height = 6
        properties = {
          title  = "API availability (SLI)"
          region = local.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            [{ expression = "IF(m2 > 0, (1 - m1 / m2) * 100, 100)", label = "Availability %", id = "e1", region = local.region }],
            ["AWS/ApiGateway", "5xx", "ApiId", aws_apigatewayv2_api.orders.id, { id = "m1", visible = false }],
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.orders.id, { id = "m2", visible = false }],
          ]
          yAxis = { left = { min = 95, max = 100 } }
          annotations = {
            horizontal = [{
              label = "SLO ${var.slo_availability_target * 100}%"
              value = var.slo_availability_target * 100
              fill  = "below"
              color = "#d62728"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 2
        width  = 8
        height = 6
        properties = {
          title  = "API latency (SLI)"
          region = local.region
          view   = "timeSeries"
          period = 300
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", aws_apigatewayv2_api.orders.id, { stat = "p50", label = "p50" }],
            ["...", { stat = "p95", label = "p95" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
          annotations = {
            horizontal = [{
              label = "SLO p99 ${var.slo_api_latency_p99_ms}ms"
              value = var.slo_api_latency_p99_ms
              fill  = "above"
              color = "#d62728"
            }]
          }
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 2
        width  = 8
        height = 6
        properties = {
          title  = "Event freshness (SLI)"
          region = local.region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", aws_sqs_queue.audit.name, { label = "Audit backlog age (s)" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.audit.name, { label = "Queue depth", yAxis = "right" }],
          ]
          annotations = {
            horizontal = [{
              label = "SLO ${var.slo_event_freshness_seconds}s"
              value = var.slo_event_freshness_seconds
              fill  = "above"
              color = "#d62728"
            }]
          }
        }
      },

      # -- Row 1: business throughput ------------------------------------
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "Order funnel"
          region = local.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            [local.metrics_namespace, "OrdersCreated", "service", local.service_name, { label = "Created", color = "#1f77b4" }],
            [local.metrics_namespace, "OrdersValidated", "service", local.service_name, { label = "Validated", color = "#2ca02c" }],
            [local.metrics_namespace, "OrdersEnriched", "service", local.service_name, { label = "Enriched", color = "#17becf" }],
            [local.metrics_namespace, "OrdersCompleted", "service", local.service_name, { label = "Completed", color = "#9467bd" }],
            [local.metrics_namespace, "OrdersFailed", "service", local.service_name, { label = "Failed", color = "#d62728" }],
            [local.metrics_namespace, "OrdersRejected", "service", local.service_name, { label = "Rejected (4xx)", color = "#ff7f0e" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "Step Functions executions"
          region = local.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/States", "ExecutionsStarted", "StateMachineArn", aws_sfn_state_machine.order_processing.arn, { label = "Started" }],
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", aws_sfn_state_machine.order_processing.arn, { label = "Succeeded", color = "#2ca02c" }],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", aws_sfn_state_machine.order_processing.arn, { label = "Failed", color = "#d62728" }],
            ["AWS/States", "ExecutionsTimedOut", "StateMachineArn", aws_sfn_state_machine.order_processing.arn, { label = "Timed out", color = "#ff7f0e" }],
            ["AWS/States", "ExecutionTime", "StateMachineArn", aws_sfn_state_machine.order_processing.arn, { label = "p95 duration", stat = "p95", yAxis = "right" }],
          ]
        }
      },

      # -- Row 2: Lambda health ------------------------------------------
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 12
        height = 6
        properties = {
          title  = "Lambda errors by function"
          region = local.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            for name in [
              module.fn_create_order.function_name,
              module.fn_get_order.function_name,
              module.fn_validate.function_name,
              module.fn_enrich.function_name,
              module.fn_notify.function_name,
              module.fn_audit_consumer.function_name,
            ] : ["AWS/Lambda", "Errors", "FunctionName", name, { label = name }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 14
        width  = 12
        height = 6
        properties = {
          title  = "Lambda duration p99 by function"
          region = local.region
          view   = "timeSeries"
          stat   = "p99"
          period = 300
          metrics = [
            for name in [
              module.fn_create_order.function_name,
              module.fn_get_order.function_name,
              module.fn_validate.function_name,
              module.fn_enrich.function_name,
              module.fn_notify.function_name,
              module.fn_audit_consumer.function_name,
            ] : ["AWS/Lambda", "Duration", "FunctionName", name, { label = name }]
          ]
        }
      },

      # -- Row 3: failure sinks ------------------------------------------
      {
        type   = "metric"
        x      = 0
        y      = 20
        width  = 8
        height = 6
        properties = {
          title  = "Dead letter queues"
          region = local.region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 300
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.audit_dlq.name, { label = "audit-dlq", color = "#d62728" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.eventbridge_dlq.name, { label = "eventbridge-dlq", color = "#ff7f0e" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.workflow_dlq.name, { label = "workflow-dlq", color = "#8c564b" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 20
        width  = 8
        height = 6
        properties = {
          title  = "EventBridge delivery"
          region = local.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Events", "Invocations", "RuleName", aws_cloudwatch_event_rule.order_created.name, "EventBusName", aws_cloudwatch_event_bus.orders.name, { label = "order-created invocations" }],
            ["AWS/Events", "FailedInvocations", "RuleName", aws_cloudwatch_event_rule.order_created.name, "EventBusName", aws_cloudwatch_event_bus.orders.name, { label = "order-created failures", color = "#d62728" }],
            ["AWS/Events", "Invocations", "RuleName", aws_cloudwatch_event_rule.audit_all_events.name, "EventBusName", aws_cloudwatch_event_bus.orders.name, { label = "audit invocations" }],
            ["AWS/Events", "FailedInvocations", "RuleName", aws_cloudwatch_event_rule.audit_all_events.name, "EventBusName", aws_cloudwatch_event_bus.orders.name, { label = "audit failures", color = "#ff7f0e" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 20
        width  = 8
        height = 6
        properties = {
          title  = "Concurrency & throttling"
          region = local.region
          view   = "timeSeries"
          period = 300
          metrics = [
            ["AWS/Lambda", "ConcurrentExecutions", { stat = "Maximum", label = "Account concurrency" }],
            ["AWS/Lambda", "Throttles", "FunctionName", module.fn_create_order.function_name, { stat = "Sum", label = "create-order throttles", color = "#d62728" }],
            ["AWS/Lambda", "Throttles", "FunctionName", module.fn_audit_consumer.function_name, { stat = "Sum", label = "audit throttles", color = "#ff7f0e" }],
          ]
        }
      },

      # -- Row 4: cost drivers -------------------------------------------
      {
        type   = "metric"
        x      = 0
        y      = 26
        width  = 12
        height = 6
        properties = {
          title  = "Cost drivers: GB-seconds consumed"
          region = local.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 3600
          metrics = [
            for entry in [
              { name = module.fn_create_order.function_name, mem = 1024 },
              { name = module.fn_get_order.function_name, mem = 512 },
              { name = module.fn_validate.function_name, mem = 512 },
              { name = module.fn_enrich.function_name, mem = 512 },
              { name = module.fn_notify.function_name, mem = 512 },
              { name = module.fn_audit_consumer.function_name, mem = 512 },
              ] : [
              "AWS/Lambda", "Duration", "FunctionName", entry.name,
              { label = "${entry.name} (${entry.mem}MB)", stat = "Sum" }
            ]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 26
        width  = 12
        height = 6
        properties = {
          title  = "DynamoDB consumed capacity"
          region = local.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", aws_dynamodb_table.orders.name, { label = "orders writes" }],
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", aws_dynamodb_table.orders.name, { label = "orders reads" }],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", aws_dynamodb_table.audit.name, { label = "audit writes" }],
            ["AWS/DynamoDB", "ThrottledRequests", "TableName", aws_dynamodb_table.orders.name, { label = "orders throttles", color = "#d62728" }],
          ]
        }
      },

      # -- Row 5: live error log -----------------------------------------
      {
        type   = "log"
        x      = 0
        y      = 32
        width  = 24
        height = 6
        properties = {
          title  = "Recent errors (all functions)"
          region = local.region
          view   = "table"
          query  = <<-EOQ
            SOURCE '${module.fn_create_order.log_group_name}' | SOURCE '${module.fn_validate.log_group_name}' | SOURCE '${module.fn_enrich.log_group_name}' | SOURCE '${module.fn_notify.log_group_name}' | SOURCE '${module.fn_audit_consumer.log_group_name}'
            | fields @timestamp, function_name, message, errorName, errorMessage, correlationId
            | filter level = "ERROR"
            | sort @timestamp desc
            | limit 25
          EOQ
        }
      },
    ]
  })
}
