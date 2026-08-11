/**
 * Order processing state machine: validate -> enrich -> notify.
 *
 * STANDARD (not EXPRESS) because the workflow is low-volume, long-lived
 * relative to a request, and we want the full execution history for audit.
 *
 * Retry/Catch policy, stated once so the JSON below reads as intent:
 *   - Lambda service faults (throttles, 5xx, sandbox errors) are ALWAYS
 *     retried -- they say nothing about the payload.
 *   - TransientError (our own class, raised on dependency trouble) is retried
 *     with exponential backoff and jitter.
 *   - ValidationError is NEVER retried: the input is bad and will stay bad.
 *     It goes straight to the failure handler.
 *   - Everything else gets one cautious retry, then the failure handler.
 * Every Catch preserves the original error under $.error and the original
 * order under $.order, so HandleFailure can report the real cause.
 */

resource "aws_cloudwatch_log_group" "state_machine" {
  name              = "/aws/vendedlogs/states/${local.name_prefix}-order-processing"
  retention_in_days = local.log_retention_days
  tags              = local.common_tags
}

locals {
  # Lambda-service-level faults: always worth another attempt.
  lambda_service_retry = {
    ErrorEquals = [
      "Lambda.ServiceException",
      "Lambda.AWSLambdaException",
      "Lambda.SdkClientException",
      "Lambda.TooManyRequestsException",
      "Lambda.Unknown",
    ]
    IntervalSeconds = 1
    MaxAttempts     = 4
    BackoffRate     = 2.0
    JitterStrategy  = "FULL"
  }

  # Our own transient class: dependency hiccups.
  transient_retry = {
    ErrorEquals     = ["TransientError"]
    IntervalSeconds = 2
    MaxAttempts     = 3
    BackoffRate     = 2.0
    JitterStrategy  = "FULL"
  }

  # A single conservative retry for anything unclassified.
  catch_all_retry = {
    ErrorEquals     = ["States.TaskFailed"]
    IntervalSeconds = 3
    MaxAttempts     = 1
    BackoffRate     = 1.0
  }

  order_processing_definition = jsonencode({
    Comment = "Validate, enrich and notify for a newly created order"
    # The state machine is started by EventBridge with the full event as input;
    # $.detail.data is the order.
    StartAt = "Validate"
    States = {

      # -- Step 1 ---------------------------------------------------------
      Validate = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::lambda:invoke"
        Comment  = "Business validation. ValidationError is terminal by design."
        Parameters = {
          FunctionName = module.fn_validate.function_arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "order.$" = "$.Payload" }
        ResultPath     = "$.validated"
        TimeoutSeconds = 40
        Retry = [
          local.lambda_service_retry,
          local.transient_retry,
        ]
        Catch = [
          {
            # Bad input: skip straight to failure, no retry, no backoff.
            ErrorEquals = ["ValidationError"]
            ResultPath  = "$.error"
            Next        = "MarkValidationFailed"
          },
          {
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.error"
            Next        = "MarkUnexpectedFailure"
          },
        ]
        Next = "Enrich"
      }

      # -- Step 2 ---------------------------------------------------------
      Enrich = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::lambda:invoke"
        Comment  = "Customer tier, discounts and shipping. Most failure-prone step."
        Parameters = {
          FunctionName = module.fn_enrich.function_arn
          "Payload.$"  = "$.validated.order"
        }
        ResultSelector = { "order.$" = "$.Payload" }
        ResultPath     = "$.enriched"
        TimeoutSeconds = 40
        Retry = [
          local.lambda_service_retry,
          local.transient_retry,
          local.catch_all_retry,
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.error"
            Next        = "MarkEnrichmentFailed"
          },
        ]
        Next = "CheckOrderValue"
      }

      # -- Branch ---------------------------------------------------------
      # High-value orders get a deliberate settle window before the customer is
      # told the order is confirmed, so a fraud hold can still intervene.
      CheckOrderValue = {
        Type    = "Choice"
        Comment = "Route high-value orders through a hold window"
        Choices = [
          {
            Variable           = "$.enriched.order.enrichment.payableMinor"
            NumericGreaterThan = 250000
            Next               = "HighValueHold"
          },
        ]
        Default = "Notify"
      }

      HighValueHold = {
        Type    = "Wait"
        Comment = "30s settle window; a real system would wait on a callback token"
        Seconds = 30
        Next    = "Notify"
      }

      # -- Step 3 ---------------------------------------------------------
      Notify = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::lambda:invoke"
        Comment  = "Publish the customer notification and complete the order"
        Parameters = {
          FunctionName = module.fn_notify.function_arn
          "Payload.$"  = "$.enriched.order"
        }
        ResultSelector = { "order.$" = "$.Payload" }
        ResultPath     = "$.notified"
        TimeoutSeconds = 40
        Retry = [
          local.lambda_service_retry,
          local.transient_retry,
          local.catch_all_retry,
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.error"
            Next        = "MarkNotificationFailed"
          },
        ]
        Next = "Succeeded"
      }

      Succeeded = {
        Type    = "Pass"
        Comment = "Terminal success; output is the completed order"
        Parameters = {
          "status"  = "COMPLETED"
          "order.$" = "$.notified.order"
        }
        End = true
      }

      # -- Failure paths --------------------------------------------------
      # Three entry points so the failure handler knows which stage broke,
      # all converging on one Lambda.
      MarkValidationFailed = {
        Type       = "Pass"
        Parameters = { "stage" = "validate", "error.$" = "$.error", "order.$" = "$.detail.data" }
        Next       = "HandleFailure"
      }

      MarkEnrichmentFailed = {
        Type       = "Pass"
        Parameters = { "stage" = "enrich", "error.$" = "$.error", "order.$" = "$.validated.order" }
        Next       = "HandleFailure"
      }

      MarkNotificationFailed = {
        Type       = "Pass"
        Parameters = { "stage" = "notify", "error.$" = "$.error", "order.$" = "$.enriched.order" }
        Next       = "HandleFailure"
      }

      MarkUnexpectedFailure = {
        Type       = "Pass"
        Parameters = { "stage" = "unknown", "error.$" = "$.error", "order.$" = "$.detail.data" }
        Next       = "HandleFailure"
      }

      HandleFailure = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::lambda:invoke"
        Comment  = "Compensate: mark FAILED, emit order.failed, record the cause"
        Parameters = {
          FunctionName = module.fn_handle_failure.function_arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "result.$" = "$.Payload" }
        TimeoutSeconds = 40
        Retry          = [local.lambda_service_retry]
        Catch = [
          {
            # If even the failure handler fails, do not lose the event.
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.handlerError"
            Next        = "SendToDlq"
          },
        ]
        Next = "Failed"
      }

      SendToDlq = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::sqs:sendMessage"
        Comment  = "Last resort: the failure handler itself broke"
        Parameters = {
          QueueUrl        = aws_sqs_queue.workflow_dlq.url
          "MessageBody.$" = "$"
        }
        Next = "Failed"
      }

      Failed = {
        Type  = "Fail"
        Error = "OrderProcessingFailed"
        Cause = "The order could not be processed; see the execution history and the order.failed event."
      }
    }
  })
}

resource "aws_sfn_state_machine" "order_processing" {
  name       = "${local.name_prefix}-order-processing"
  role_arn   = aws_iam_role.sfn_execution.arn
  type       = "STANDARD"
  definition = local.order_processing_definition

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.state_machine.arn}:*"
    include_execution_data = !local.is_prod # payloads may contain PII
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  tags = local.common_tags
}
