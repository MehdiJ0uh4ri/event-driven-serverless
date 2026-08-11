/**
 * The async backbone.
 *
 * A custom bus (never the default bus -- it is shared with every AWS service
 * and cannot be governed) carries the domain events. Rules fan them out:
 *
 *   order.created            -> Step Functions state machine   (+ DLQ)
 *   every order.* event      -> SQS audit queue                (+ DLQ)
 *   order.failed             -> SNS ops alerts                 (+ DLQ)
 *
 * Every target carries a dead_letter_config and a bounded retry_policy. An
 * EventBridge target without a DLQ silently drops events after 24h of retries.
 */

resource "aws_cloudwatch_event_bus" "orders" {
  name = "${local.name_prefix}-bus"
  tags = local.common_tags
}

# Archive enables replay: re-drive the last N days of events into the bus after
# fixing a consumer bug, without asking producers to resend anything.
resource "aws_cloudwatch_event_archive" "orders" {
  name             = "${local.name_prefix}-archive"
  event_source_arn = aws_cloudwatch_event_bus.orders.arn
  retention_days   = local.is_prod ? 90 : 7
  description      = "Replayable archive of all order-platform domain events"

  event_pattern = jsonencode({
    source = [local.event_source]
  })
}

# Bus-level logging of every event, sampled. Invaluable when a rule "should
# have matched" and did not.
resource "aws_cloudwatch_log_group" "event_bus" {
  name              = "/aws/events/${local.name_prefix}-bus"
  retention_in_days = local.log_retention_days
  tags              = local.common_tags
}

# ---------------------------------------------------------------------------
# Rule 1: order.created -> Step Functions
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "order_created" {
  name           = "${local.name_prefix}-order-created"
  description    = "Route newly created orders into the processing state machine"
  event_bus_name = aws_cloudwatch_event_bus.orders.name

  event_pattern = jsonencode({
    source      = [local.event_source]
    detail-type = ["order.created"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "order_created_to_sfn" {
  rule           = aws_cloudwatch_event_rule.order_created.name
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  target_id      = "order-processing-state-machine"
  arn            = aws_sfn_state_machine.order_processing.arn
  role_arn       = aws_iam_role.eventbridge_invoke_sfn.arn

  retry_policy {
    maximum_retry_attempts       = 3
    maximum_event_age_in_seconds = 3600
  }

  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq.arn
  }
}

# ---------------------------------------------------------------------------
# Rule 2: every domain event -> SQS -> audit consumer
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "audit_all_events" {
  name           = "${local.name_prefix}-audit-all"
  description    = "Mirror every domain event to the audit queue"
  event_bus_name = aws_cloudwatch_event_bus.orders.name

  event_pattern = jsonencode({
    source = [local.event_source]
    detail = {
      eventType = [{ prefix = "order." }]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "audit_to_sqs" {
  rule           = aws_cloudwatch_event_rule.audit_all_events.name
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  target_id      = "audit-queue"
  arn            = aws_sqs_queue.audit.arn

  # Propagate the correlation id as an SQS message attribute so the Python
  # consumer can bind it before parsing the body.
  input_transformer {
    input_paths = {
      correlationId = "$.detail.correlationId"
      eventType     = "$.detail.eventType"
      detail        = "$.detail"
    }
    input_template = <<-EOT
      {
        "detail": <detail>,
        "correlationId": <correlationId>,
        "eventType": <eventType>
      }
    EOT
  }

  retry_policy {
    maximum_retry_attempts       = 5
    maximum_event_age_in_seconds = 3600
  }

  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq.arn
  }
}

# ---------------------------------------------------------------------------
# Rule 3: order.failed -> ops alert topic
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "order_failed" {
  name           = "${local.name_prefix}-order-failed"
  description    = "Page the on-call channel when an order workflow fails"
  event_bus_name = aws_cloudwatch_event_bus.orders.name

  event_pattern = jsonencode({
    source      = [local.event_source]
    detail-type = ["order.failed"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "order_failed_to_sns" {
  rule           = aws_cloudwatch_event_rule.order_failed.name
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  target_id      = "ops-alerts"
  arn            = aws_sns_topic.ops_alerts.arn

  # Flatten the event into something readable in an email/Slack subscription.
  input_transformer {
    input_paths = {
      orderId       = "$.detail.data.orderId"
      stage         = "$.detail.data.stage"
      message       = "$.detail.data.message"
      correlationId = "$.detail.correlationId"
      occurredAt    = "$.detail.occurredAt"
    }
    input_template = <<-EOT
      "Order <orderId> FAILED at stage <stage> (<occurredAt>). Reason: <message>. Correlation id: <correlationId>."
    EOT
  }

  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq.arn
  }
}

# ---------------------------------------------------------------------------
# Rule 4: catch-all -> CloudWatch Logs, for debugging rule patterns
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "log_all" {
  name           = "${local.name_prefix}-log-all"
  description    = "Tee every event to CloudWatch Logs for pattern debugging"
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  state          = local.is_prod ? "DISABLED" : "ENABLED"

  event_pattern = jsonencode({
    source = [local.event_source]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "log_all" {
  rule           = aws_cloudwatch_event_rule.log_all.name
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  target_id      = "cloudwatch-logs"
  arn            = aws_cloudwatch_log_group.event_bus.arn
}

# Resource policy letting EventBridge write to that log group.
data "aws_iam_policy_document" "event_bus_logs" {
  statement {
    sid    = "AllowEventBridgeToLog"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }

    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.event_bus.arn}:*"]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.log_all.arn]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "event_bus" {
  policy_name     = "${local.name_prefix}-eventbridge-logs"
  policy_document = data.aws_iam_policy_document.event_bus_logs.json
}

# ---------------------------------------------------------------------------
# SQS -> Lambda event source mapping for the audit consumer
# ---------------------------------------------------------------------------
resource "aws_lambda_event_source_mapping" "audit" {
  event_source_arn = aws_sqs_queue.audit.arn
  function_name    = module.fn_audit_consumer.function_arn
  enabled          = true

  batch_size = 10
  # Wait up to 5s to fill a batch: fewer invocations, materially lower cost,
  # at the price of up to 5s of extra latency on a quiet queue.
  maximum_batching_window_in_seconds = 5

  # Required for the partial-batch-failure contract the Python handler uses.
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 10
  }
}

# ---------------------------------------------------------------------------
# DLQ -> Lambda: the dead-letter processor
# ---------------------------------------------------------------------------
resource "aws_lambda_event_source_mapping" "audit_dlq" {
  event_source_arn                   = aws_sqs_queue.audit_dlq.arn
  function_name                      = module.fn_dlq_processor.function_arn
  enabled                            = true
  batch_size                         = 10
  maximum_batching_window_in_seconds = 30
  function_response_types            = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 2
  }
}
