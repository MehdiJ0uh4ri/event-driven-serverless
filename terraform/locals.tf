locals {
  name_prefix = "${var.project_name}-${var.environment}"

  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  partition  = data.aws_partition.current.partition

  service_name      = var.project_name
  metrics_namespace = "OrderPlatform"

  # Source of the domain events; EventBridge rules match on this exact string.
  event_source = "order.platform"

  is_prod = var.environment == "prod"

  # Prod keeps logs longer and talks less.
  log_retention_days = local.is_prod ? 90 : var.log_retention_days
  log_level          = local.is_prod ? "INFO" : var.log_level

  common_tags = {
    Component = "event-driven-order-platform"
  }

  # Build artefacts produced by scripts/build.sh, consumed by the lambda module.
  dist_dir = "${path.module}/../dist"

  # Error-budget maths, reused by several alarms. A 99.5% availability target
  # over 30 days leaves 0.5% of requests as budget; the fast-burn alarm fires
  # when a 5-minute window is consuming budget 14.4x faster than sustainable
  # (the Google SRE workbook multi-window burn rate).
  error_budget_fraction = 1 - var.slo_availability_target
  fast_burn_threshold   = local.error_budget_fraction * 14.4
  slow_burn_threshold   = local.error_budget_fraction * 6
}
