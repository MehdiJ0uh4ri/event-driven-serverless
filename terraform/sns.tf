/**
 * Notification topics.
 *
 *   customer_notifications -- fan-out for the workflow's notify step
 *   ops_alerts             -- SLO alarms and order.failed events
 */

resource "aws_sns_topic" "customer_notifications" {
  name              = "${local.name_prefix}-customer-notifications"
  kms_master_key_id = "alias/aws/sns"
  tags              = local.common_tags
}

resource "aws_sns_topic" "ops_alerts" {
  name              = "${local.name_prefix}-ops-alerts"
  kms_master_key_id = "alias/aws/sns"
  tags              = local.common_tags
}

# Only EventBridge (via our rules) and CloudWatch alarms may publish here.
data "aws_iam_policy_document" "ops_alerts" {
  statement {
    sid    = "AllowEventBridge"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.ops_alerts.arn]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:events:${local.region}:${local.account_id}:rule/${aws_cloudwatch_event_bus.orders.name}/*"]
    }
  }

  statement {
    sid    = "AllowCloudWatchAlarms"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.ops_alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "ops_alerts" {
  arn    = aws_sns_topic.ops_alerts.arn
  policy = data.aws_iam_policy_document.ops_alerts.json
}

resource "aws_sns_topic_subscription" "ops_email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
