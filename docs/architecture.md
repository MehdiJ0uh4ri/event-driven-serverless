# Architecture decisions

The reasoning behind the choices that a reviewer would otherwise have to ask
about. Each section states the decision, the alternative, and what it costs.

---

## Custom event bus, not the default bus

**Decision.** All domain events go to `order-platform-<env>-bus`.

The default bus receives events from every AWS service in the account. Putting
domain events there means rules must filter aggressively to avoid matching AWS
service events, the bus cannot be governed independently, and there is no clean
way to give another team access to *our* events without giving them everything.

A custom bus also gets its own archive and replay, which is the recovery
mechanism the [runbook](runbook.md#recovery-replaying-failed-orders) depends on.

---

## Events carry a versioned envelope

Every event on the bus has the same shape:

```json
{
  "eventId": "uuid",
  "eventType": "order.created",
  "eventVersion": "1.0",
  "occurredAt": "2026-08-01T10:00:00.000Z",
  "correlationId": "uuid",
  "causationId": "uuid-of-the-event-that-caused-this",
  "source": "order.platform",
  "data": { }
}
```

`causationId` is the field teams regret not having. `correlationId` groups
everything belonging to one user request; `causationId` records which specific
event triggered this one, so the causal chain can be reconstructed rather than
just the set.

EventBridge rules match on `detail-type` and `source`, both of which are outside
`data`, so the payload can evolve without rewriting the routing.

---

## <a name="standard-vs-express"></a>Step Functions STANDARD, not EXPRESS

**Decision.** STANDARD, knowingly, and it is the largest line on the bill.

| | STANDARD | EXPRESS |
| --- | --- | --- |
| Billing | $25 per million state transitions | Per GB-second of duration |
| History | Full, queryable for 90 days | CloudWatch Logs only |
| Duration | Up to 1 year | Up to 5 minutes |
| Semantics | Exactly-once | At-least-once |

At the 2M-orders/month prod profile, STANDARD is ~60% of total spend — roughly
$249/month against a $412 total, where Lambda is under $8. EXPRESS would save
most of that.

**Why STANDARD anyway.** The workflow includes a `Wait` state for high-value
orders that a real implementation would extend into a human-approval callback,
which exceeds the 5-minute EXPRESS ceiling. And the durable execution history is
what makes the failure triage in the runbook possible: with EXPRESS, "which step
failed and with what input" is a log-mining exercise instead of one API call.

**When to revisit.** If the `Wait`/callback requirement goes away, or if volume
grows another 5×, EXPRESS plus explicit logging becomes the right trade. The
cost model in CI is what will surface that moment — it is designed to make this
decision visible rather than accidental.

---

## Two DynamoDB tables, not one

Single-table design is the DynamoDB default for good reasons, and the orders
table itself uses it (`ORDER#<id>` / `CUSTOMER#<id>` overloaded keys). But the
audit trail is separated deliberately:

- **Different access patterns.** Orders are read-modify-write on a hot key.
  Audit is append-only and read almost never, except during an incident.
- **Different lifecycles.** 90-day TTL vs 365-day.
- **Different permissions.** This is the deciding reason: with one table, the
  API role would need write access to audit rows, and the audit consumer would
  need access to order data. Two tables let each function's IAM policy name
  exactly one table, and it means the audit trail is genuinely independent —
  reconstructible from events alone, not from the operational store it audits.

---

## Least privilege, mechanically enforced

The [`lambda_function` module](../terraform/modules/lambda_function/) makes the
insecure option the harder one. It always creates a dedicated role, and the
baseline policy grants only:

- `logs:CreateLogStream` + `logs:PutLogEvents` on **that function's own log
  group ARN** — not `arn:aws:logs:*:*:*`
- `xray:PutTraceSegments` + `PutTelemetryRecords` on `*`, because the X-Ray
  ingestion APIs genuinely have no resource-level permissions

Everything else is a caller-supplied policy naming specific ARNs. The results
are worth reading as a set in [iam.tf](../terraform/iam.tf):

| Function | Can | Explicitly cannot |
| --- | --- | --- |
| `create-order` | `PutItem` on orders, `PutEvents` on the bus | Read anything |
| `get-order` | `GetItem`, `Query` | Write anything, touch the bus |
| `validate` / `enrich` | `UpdateItem`, `PutEvents` | `PutItem`, `DeleteItem` — cannot create or destroy an order |
| `notify` | The above, plus `Publish` to one topic | Publish to any other topic |
| `audit-consumer` | Consume one queue, `PutItem` to audit | Read the orders table at all |
| `dlq-processor` | Receive + delete on three DLQs | Write to any data store |

Two further hardening details: the assume-role policies carry an
`aws:SourceAccount` condition (confused-deputy guard), and the `events:PutEvents`
grants carry an `events:source` condition so a compromised function cannot spoof
events from another system.

### Checkov exceptions

CI runs Checkov with five documented skips. They are listed here rather than
buried in a config so they can be challenged:

| Check | Why skipped |
| --- | --- |
| `CKV_AWS_116` | Lambda DLQ — asserted at the event-source and EventBridge target level instead, which is where our failures actually occur |
| `CKV_AWS_117` | VPC attachment — these functions talk only to AWS APIs; a VPC would add ENI cold-start latency for no security gain |
| `CKV_AWS_158` | Log group CMK — the module supports `log_kms_key_arn`; the default AWS-managed key is appropriate for non-regulated data |
| `CKV_AWS_173` | Lambda env var CMK — no secrets are stored in environment variables; configuration only |
| `CKV2_AWS_5` | Security group attachment — no security groups are created |

---

## Retry policy: three classes of failure

Encoded in [stepfunctions.tf](../terraform/stepfunctions.tf) and matched on
`err.name`, which is why the error taxonomy lives in one dependency-free
[errors.js](../src/nodejs/src/common/errors.js).

| Class | Retried? | Policy | Reasoning |
| --- | --- | --- | --- |
| `Lambda.ServiceException`, `TooManyRequestsException`, … | Always | 4 attempts, 1s base, 2× backoff, full jitter | Service faults say nothing about the payload |
| `TransientError` | Yes | 3 attempts, 2s base, 2× backoff, full jitter | A dependency blipped; the same input may well succeed |
| `ValidationError` | **Never** | — | The input is bad and will stay bad. Retrying burns money and latency to reach the same answer |
| Anything else | Once | 1 attempt, 3s | Cautious middle ground for the unclassified |

**Full jitter**, not plain exponential backoff. Without jitter, every function
that failed during a dependency outage retries in lockstep and re-creates the
thundering herd that caused the outage.

**Every `Catch` preserves the original error** under `$.error` and the original
order under `$.order`. Without `ResultPath`, the catch would overwrite the state
input with the error and the failure handler would have no idea which order it
was compensating for.

---

## Three DLQs

| Queue | Fed by | Failure it represents |
| --- | --- | --- |
| `audit-dlq` | SQS redrive after 3 receives | The consumer ran and failed |
| `eventbridge-dlq` | EventBridge target `dead_letter_config` | Delivery never happened — IAM, or the target is gone |
| `workflow-dlq` | The state machine's last-resort `SendToDlq` state | The compensating handler itself failed |

These are three different incidents with three different first actions. A single
shared DLQ turns triage into archaeology.

The DLQ processor deliberately **does not retry**. It classifies, logs a
structured line that the runbook's Insights query keys on, emits a metric, and
deletes the message. Automatic redrive of a poisoned message is an infinite loop
with a bill attached; redrive is a human decision, documented in the
[runbook](runbook.md#redrive).

---

## Correlation ids across four transports

One id survives the whole path because it is carried redundantly — no single
mechanism spans every hop:

| Hop | Carrier |
| --- | --- |
| Client → API Gateway → Lambda | `x-correlation-id` HTTP header |
| Lambda → EventBridge → any target | `correlationId` in the event envelope |
| EventBridge → SQS → consumer | SQS message attribute, set by the rule's input transformer |
| Within a function | Powertools persistent log key + X-Ray annotation |

It is an X-Ray **annotation** rather than metadata specifically because
annotations are indexed, making `annotation.correlationId = "..."` a filterable
trace search rather than something you can only read after finding the trace.

The header wins over other sources when present: a caller that supplied its own
id is trying to join our traces to theirs, and honouring that is free.

---

## arm64 by default

Graviton is ~20% cheaper per GB-second and, in the benchmark sweep, no slower to
cold start for these workloads. The only reason to choose x86 is a native
dependency without an arm64 wheel — which is why `scripts/build.sh` passes
`--platform manylinux2014_aarch64` to pip explicitly rather than letting the
build host decide. A local build on an x86 laptop that silently ships x86 wheels
to an arm64 function fails at runtime, in production, with an import error.

---

## HTTP API, not REST API

~70% cheaper per million requests and lower latency. The REST-only features we
would give up are request validation models (validation is business logic and
belongs in the function, where it can return all violations at once), usage
plans and API keys (not needed here), and WAF integration (would matter for a
public production API — that is the trigger to revisit).

---

## What is deliberately not here

Honest scope boundaries, so their absence reads as a decision rather than an
oversight:

- **Authentication.** The API is open. A real deployment adds a JWT authorizer
  (Cognito or an external IdP) on the HTTP API — the route-level structure is
  already there to attach one.
- **Idempotency keys on `POST /orders`.** A client retry currently creates a
  second order. Powertools' idempotency utility with a DynamoDB backend is the
  standard fix; it is a table and a decorator away.
- **The `Wait` state is a placeholder.** A real high-value hold uses
  `waitForTaskToken` and a callback from the fraud team, not a fixed 30 seconds.
- **Multi-region.** Single region. The DynamoDB tables have streams enabled so
  global tables can be added without a table replacement.
- **Real dependencies.** `checkInventory` and `fetchCustomerProfile` are
  simulated, with `OOS-` and `FAIL-` prefixes as the trigger for the failure
  paths. That is what lets the smoke test exercise retry and catch behaviour on
  every deploy instead of hoping it works during a real outage.
