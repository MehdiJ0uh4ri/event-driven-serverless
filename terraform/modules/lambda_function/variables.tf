variable "name" {
  type        = string
  description = "Short function name, suffixed onto name_prefix."
}

variable "name_prefix" {
  type        = string
  description = "Project + environment prefix, e.g. order-platform-dev."
}

variable "description" {
  type        = string
  description = "Human-readable purpose of the function."
  default     = ""
}

variable "account_id" {
  type        = string
  description = "AWS account id, used in the assume-role confused-deputy guard."
}

variable "service_name" {
  type        = string
  description = "POWERTOOLS_SERVICE_NAME value."
  default     = "order-platform"
}

variable "metrics_namespace" {
  type        = string
  description = "CloudWatch EMF namespace."
  default     = "OrderPlatform"
}

variable "environment_name" {
  type        = string
  description = "dev / staging / prod."
}

# --- code -------------------------------------------------------------------

variable "package_path" {
  type        = string
  description = "Path to the built deployment .zip."
}

variable "package_hash" {
  type        = string
  description = "base64sha256 of the package, drives redeploys."
}

variable "handler" {
  type        = string
  description = "Handler entrypoint (ignored in spirit by provided.al2023, still required)."
}

variable "runtime" {
  type        = string
  description = "Lambda runtime identifier."

  validation {
    condition     = contains(["nodejs20.x", "nodejs22.x", "python3.12", "python3.11", "provided.al2023"], var.runtime)
    error_message = "Runtime must be one of the runtimes this platform benchmarks and supports."
  }
}

variable "architecture" {
  type        = string
  description = "arm64 (Graviton, ~20% cheaper) or x86_64."
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "Architecture must be arm64 or x86_64."
  }
}

variable "layers" {
  type        = list(string)
  description = "Layer ARNs, e.g. the AWS-managed Powertools layer."
  default     = []
}

# --- sizing -----------------------------------------------------------------

variable "memory_size" {
  type        = number
  description = "Memory in MB; also determines CPU allocation."
  default     = 512

  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240
    error_message = "memory_size must be between 128 and 10240 MB."
  }
}

variable "timeout" {
  type        = number
  description = "Timeout in seconds."
  default     = 15

  validation {
    condition     = var.timeout >= 1 && var.timeout <= 900
    error_message = "timeout must be between 1 and 900 seconds."
  }
}

variable "reserved_concurrency" {
  type        = number
  description = "Reserved concurrent executions; -1 leaves it unreserved."
  default     = -1
}

# --- wiring -----------------------------------------------------------------

variable "environment" {
  type        = map(string)
  description = "Function-specific environment variables, merged over the base set."
  default     = {}
}

variable "policy_json" {
  type        = string
  description = "Least-privilege IAM policy document JSON for this function."
  default     = null
}

variable "permissions_boundary_arn" {
  type        = string
  description = "Optional permissions boundary applied to the execution role."
  default     = null
}

variable "dlq_arn" {
  type        = string
  description = "SQS/SNS ARN for the Lambda-level dead letter config."
  default     = null
}

variable "configure_async_invoke" {
  type        = bool
  description = "Whether to manage the async invoke config (retries + destinations)."
  default     = false
}

variable "async_retry_attempts" {
  type        = number
  description = "Async retry attempts (0-2)."
  default     = 2
}

variable "async_max_event_age" {
  type        = number
  description = "Max age of an async event before it is discarded, in seconds."
  default     = 3600
}

variable "on_failure_destination_arn" {
  type        = string
  description = "OnFailure destination for async invocations (SQS/SNS/EventBridge)."
  default     = null
}

variable "create_alias" {
  type        = bool
  description = "Create a 'live' alias for stable targeting and rollback."
  default     = false
}

variable "alias_name" {
  type        = string
  description = "Alias name when create_alias is true."
  default     = "live"
}

variable "subnet_ids" {
  type        = list(string)
  description = "VPC subnets; empty means no VPC attachment (and no ENI cold-start cost)."
  default     = []
}

variable "security_group_ids" {
  type        = list(string)
  description = "Security groups, only used when subnet_ids is non-empty."
  default     = []
}

# --- observability ----------------------------------------------------------

variable "log_level" {
  type        = string
  description = "Powertools log level."
  default     = "INFO"
}

variable "log_event" {
  type        = bool
  description = "Log the full inbound event. Keep false outside dev: PII risk + log cost."
  default     = false
}

variable "tracer_capture_response" {
  type        = bool
  description = "Capture handler responses in X-Ray metadata."
  default     = false
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention."
  default     = 14
}

variable "log_kms_key_arn" {
  type        = string
  description = "Optional CMK for log group encryption."
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource in the module."
  default     = {}
}
