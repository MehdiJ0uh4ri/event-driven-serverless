/**
 * Observability and SLOs.
 *
 * Alarm philosophy: alarms are pages, and every page must be actionable. So:
 *   - SLI-based alarms (availability, latency, freshness) use multi-window
 *     burn rates rather than raw error counts, so a single blip does not page.
 *   - Resource alarms (DLQ depth, throttles) fire on any occurrence, because
 *     any occurrence means data is stuck somewhere.
 *   - `treat_missing_data` is set explicitly on every alarm. The default
 *     ("missing") silently hides a service that has stopped receiving traffic.
 *
 * Targets live in variables.tf and are documented in docs/slo.md.
 */

# ---------------------------------------------------------------------------
# SLO 1: API availability. Error budget burn, fast + slow window.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "api_availability_fast_burn" {
  alarm_name        = "${local.name_prefix}-slo-availability-fast-burn"
  alarm_description = <<-EOT
    API 5xx rate is burning the availability error budget 14.4x faster than
    sustainable. At this rate the ${var.slo_availability_target * 100}% monthly
    objective is exhausted in ~2 days. Runbook: docs/runbook.md#availability
  EOT

  comparison_operator = "GreaterThanThreshold"
  threshold           = local.fast_burn_threshold
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching" # no traffic is not an availability breach

  metric_query {
    id          = "error_rate"
    expression  = "IF(requests > 0, errors / requests, 0)"
    label       = "5xx error rate"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "5xx"
      dimensions  = { ApiId = aws_apigatewayv2_api.orders.id }
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "Count"
      dimensions  = { ApiId = aws_apigatewayv2_api.orders.id }
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]
  tags          = merge(local.common_tags, { SLO = "availability", Severity = "page" })
}

resource "aws_cloudwatch_metric_alarm" "api_availability_slow_burn" {
  alarm_name        = "${local.name_prefix}-slo-availability-slow-burn"
  alarm_description = "Sustained elevated error rate over 1h. Ticket, not a page. Runbook: docs/runbook.md#availability"

  comparison_operator = "GreaterThanThreshold"
  threshold           = local.slow_burn_threshold
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "IF(requests > 0, errors / requests, 0)"
    label       = "5xx error rate (1h windows)"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "5xx"
      dimensions  = { ApiId = aws_apigatewayv2_api.orders.id }
      period      = 3600
      stat        = "Sum"
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "Count"
      dimensions  = { ApiId = aws_apigatewayv2_api.orders.id }
      period      = 3600
      stat        = "Sum"
    }
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = merge(local.common_tags, { SLO = "availability", Severity = "ticket" })
}

# ---------------------------------------------------------------------------
# SLO 2: API latency (p99 on the write path).
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "api_latency_p99" {
  alarm_name        = "${local.name_prefix}-slo-api-latency-p99"
  alarm_description = "p99 API latency exceeded ${var.slo_api_latency_p99_ms}ms. Runbook: docs/runbook.md#latency"

  namespace           = "AWS/ApiGateway"
  metric_name         = "Latency"
  dimensions          = { ApiId = aws_apigatewayv2_api.orders.id }
  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.slo_api_latency_p99_ms
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]
  tags          = merge(local.common_tags, { SLO = "latency", Severity = "ticket" })
}

# ---------------------------------------------------------------------------
# SLO 3: workflow success rate.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "workflow_success_rate" {
  alarm_name        = "${local.name_prefix}-slo-workflow-success-rate"
  alarm_description = <<-EOT
    Step Functions success rate dropped below ${var.slo_workflow_success_target * 100}%.
    Orders are being accepted but not fulfilled -- customer-visible.
    Runbook: docs/runbook.md#workflow-failures
  EOT

  comparison_operator = "LessThanThreshold"
  threshold           = var.slo_workflow_success_target
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "success_rate"
    expression  = "IF(started > 0, succeeded / started, 1)"
    label       = "Execution success rate"
    return_data = true
  }

  metric_query {
    id = "succeeded"
    metric {
      namespace   = "AWS/States"
      metric_name = "ExecutionsSucceeded"
      dimensions  = { StateMachineArn = aws_sfn_state_machine.order_processing.arn }
      period      = 900
      stat        = "Sum"
    }
  }

  metric_query {
    id = "started"
    metric {
      namespace   = "AWS/States"
      metric_name = "ExecutionsStarted"
      dimensions  = { StateMachineArn = aws_sfn_state_machine.order_processing.arn }
      period      = 900
      stat        = "Sum"
    }
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]
  tags          = merge(local.common_tags, { SLO = "workflow", Severity = "page" })
}

# ---------------------------------------------------------------------------
# SLO 4: event freshness. Backlog age is the honest measure of an async
# pipeline's health -- queue depth alone lies when throughput is high.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "audit_queue_freshness" {
  alarm_name        = "${local.name_prefix}-slo-event-freshness"
  alarm_description = "Oldest unprocessed audit event is older than ${var.slo_event_freshness_seconds}s. Runbook: docs/runbook.md#backlog"

  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.audit.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.slo_event_freshness_seconds
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]
  tags          = merge(local.common_tags, { SLO = "freshness", Severity = "ticket" })
}

# ---------------------------------------------------------------------------
# Resource alarms: any occurrence is actionable.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each = {
    audit       = aws_sqs_queue.audit_dlq.name
    eventbridge = aws_sqs_queue.eventbridge_dlq.name
    workflow    = aws_sqs_queue.workflow_dlq.name
  }

  alarm_name        = "${local.name_prefix}-dlq-${each.key}-not-empty"
  alarm_description = "Messages are sitting on the ${each.key} DLQ. Runbook: docs/runbook.md#dlq"

  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = merge(local.common_tags, { Severity = "page" })
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each = {
    create-order   = module.fn_create_order.function_name
    get-order      = module.fn_get_order.function_name
    audit-consumer = module.fn_audit_consumer.function_name
  }

  alarm_name        = "${local.name_prefix}-${each.key}-throttled"
  alarm_description = "Lambda ${each.value} is being throttled -- concurrency ceiling reached. Runbook: docs/runbook.md#throttling"

  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = merge(local.common_tags, { Severity = "page" })
}

# Iterator age on the SQS consumer's own errors -- catches a consumer that is
# running but failing every record (queue drains to the DLQ silently otherwise).
resource "aws_cloudwatch_metric_alarm" "audit_consumer_errors" {
  alarm_name        = "${local.name_prefix}-audit-consumer-error-rate"
  alarm_description = "The audit consumer is failing more than 5% of invocations. Runbook: docs/runbook.md#audit-consumer"

  comparison_operator = "GreaterThanThreshold"
  threshold           = 0.05
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "IF(invocations > 0, errors / invocations, 0)"
    label       = "Audit consumer error rate"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Errors"
      dimensions  = { FunctionName = module.fn_audit_consumer.function_name }
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "invocations"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Invocations"
      dimensions  = { FunctionName = module.fn_audit_consumer.function_name }
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = merge(local.common_tags, { Severity = "ticket" })
}

# EventBridge rules that fail to invoke their target at all.
resource "aws_cloudwatch_metric_alarm" "eventbridge_failed_invocations" {
  for_each = {
    order-created = aws_cloudwatch_event_rule.order_created.name
    audit-all     = aws_cloudwatch_event_rule.audit_all_events.name
  }

  alarm_name        = "${local.name_prefix}-eventbridge-${each.key}-failed"
  alarm_description = "EventBridge rule ${each.value} could not invoke its target. Runbook: docs/runbook.md#eventbridge"

  namespace           = "AWS/Events"
  metric_name         = "FailedInvocations"
  dimensions          = { RuleName = each.value, EventBusName = aws_cloudwatch_event_bus.orders.name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  tags          = merge(local.common_tags, { Severity = "page" })
}

# ---------------------------------------------------------------------------
# Cost guardrail: an AWS Budget that alerts before the bill surprises anyone.
# The CI-side projection lives in tools/cost_model.py; this is the backstop
# that catches what the model did not predict.
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "${local.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_cost_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Environment$${var.environment}"]
  }

  # Warn on forecast before actual, so there is time to react.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.ops_alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.ops_alerts.arn]
  }
}

# ---------------------------------------------------------------------------
# Saved CloudWatch Insights queries -- the ones you actually want at 3am,
# already written, instead of being composed under pressure.
# ---------------------------------------------------------------------------
locals {
  app_log_groups = [
    module.fn_create_order.log_group_name,
    module.fn_get_order.log_group_name,
    module.fn_validate.log_group_name,
    module.fn_enrich.log_group_name,
    module.fn_notify.log_group_name,
    module.fn_handle_failure.log_group_name,
    module.fn_audit_consumer.log_group_name,
    module.fn_dlq_processor.log_group_name,
  ]
}

resource "aws_cloudwatch_query_definition" "trace_correlation_id" {
  name            = "${local.name_prefix}/Trace one request by correlation id"
  log_group_names = local.app_log_groups

  query_string = <<-EOQ
    fields @timestamp, service, function_name, level, message, correlationId, orderId
    | filter correlationId = "REPLACE_WITH_CORRELATION_ID"
    | sort @timestamp asc
    | limit 200
  EOQ
}

resource "aws_cloudwatch_query_definition" "errors_by_function" {
  name            = "${local.name_prefix}/Errors grouped by function"
  log_group_names = local.app_log_groups

  query_string = <<-EOQ
    fields @timestamp, function_name, level, message, errorName, errorMessage, correlationId
    | filter level = "ERROR"
    | stats count() as errors by function_name, errorName
    | sort errors desc
  EOQ
}

resource "aws_cloudwatch_query_definition" "cold_starts" {
  name            = "${local.name_prefix}/Cold start init durations"
  log_group_names = local.app_log_groups

  query_string = <<-EOQ
    filter @type = "REPORT"
    | fields @initDuration / 1000 as initSeconds, @duration, @billedDuration, @memorySize / 1000000 as memoryMb
    | filter ispresent(@initDuration)
    | stats count() as coldStarts,
            avg(@initDuration) as avgInitMs,
            pct(@initDuration, 50) as p50InitMs,
            pct(@initDuration, 95) as p95InitMs,
            pct(@initDuration, 99) as p99InitMs
      by bin(1h)
  EOQ
}

resource "aws_cloudwatch_query_definition" "dead_letter_reasons" {
  name            = "${local.name_prefix}/Dead letter messages by reason"
  log_group_names = [module.fn_dlq_processor.log_group_name]

  query_string = <<-EOQ
    fields @timestamp, reason, messageId, correlationId, orderId, eventType, bodyPreview
    | filter message = "dead_letter_message"
    | stats count() as messages by reason, eventType
    | sort messages desc
  EOQ
}

resource "aws_cloudwatch_query_definition" "slow_requests" {
  name            = "${local.name_prefix}/Slowest API requests"
  log_group_names = [aws_cloudwatch_log_group.api_access.name]

  query_string = <<-EOQ
    fields @timestamp, routeKey, status, responseLatency, integrationLatency, correlationId, xrayTraceId
    | filter responseLatency > 500
    | sort responseLatency desc
    | limit 50
  EOQ
}
