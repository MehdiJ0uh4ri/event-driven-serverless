# Prod: PITR and deletion protection are switched on automatically by the
# `is_prod` local; what is set here are the deliberate policy choices.
aws_region  = "eu-west-1"
environment = "prod"

log_level          = "INFO"
log_retention_days = 90

api_throttle_rate_limit  = 500
api_throttle_burst_limit = 1000
monthly_cost_budget_usd  = 250

slo_availability_target     = 0.999
slo_api_latency_p99_ms      = 800
slo_workflow_success_target = 0.995
slo_event_freshness_seconds = 60

# Benchmarks deploy real (if tiny) functions; they do not belong in prod.
enable_coldstart_benchmark = false

alert_email = "platform-oncall@example.com"
