/**
 * Reusable Lambda function module.
 *
 * Every function in the platform goes through here so that the non-negotiables
 * are structurally impossible to forget:
 *   - a dedicated IAM role per function (no shared "lambda-exec-role")
 *   - an inline least-privilege policy scoped to named resources
 *   - X-Ray active tracing
 *   - an explicitly managed log group with a retention policy
 *   - an on-failure destination or DLQ for async invocations
 */

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
  }
}

locals {
  function_name = "${var.name_prefix}-${var.name}"

  # Base environment every function receives: Powertools configuration plus the
  # correlation-id plumbing. Merged with (and overridable by) var.environment.
  base_environment = {
    POWERTOOLS_SERVICE_NAME            = var.service_name
    POWERTOOLS_METRICS_NAMESPACE       = var.metrics_namespace
    POWERTOOLS_LOG_LEVEL               = var.log_level
    POWERTOOLS_LOGGER_LOG_EVENT        = tostring(var.log_event)
    POWERTOOLS_TRACE_ENABLED           = "true"
    POWERTOOLS_TRACER_CAPTURE_RESPONSE = tostring(var.tracer_capture_response)
    POWERTOOLS_TRACER_CAPTURE_ERROR    = "true"
    ENVIRONMENT                        = var.environment_name
  }
}

# ---------------------------------------------------------------------------
# Log group -- created explicitly (not implicitly by the first invocation) so
# retention and encryption are under IaC control from minute one.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn
  tags              = var.tags
}

# ---------------------------------------------------------------------------
# Execution role -- one per function.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "LambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    # Confused-deputy guard: only this account's Lambda service may assume it.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = "${local.function_name}-role"
  description          = "Execution role for ${local.function_name}"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}

# Logging: scoped to this function's own log group only -- not "arn:aws:logs:*".
data "aws_iam_policy_document" "baseline" {
  statement {
    sid       = "WriteOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  statement {
    sid    = "XRayTracing"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]
    # X-Ray ingestion APIs do not support resource-level permissions.
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "baseline" {
  name   = "baseline"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.baseline.json
}

# The caller-supplied, function-specific grants (DynamoDB table X, bus Y, ...).
resource "aws_iam_role_policy" "scoped" {
  count  = var.policy_json == null ? 0 : 1
  name   = "scoped"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}

# ---------------------------------------------------------------------------
# The function
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "this" {
  function_name = local.function_name
  description   = var.description
  role          = aws_iam_role.this.arn

  filename         = var.package_path
  source_code_hash = var.package_hash

  handler       = var.handler
  runtime       = var.runtime
  architectures = [var.architecture]

  memory_size = var.memory_size
  timeout     = var.timeout

  layers = var.layers

  reserved_concurrent_executions = var.reserved_concurrency

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = merge(local.base_environment, var.environment)
  }

  dynamic "dead_letter_config" {
    for_each = var.dlq_arn == null ? [] : [var.dlq_arn]
    content {
      target_arn = dead_letter_config.value
    }
  }

  dynamic "vpc_config" {
    for_each = length(var.subnet_ids) == 0 ? [] : [1]
    content {
      subnet_ids         = var.subnet_ids
      security_group_ids = var.security_group_ids
    }
  }

  # Terraform would otherwise race the first invocation to create the group.
  depends_on = [
    aws_cloudwatch_log_group.this,
    aws_iam_role_policy.baseline,
  ]

  tags = merge(var.tags, { Runtime = var.runtime })
}

# ---------------------------------------------------------------------------
# Async invocation behaviour: bounded retries and an explicit failure sink.
# Without this, async failures retry twice over ~6 hours and then vanish.
# ---------------------------------------------------------------------------
resource "aws_lambda_function_event_invoke_config" "this" {
  count = var.configure_async_invoke ? 1 : 0

  function_name                = aws_lambda_function.this.function_name
  maximum_retry_attempts       = var.async_retry_attempts
  maximum_event_age_in_seconds = var.async_max_event_age

  dynamic "destination_config" {
    for_each = var.on_failure_destination_arn == null ? [] : [1]
    content {
      on_failure {
        destination = var.on_failure_destination_arn
      }
    }
  }
}

# Published version + alias give us a stable target for EventBridge and a
# rollback handle that does not require a redeploy.
resource "aws_lambda_alias" "live" {
  count            = var.create_alias ? 1 : 0
  name             = var.alias_name
  description      = "Live traffic alias for ${local.function_name}"
  function_name    = aws_lambda_function.this.function_name
  function_version = "$LATEST"
}
