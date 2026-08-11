variable "aws_region" {
  type        = string
  description = "Region to deploy into."
  default     = "eu-west-1"
}

variable "project_name" {
  type        = string
  description = "Project name, used as the resource name prefix."
  default     = "order-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,24}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, 3-25 chars."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment."
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "cost_center" {
  type        = string
  description = "Tag used for cost allocation reporting."
  default     = "platform-engineering"
}

variable "lambda_architecture" {
  type        = string
  description = "Default architecture for application functions."
  default     = "arm64"
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention for all functions."
  default     = 14
}

variable "log_level" {
  type        = string
  description = "Powertools log level for application functions."
  default     = "INFO"
}

# --- alerting ---------------------------------------------------------------

variable "alert_email" {
  type        = string
  description = "Email subscribed to the ops alert topic. Empty disables the subscription."
  default     = ""
}

# --- SLO targets ------------------------------------------------------------
# These drive the CloudWatch alarms in observability.tf. Documented in docs/slo.md.

variable "slo_availability_target" {
  type        = number
  description = "Fraction of successful API requests, e.g. 0.995 = 99.5%."
  default     = 0.995

  validation {
    condition     = var.slo_availability_target > 0.9 && var.slo_availability_target < 1
    error_message = "slo_availability_target must be between 0.9 and 1."
  }
}

variable "slo_api_latency_p99_ms" {
  type        = number
  description = "p99 latency objective for the write path, in milliseconds."
  default     = 1000
}

variable "slo_workflow_success_target" {
  type        = number
  description = "Fraction of Step Functions executions that must succeed."
  default     = 0.99
}

variable "slo_event_freshness_seconds" {
  type        = number
  description = "Max acceptable age of the oldest unprocessed message on the audit queue."
  default     = 120
}

# --- capacity / cost --------------------------------------------------------

variable "dynamodb_billing_mode" {
  type        = string
  description = "PAY_PER_REQUEST for spiky/unknown load, PROVISIONED once it is predictable."
  default     = "PAY_PER_REQUEST"

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.dynamodb_billing_mode)
    error_message = "dynamodb_billing_mode must be PAY_PER_REQUEST or PROVISIONED."
  }
}

variable "api_throttle_rate_limit" {
  type        = number
  description = "Steady-state request rate ceiling. Also the primary cost guardrail."
  default     = 200
}

variable "api_throttle_burst_limit" {
  type        = number
  description = "Burst ceiling for the HTTP API stage."
  default     = 400
}

variable "monthly_cost_budget_usd" {
  type        = number
  description = "Projected monthly cost ceiling; tools/cost_model.py fails CI above it."
  default     = 50
}

# --- benchmarking -----------------------------------------------------------

variable "enable_coldstart_benchmark" {
  type        = bool
  description = "Deploy the Node/Python/Go benchmark functions. Off in prod by default."
  default     = true
}

variable "benchmark_memory_sizes" {
  type        = list(number)
  description = "Memory sizes to deploy each benchmark runtime at, for the sweep."
  default     = [128, 512, 1024]
}
