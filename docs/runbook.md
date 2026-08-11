# Runbook

Every alarm description links here. Each section is written to be followed by
someone who did not build the system, at 3am.

**First move, always:** open the dashboard
(`terraform -chdir=terraform output -raw dashboard_url`, or `make dashboard`)
and read the four SLI widgets across the top. They tell you whether this is a
customer-facing outage or an internal backlog before you touch anything.

**Second move:** get a correlation id from any failing request — the API returns
it in the `x-correlation-id` response header and in the body of every error —
and follow it across the whole platform:

```bash
make trace CID=<correlation-id> ENV=prod
```

Or in the console: **CloudWatch → Logs Insights → Queries →
`order-platform-prod/Trace one request by correlation id`**.

---

## availability

**Alarm:** `slo-availability-fast-burn` (page) / `-slow-burn` (ticket)
**Means:** API Gateway is returning 5xx faster than the error budget sustains.

### Triage

```bash
ENV=prod

# 1. Which route is failing?
aws logs start-query \
  --log-group-name "/aws/apigateway/order-platform-$ENV-api" \
  --start-time $(( $(date +%s) - 1800 )) --end-time $(date +%s) \
  --query-string 'fields routeKey, status, integrationError
                  | filter status >= 500
                  | stats count() by routeKey, status, integrationError'

# 2. Is the function erroring, or timing out, or being throttled?
aws cloudwatch get-metric-statistics --namespace AWS/Lambda \
  --metric-name Errors --dimensions Name=FunctionName,Value=order-platform-$ENV-create-order \
  --start-time $(date -u -d '30 minutes ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 300 --statistics Sum
```

### Common causes, in the order they actually happen

| Symptom | Cause | Fix |
| --- | --- | --- |
| `integrationError` mentions permissions | An IAM policy was tightened past what the function needs | Check the scoped policy in [iam.tf](../terraform/iam.tf); the function's role is `order-platform-$ENV-<name>-role` |
| Errors start exactly at a deploy | Bad release | [Roll back](#rollback) |
| `Task timed out after N seconds` | DynamoDB slow, or a dependency hanging | Check the DynamoDB throttle widget; raise the timeout only after ruling out the dependency |
| Errors correlate with a traffic spike, `Throttles > 0` | Concurrency ceiling | See [#throttling](#throttling) |
| 5xx but Lambda `Errors` is flat | The failure is in API Gateway itself — check the integration and the route's Lambda permission | |

### Mitigation

If the cause is a bad release, roll back first and diagnose afterwards. The
error budget is spent while you investigate.

---

## latency

**Alarm:** `slo-api-latency-p99`
**Means:** the slowest 1% of requests are exceeding the objective.

### Triage

```bash
# Are we looking at cold starts or at slow warm invocations?
# Insights → order-platform-$ENV/Cold start init durations
```

Compare `Latency` against `IntegrationLatency` on the dashboard. A large gap
means the time is being spent in API Gateway (rare); a small gap means it is the
function.

| Finding | Cause | Fix |
| --- | --- | --- |
| p99 spiky, p50 flat, cold starts frequent | Scaling events | Raise memory (more CPU shortens init), or add provisioned concurrency to `create-order` |
| p50 and p99 both up | A dependency slowed down | Check the X-Ray service map for the widened edge |
| Gradual creep over weeks | Package growth, or an unindexed query | Compare `docs/benchmarks.md` against the current numbers; check for a DynamoDB `Scan` that should be a `Query` |
| Step change at a deploy | New dependency added to the bundle | Cold-start cost scales with package size — see [benchmarks.md](benchmarks.md) |

Provisioned concurrency eliminates cold starts but is billed hourly whether used
or not. Model it first: `python tools/cost_model.py --profile tools/profiles/prod.json`.

---

## workflow-failures

**Alarm:** `slo-workflow-success-rate`
**Means:** orders are being accepted by the API but not fulfilled. **Customer-visible.**

### Triage

```bash
ENV=prod
SM=$(terraform -chdir=terraform output -raw state_machine_arn)

# Recent failures
aws stepfunctions list-executions --state-machine-arn "$SM" \
  --status-filter FAILED --max-results 10

# Which step, and why
aws stepfunctions get-execution-history --execution-arn <arn> \
  --reverse-order --max-results 20 \
  --query 'events[?type==`ExecutionFailed` || type==`TaskFailed`]'
```

Or query the failures by stage across all of them:

```
# Insights → order-platform-$ENV/Errors grouped by function
fields @timestamp, orderId, stage, error, message
| filter message = "workflow failed"
| stats count() by stage, error
```

### Interpreting the stage

| Stage | Meaning | Likely cause |
| --- | --- | --- |
| `validate` + `ValidationError` | Orders are being **rejected**, not broken | An upstream client started sending bad data, or a business rule changed. Check `MAX_ORDER_VALUE_MINOR` / `MAX_ITEMS_PER_ORDER` and whether a real customer legitimately exceeded them |
| `enrich` + `TransientError` | The customer-profile dependency is down | Retries already ran (3 attempts, exponential backoff, full jitter) and were exhausted. This is a dependency incident |
| `notify` | SNS publish or the final DynamoDB update failed | The order was enriched but the customer was not told. Check the SNS topic policy |
| `unknown` | Something unclassified threw before `Validate` completed | Read the raw execution history |

### Recovery: replaying failed orders

Orders are not lost — they are in DynamoDB with `status = FAILED` and the cause
in the `failure` attribute. Once the underlying problem is fixed, replay the
events from the EventBridge archive:

```bash
aws events start-replay \
  --replay-name "recover-$(date +%s)" \
  --event-source-arn "$(terraform -chdir=terraform output -json | jq -r '.event_bus_arn.value')" \
  --event-start-time "$(date -u -d '2 hours ago' +%FT%TZ)" \
  --event-end-time "$(date -u +%FT%TZ)" \
  --destination '{"Arn":"<bus-arn>","FilterArns":["<order-created-rule-arn>"]}'
```

The workflow steps are idempotent (`UpdateItem` with fixed values, guarded by
`attribute_exists`), so a replay of an order that already succeeded is safe.

---

## dlq

**Alarm:** `dlq-audit-not-empty`, `dlq-eventbridge-not-empty`, `dlq-workflow-not-empty`
**Means:** messages have exhausted their retries. They will be **lost when the
14-day retention expires**.

Which queue fired tells you what kind of failure it was:

| Queue | What failed |
| --- | --- |
| `audit-dlq` | The audit consumer ran and failed 3 times on the same message |
| `eventbridge-dlq` | EventBridge could not deliver to a target at all — IAM, or the target is gone |
| `workflow-dlq` | The failure handler itself failed — the last-resort sink |

### Triage

The DLQ processor has already classified every message. Do not read raw
messages first — read its output:

```
# Insights → order-platform-$ENV/Dead letter messages by reason
fields @timestamp, reason, messageId, correlationId, orderId, eventType, bodyPreview
| filter message = "dead_letter_message"
| stats count() by reason, eventType
```

| Reason | Meaning | Action |
| --- | --- | --- |
| `MALFORMED_PAYLOAD` | Not valid JSON | A producer is broken. Fix the producer; these messages are not recoverable |
| `MISSING_EVENT_TYPE` / `MISSING_ORDER_ID` | Envelope contract violated | Someone published to the bus without the standard envelope |
| `DOWNSTREAM_FAILURE` | The event was fine; the consumer failed | Usually DynamoDB throttling or a deploy bug. **Redrive after fixing** |

### Redrive

Deliberately manual — automatic redrive of a poisoned message is an infinite
loop with a bill attached.

```bash
aws sqs start-message-move-task \
  --source-arn "$(terraform -chdir=terraform output -json queue_urls | jq -r '.audit_dlq')" \
  --max-number-of-messages-per-second 10
```

Watch `AuditRecordsWritten` climb and the DLQ drain. If messages come straight
back, stop and fix the consumer first.

---

## backlog

**Alarm:** `slo-event-freshness`
**Means:** the oldest unprocessed audit event is older than the objective.

### Triage

```bash
QUEUE=$(terraform -chdir=terraform output -json queue_urls | jq -r '.audit')
aws sqs get-queue-attributes --queue-url "$QUEUE" \
  --attribute-names ApproximateNumberOfMessages \
                    ApproximateNumberOfMessagesNotVisible \
                    ApproximateAgeOfOldestMessage
```

| Reading | Diagnosis | Fix |
| --- | --- | --- |
| Depth high, `NotVisible` high, age climbing | Consumer is running but too slow | Raise `maximum_concurrency` on the event source mapping (currently 10) |
| Depth high, `NotVisible` ≈ 0 | Consumer is not running at all | Check the event source mapping is `Enabled`; check the function is not throttled |
| Depth low, age high | A single message is stuck in a redelivery loop | It will reach the DLQ after 3 receives — wait, then see [#dlq](#dlq) |
| Both climbing after a deploy | New code is slower or erroring | [Roll back](#rollback) |

Raising concurrency raises DynamoDB write throughput on the audit table too —
check for throttles on that table before turning the dial far.

---

## throttling

**Alarm:** `{function}-throttled`
**Means:** Lambda rejected invocations before the code ran.

```bash
# Account-level concurrency headroom
aws lambda get-account-settings --query 'AccountLimit.ConcurrentExecutions'

# Is one function eating the pool?
# Dashboard → "Concurrency & throttling"
```

| Cause | Fix |
| --- | --- |
| Account concurrency limit reached | Request a quota increase; it is not instant, so mitigate first |
| One function starving the others | Set `reserved_concurrency` on the noisy one — reserving *caps* it as well as guaranteeing it |
| Legitimate traffic spike | Lower `api_throttle_rate_limit` to shed load at the edge rather than failing deep in the stack |

The API Gateway throttle in [api_gateway.tf](../terraform/api_gateway.tf) is the
fastest lever: it rejects at the edge, cheaply, before any Lambda is invoked.

---

## eventbridge

**Alarm:** `eventbridge-{rule}-failed`
**Means:** a rule matched an event but could not invoke its target.

This is nearly always IAM or a missing target. Check, in order:

1. Does the target still exist? (`aws events list-targets-by-rule --rule <name> --event-bus-name <bus>`)
2. Can EventBridge assume the role? For the Step Functions target that is
   `order-platform-$ENV-eventbridge-invoke-sfn`.
3. Does the target's resource policy allow the rule? For SQS, the queue policy
   names the rule ARN explicitly in [sqs.tf](../terraform/sqs.tf).

If the rule *matched nothing* rather than failing, the pattern is wrong. In
non-prod, the `log-all` rule tees every event to
`/aws/events/order-platform-$ENV-bus` — compare a real event against the pattern
there.

---

## audit-consumer

**Alarm:** `audit-consumer-error-rate`
**Means:** more than 5% of audit consumer invocations are failing.

Because the consumer uses partial batch responses, a single bad record fails
only itself. A 5% *invocation* error rate therefore means something systemic:

```
fields @timestamp, level, message, correlation_id, order_id
| filter level = "ERROR"
| sort @timestamp desc
| limit 50
```

Usual suspects: the audit table throttling, a malformed envelope from a new
producer, or an IAM change. The consumer only has `dynamodb:PutItem` on the
audit table — if someone added a read to the handler, it will fail here.

---

## rollback

Terraform holds the deployed state, so rolling back is redeploying the last good
commit:

```bash
git log --oneline -10
git checkout <last-good-sha>
make build
make apply ENV=prod
make smoke ENV=prod          # verify before declaring the incident over
```

For a single misbehaving function, the alias gives a faster path that does not
require a full apply:

```bash
aws lambda list-versions-by-function --function-name order-platform-prod-create-order
aws lambda update-alias --function-name order-platform-prod-create-order \
  --name live --function-version <previous>
```

Note that a Terraform apply will move the alias back to `$LATEST`, so treat this
as a mitigation, not a fix — follow it with a real revert.

---

## Escalation

| Situation | Escalate |
| --- | --- |
| Availability or workflow SLO burning fast and no cause found in 15 minutes | Page the service owner |
| Data loss suspected (DLQ near 14-day retention) | Page immediately; the deadline is real |
| An AWS service is degraded | Check the Health Dashboard, open a support case, communicate — do not keep debugging your own code |
