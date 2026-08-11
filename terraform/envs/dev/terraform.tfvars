# Dev: cheap, chatty, everything enabled.
aws_region  = "eu-west-1"
environment = "dev"

log_level          = "DEBUG"
log_retention_days = 7

# Generous relative to the traffic dev actually sees, but low enough that a
# runaway test loop cannot generate a surprising bill.
api_throttle_rate_limit  = 50
api_throttle_burst_limit = 100
monthly_cost_budget_usd  = 10

# Looser targets: dev is where things break on purpose.
slo_availability_target     = 0.95
slo_api_latency_p99_ms      = 2000
slo_workflow_success_target = 0.90
slo_event_freshness_seconds = 300

enable_coldstart_benchmark = true
benchmark_memory_sizes     = [128, 512, 1024]

# alert_email = "platform-oncall@example.com"
