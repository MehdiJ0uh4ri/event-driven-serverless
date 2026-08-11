/**
 * Least-privilege IAM.
 *
 * The rule enforced here: no function gets an action it does not call, and no
 * action is granted on "*" unless the AWS API genuinely has no resource-level
 * permission. Each policy below is small enough to read in one sitting -- that
 * is the point.
 *
 * Baseline logging and X-Ray live inside modules/lambda_function; these are the
 * function-specific grants layered on top.
 */

# ---------------------------------------------------------------------------
# createOrder: write one order, publish to one bus.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "fn_create_order" {
  statement {
    sid       = "WriteOrder"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.orders.arn]
  }

  statement {
    sid       = "PublishDomainEvents"
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.orders.arn]

    # Belt and braces: even with the bus ARN scoped, refuse to let this role
    # spoof events from another source.
    condition {
      test     = "StringEquals"
      variable = "events:source"
      values   = [local.event_source]
    }
  }
}

# ---------------------------------------------------------------------------
# getOrder: read-only. No PutItem, no bus access at all.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "fn_get_order" {
  statement {
    sid     = "ReadOrders"
    effect  = "Allow"
    actions = ["dynamodb:GetItem", "dynamodb:Query"]
    resources = [
      aws_dynamodb_table.orders.arn,
      "${aws_dynamodb_table.orders.arn}/index/gsi1-customer-index",
    ]
  }
}

# ---------------------------------------------------------------------------
# validate / enrich: update status on an existing order, publish events.
# UpdateItem but deliberately no DeleteItem and no PutItem -- these steps must
# never be able to create or destroy an order.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "fn_workflow_step" {
  statement {
    sid       = "UpdateOrderStatus"
    effect    = "Allow"
    actions   = ["dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.orders.arn]
  }

  statement {
    sid       = "PublishDomainEvents"
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.orders.arn]

    condition {
      test     = "StringEquals"
      variable = "events:source"
      values   = [local.event_source]
    }
  }
}

# ---------------------------------------------------------------------------
# notify: workflow-step permissions plus publish to exactly one SNS topic.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "fn_notify" {
  source_policy_documents = [data.aws_iam_policy_document.fn_workflow_step.json]

  statement {
    sid       = "PublishCustomerNotification"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.customer_notifications.arn]
  }
}

# ---------------------------------------------------------------------------
# audit consumer: consume the audit queue, write the audit table. Cannot read
# the orders table -- audit history must be reconstructible from events alone.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "fn_audit_consumer" {
  statement {
    sid    = "ConsumeAuditQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.audit.arn]
  }

  statement {
    sid       = "WriteAuditRecord"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.audit.arn]
  }
}

# ---------------------------------------------------------------------------
# DLQ processor: drain the dead-letter queue. Read + delete only; it has no
# write access to any data store, because its whole job is to observe.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "fn_dlq_processor" {
  statement {
    sid    = "ConsumeDeadLetterQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [
      aws_sqs_queue.audit_dlq.arn,
      aws_sqs_queue.eventbridge_dlq.arn,
      aws_sqs_queue.workflow_dlq.arn,
    ]
  }
}

# ---------------------------------------------------------------------------
# EventBridge -> Step Functions
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "eventbridge_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "eventbridge_invoke_sfn" {
  name               = "${local.name_prefix}-eventbridge-invoke-sfn"
  description        = "Lets the order-created rule start the processing state machine"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "eventbridge_invoke_sfn" {
  statement {
    sid       = "StartOrderWorkflow"
    effect    = "Allow"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.order_processing.arn]
  }
}

resource "aws_iam_role_policy" "eventbridge_invoke_sfn" {
  name   = "start-execution"
  role   = aws_iam_role.eventbridge_invoke_sfn.id
  policy = data.aws_iam_policy_document.eventbridge_invoke_sfn.json
}

# ---------------------------------------------------------------------------
# Step Functions execution role
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "sfn_execution" {
  name               = "${local.name_prefix}-sfn-execution"
  description        = "Execution role for the order processing state machine"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "sfn_execution" {
  # Exactly the four functions the state machine invokes -- not "every Lambda".
  statement {
    sid     = "InvokeWorkflowFunctions"
    effect  = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [
      module.fn_validate.function_arn,
      module.fn_enrich.function_arn,
      module.fn_notify.function_arn,
      module.fn_handle_failure.function_arn,
      # Aliases and versions are separate ARNs; include the qualified form.
      "${module.fn_validate.function_arn}:*",
      "${module.fn_enrich.function_arn}:*",
      "${module.fn_notify.function_arn}:*",
      "${module.fn_handle_failure.function_arn}:*",
    ]
  }

  statement {
    sid       = "SendFailuresToDlq"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.workflow_dlq.arn]
  }

  # Required for the EXPRESS/STANDARD logging configuration. These log APIs do
  # not support resource-level permissions -- an AWS limitation, not laziness.
  statement {
    sid    = "StateMachineLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "XRayTracing"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sfn_execution" {
  name   = "execution"
  role   = aws_iam_role.sfn_execution.id
  policy = data.aws_iam_policy_document.sfn_execution.json
}

# ---------------------------------------------------------------------------
# API Gateway -> CloudWatch Logs (access logging)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "apigw_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_logs" {
  name               = "${local.name_prefix}-apigw-logs"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "apigw_logs" {
  role       = aws_iam_role.apigw_logs.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}
