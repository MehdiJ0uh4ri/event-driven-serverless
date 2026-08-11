/**
 * Queues and dead-letter queues.
 *
 * Three distinct failure sinks, because "one DLQ for everything" makes triage
 * impossible:
 *   audit_dlq        -- audit consumer exhausted its redrive policy
 *   eventbridge_dlq  -- EventBridge could not deliver to a target at all
 *   workflow_dlq     -- Step Functions / async Lambda failures
 *
 * Every queue is SSE-encrypted and has a policy that names exactly one
 * principal. Visibility timeout is 6x the consumer timeout, per the AWS
 * guidance that avoids a slow consumer double-processing its own batch.
 */

locals {
  audit_consumer_timeout = 30
}

# --- main work queue --------------------------------------------------------

resource "aws_sqs_queue" "audit_dlq" {
  name                      = "${local.name_prefix}-audit-dlq"
  message_retention_seconds = 1209600 # 14 days, the maximum -- never lose evidence
  sqs_managed_sse_enabled   = true
  tags                      = merge(local.common_tags, { Purpose = "dead-letter" })
}

resource "aws_sqs_queue" "audit" {
  name                       = "${local.name_prefix}-audit"
  visibility_timeout_seconds = local.audit_consumer_timeout * 6
  message_retention_seconds  = 345600 # 4 days
  receive_wait_time_seconds  = 20     # long polling: fewer empty receives, lower cost
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.audit_dlq.arn
    maxReceiveCount     = 3
  })

  tags = merge(local.common_tags, { Purpose = "audit-ingest" })
}

# Allow the DLQ to be redriven back to the source queue from the console/CLI.
resource "aws_sqs_queue_redrive_allow_policy" "audit_dlq" {
  queue_url = aws_sqs_queue.audit_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.audit.arn]
  })
}

# Only EventBridge, and only our specific rule, may enqueue.
data "aws_iam_policy_document" "audit_queue_policy" {
  statement {
    sid    = "AllowEventBridgeRule"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.audit.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.audit_all_events.arn]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.audit.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "audit" {
  queue_url = aws_sqs_queue.audit.id
  policy    = data.aws_iam_policy_document.audit_queue_policy.json
}

# --- EventBridge target-delivery DLQ ---------------------------------------
# Catches the case where EventBridge itself cannot deliver (target throttled,
# target deleted, permissions revoked). Distinct from a consumer that ran and
# failed -- that lands on audit_dlq.

resource "aws_sqs_queue" "eventbridge_dlq" {
  name                      = "${local.name_prefix}-eventbridge-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = merge(local.common_tags, { Purpose = "dead-letter" })
}

data "aws_iam_policy_document" "eventbridge_dlq_policy" {
  statement {
    sid    = "AllowEventBridgeRules"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.eventbridge_dlq.arn]

    # Any rule on our bus, but nothing outside this account.
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:events:${local.region}:${local.account_id}:rule/${aws_cloudwatch_event_bus.orders.name}/*"]
    }
  }
}

resource "aws_sqs_queue_policy" "eventbridge_dlq" {
  queue_url = aws_sqs_queue.eventbridge_dlq.id
  policy    = data.aws_iam_policy_document.eventbridge_dlq_policy.json
}

# --- workflow / async Lambda failure sink -----------------------------------

resource "aws_sqs_queue" "workflow_dlq" {
  name                      = "${local.name_prefix}-workflow-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = merge(local.common_tags, { Purpose = "dead-letter" })
}
