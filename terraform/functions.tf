/**
 * Function definitions.
 *
 * Memory sizes are not guesses: they come from the benchmark sweep in
 * docs/benchmarks.md. The write path gets more memory than it needs for RAM,
 * because on Lambda memory buys CPU and the extra CPU pays for itself in
 * reduced duration on the JSON + crypto work.
 */

locals {
  fn_common = {
    name_prefix        = local.name_prefix
    account_id         = local.account_id
    service_name       = local.service_name
    metrics_namespace  = local.metrics_namespace
    environment_name   = var.environment
    log_retention_days = local.log_retention_days
    log_level          = local.log_level
    architecture       = var.lambda_architecture
    tags               = local.common_tags
  }

  # Environment shared by every application function.
  app_environment = {
    TABLE_NAME     = aws_dynamodb_table.orders.name
    GSI1_NAME      = "gsi1-customer-index"
    EVENT_BUS_NAME = aws_cloudwatch_event_bus.orders.name
    EVENT_SOURCE   = local.event_source
    NODE_OPTIONS   = "--enable-source-maps"
  }
}

# ---------------------------------------------------------------------------
# API path
# ---------------------------------------------------------------------------
module "fn_create_order" {
  source = "./modules/lambda_function"

  name        = "create-order"
  description = "POST /orders -- persist the order and publish order.created"

  name_prefix        = local.fn_common.name_prefix
  account_id         = local.fn_common.account_id
  service_name       = local.fn_common.service_name
  metrics_namespace  = local.fn_common.metrics_namespace
  environment_name   = local.fn_common.environment_name
  log_retention_days = local.fn_common.log_retention_days
  log_level          = local.fn_common.log_level
  architecture       = local.fn_common.architecture
  tags               = local.fn_common.tags

  package_path = data.archive_file.nodejs.output_path
  package_hash = data.archive_file.nodejs.output_base64sha256
  handler      = "src/api/create_order.handler"
  runtime      = "nodejs20.x"

  memory_size = 1024 # CPU-bound on JSON + UUID; 1024MB is the sweet spot
  timeout     = 10

  environment = local.app_environment
  policy_json = data.aws_iam_policy_document.fn_create_order.json
}

module "fn_get_order" {
  source = "./modules/lambda_function"

  name        = "get-order"
  description = "GET /orders/{orderId} and GET /orders?customerId="

  name_prefix        = local.fn_common.name_prefix
  account_id         = local.fn_common.account_id
  service_name       = local.fn_common.service_name
  metrics_namespace  = local.fn_common.metrics_namespace
  environment_name   = local.fn_common.environment_name
  log_retention_days = local.fn_common.log_retention_days
  log_level          = local.fn_common.log_level
  architecture       = local.fn_common.architecture
  tags               = local.fn_common.tags

  package_path = data.archive_file.nodejs.output_path
  package_hash = data.archive_file.nodejs.output_base64sha256
  handler      = "src/api/get_order.handler"
  runtime      = "nodejs20.x"

  memory_size = 512
  timeout     = 10

  environment = local.app_environment
  policy_json = data.aws_iam_policy_document.fn_get_order.json
}

# ---------------------------------------------------------------------------
# Step Functions tasks
# ---------------------------------------------------------------------------
module "fn_validate" {
  source = "./modules/lambda_function"

  name        = "validate-order"
  description = "Workflow step 1: business validation"

  name_prefix        = local.fn_common.name_prefix
  account_id         = local.fn_common.account_id
  service_name       = local.fn_common.service_name
  metrics_namespace  = local.fn_common.metrics_namespace
  environment_name   = local.fn_common.environment_name
  log_retention_days = local.fn_common.log_retention_days
  log_level          = local.fn_common.log_level
  architecture       = local.fn_common.architecture
  tags               = local.fn_common.tags

  package_path = data.archive_file.nodejs.output_path
  package_hash = data.archive_file.nodejs.output_base64sha256
  handler      = "src/workflow/validate.handler"
  runtime      = "nodejs20.x"

  memory_size = 512
  timeout     = 30

  environment = merge(local.app_environment, {
    MAX_ITEMS_PER_ORDER   = "50"
    MAX_ORDER_VALUE_MINOR = "1000000"
  })
  policy_json = data.aws_iam_policy_document.fn_workflow_step.json
}

module "fn_enrich" {
  source = "./modules/lambda_function"

  name        = "enrich-order"
  description = "Workflow step 2: customer tier, pricing and shipping enrichment"

  name_prefix        = local.fn_common.name_prefix
  account_id         = local.fn_common.account_id
  service_name       = local.fn_common.service_name
  metrics_namespace  = local.fn_common.metrics_namespace
  environment_name   = local.fn_common.environment_name
  log_retention_days = local.fn_common.log_retention_days
  log_level          = local.fn_common.log_level
  architecture       = local.fn_common.architecture
  tags               = local.fn_common.tags

  package_path = data.archive_file.nodejs.output_path
  package_hash = data.archive_file.nodejs.output_base64sha256
  handler      = "src/workflow/enrich.handler"
  runtime      = "nodejs20.x"

  memory_size = 512
  timeout     = 30

  environment = local.app_environment
  policy_json = data.aws_iam_policy_document.fn_workflow_step.json
}

module "fn_notify" {
  source = "./modules/lambda_function"

  name        = "notify-customer"
  description = "Workflow step 3: publish the customer notification and complete the order"

  name_prefix        = local.fn_common.name_prefix
  account_id         = local.fn_common.account_id
  service_name       = local.fn_common.service_name
  metrics_namespace  = local.fn_common.metrics_namespace
  environment_name   = local.fn_common.environment_name
  log_retention_days = local.fn_common.log_retention_days
  log_level          = local.fn_common.log_level
  architecture       = local.fn_common.architecture
  tags               = local.fn_common.tags

  package_path = data.archive_file.nodejs.output_path
  package_hash = data.archive_file.nodejs.output_base64sha256
  handler      = "src/workflow/notify.handler"
  runtime      = "nodejs20.x"

  memory_size = 512
  timeout     = 30

  environment = merge(local.app_environment, {
    NOTIFICATION_TOPIC_ARN = aws_sns_topic.customer_notifications.arn
  })
  policy_json = data.aws_iam_policy_document.fn_notify.json
}

module "fn_handle_failure" {
  source = "./modules/lambda_function"

  name        = "handle-failure"
  description = "Workflow Catch target: mark FAILED and emit order.failed"

  name_prefix        = local.fn_common.name_prefix
  account_id         = local.fn_common.account_id
  service_name       = local.fn_common.service_name
  metrics_namespace  = local.fn_common.metrics_namespace
  environment_name   = local.fn_common.environment_name
  log_retention_days = local.fn_common.log_retention_days
  log_level          = local.fn_common.log_level
  architecture       = local.fn_common.architecture
  tags               = local.fn_common.tags

  package_path = data.archive_file.nodejs.output_path
  package_hash = data.archive_file.nodejs.output_base64sha256
  handler      = "src/workflow/handle_failure.handler"
  runtime      = "nodejs20.x"

  memory_size = 256
  timeout     = 30

  environment = local.app_environment
  policy_json = data.aws_iam_policy_document.fn_workflow_step.json
}

# ---------------------------------------------------------------------------
# Async consumers
# ---------------------------------------------------------------------------
module "fn_audit_consumer" {
  source = "./modules/lambda_function"

  name        = "audit-consumer"
  description = "SQS consumer writing the immutable audit trail (Python + Powertools)"

  name_prefix        = local.fn_common.name_prefix
  account_id         = local.fn_common.account_id
  service_name       = local.fn_common.service_name
  metrics_namespace  = local.fn_common.metrics_namespace
  environment_name   = local.fn_common.environment_name
  log_retention_days = local.fn_common.log_retention_days
  log_level          = local.fn_common.log_level
  architecture       = local.fn_common.architecture
  tags               = local.fn_common.tags

  package_path = data.archive_file.python_audit.output_path
  package_hash = data.archive_file.python_audit.output_base64sha256
  handler      = "handler.handler"
  runtime      = "python3.12"

  memory_size = 512
  timeout     = local.audit_consumer_timeout

  environment = {
    AUDIT_TABLE_NAME     = aws_dynamodb_table.audit.name
    AUDIT_RETENTION_DAYS = local.is_prod ? "365" : "30"
  }
  policy_json = data.aws_iam_policy_document.fn_audit_consumer.json
}

module "fn_dlq_processor" {
  source = "./modules/lambda_function"

  name        = "dlq-processor"
  description = "Classifies and records dead-lettered messages for triage"

  name_prefix        = local.fn_common.name_prefix
  account_id         = local.fn_common.account_id
  service_name       = local.fn_common.service_name
  metrics_namespace  = local.fn_common.metrics_namespace
  environment_name   = local.fn_common.environment_name
  log_retention_days = 90 # keep failure evidence longer than success logs
  log_level          = local.fn_common.log_level
  architecture       = local.fn_common.architecture
  tags               = local.fn_common.tags

  package_path = data.archive_file.nodejs.output_path
  package_hash = data.archive_file.nodejs.output_base64sha256
  handler      = "src/events/dlq_processor.handler"
  runtime      = "nodejs20.x"

  memory_size = 256
  timeout     = 60

  environment = local.app_environment
  policy_json = data.aws_iam_policy_document.fn_dlq_processor.json
}

# ---------------------------------------------------------------------------
# Cold-start benchmark subjects: 3 runtimes x N memory sizes.
# ---------------------------------------------------------------------------
locals {
  bench_runtimes = var.enable_coldstart_benchmark ? {
    nodejs = {
      runtime      = "nodejs20.x"
      handler      = "coldstart.handler"
      package_path = data.archive_file.bench_nodejs.output_path
      package_hash = data.archive_file.bench_nodejs.output_base64sha256
    }
    python = {
      runtime      = "python3.12"
      handler      = "coldstart.handler"
      package_path = data.archive_file.bench_python.output_path
      package_hash = data.archive_file.bench_python.output_base64sha256
    }
    go = {
      runtime      = "provided.al2023"
      handler      = "bootstrap"
      package_path = data.archive_file.bench_go.output_path
      package_hash = data.archive_file.bench_go.output_base64sha256
    }
  } : {}

  # Cartesian product of runtime x memory size, keyed for for_each.
  bench_matrix = {
    for pair in setproduct(keys(local.bench_runtimes), var.benchmark_memory_sizes) :
    "${pair[0]}-${pair[1]}" => {
      runtime_key = pair[0]
      memory      = pair[1]
    }
  }
}

module "fn_bench" {
  source   = "./modules/lambda_function"
  for_each = local.bench_matrix

  name        = "bench-${each.key}"
  description = "Cold-start benchmark subject: ${each.value.runtime_key} @ ${each.value.memory}MB"

  name_prefix        = local.fn_common.name_prefix
  account_id         = local.fn_common.account_id
  service_name       = "${local.service_name}-bench"
  metrics_namespace  = local.fn_common.metrics_namespace
  environment_name   = local.fn_common.environment_name
  log_retention_days = 3 # benchmark logs are consumed immediately by the harness
  architecture       = local.fn_common.architecture
  tags               = merge(local.common_tags, { Purpose = "benchmark" })

  package_path = local.bench_runtimes[each.value.runtime_key].package_path
  package_hash = local.bench_runtimes[each.value.runtime_key].package_hash
  handler      = local.bench_runtimes[each.value.runtime_key].handler
  runtime      = local.bench_runtimes[each.value.runtime_key].runtime

  memory_size = each.value.memory
  timeout     = 10

  # The harness forces a fresh execution environment by publishing a new
  # function version and invoking that qualifier -- not by mutating this env
  # var, which would put every benchmark run into Terraform drift.
  environment = { BENCH_NONCE = "terraform" }
}
