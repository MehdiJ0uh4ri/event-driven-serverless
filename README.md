# Event-driven serverless platform on AWS

An order-processing platform built the way a production team would build it:
API Gateway → Lambda → DynamoDB on the synchronous path, EventBridge → SQS →
Step Functions on the asynchronous one, everything in IaC, with the
observability and cost controls that make it operable rather than just
deployable.

No console clicks. `terraform apply` (or `sam deploy`) creates the entire stack,
and CI can do it unattended.

```
                    ┌──────────────┐
   POST /orders ───▶│  API Gateway │
   GET  /orders     │   HTTP API   │
                    └──────┬───────┘
                           │ AWS_PROXY
                    ┌──────▼────────┐        ┌─────────────────┐
                    │ createOrder   │───────▶│  DynamoDB       │
                    │ getOrder      │        │  orders (+GSI1) │
                    │  (Node 20)    │        └─────────────────┘
                    └──────┬────────┘
                           │ PutEvents  (order.created)
                    ┌──────▼──────────────────────────────────┐
                    │       EventBridge custom bus            │
                    │       + 7-90 day replay archive         │
                    └──┬──────────────┬──────────────┬────────┘
        order.created  │   order.*    │  order.failed│
                       ▼              ▼              ▼
         ┌─────────────────────┐  ┌────────┐   ┌──────────┐
         │  Step Functions     │  │  SQS   │   │   SNS    │
         │  ┌───────────────┐  │  │ audit  │   │ ops      │
         │  │   Validate    │  │  └───┬────┘   │ alerts   │
         │  │      ▼        │  │      │        └──────────┘
         │  │   Enrich      │  │      ▼
         │  │      ▼        │  │  ┌──────────────┐   ┌──────────┐
         │  │ CheckValue ─▶ │  │  │auditConsumer │──▶│ DynamoDB │
         │  │   Wait        │  │  │  (Python)    │   │  audit   │
         │  │      ▼        │  │  └──────┬───────┘   └──────────┘
         │  │   Notify      │  │         │ 3 failures
         │  └───────┬───────┘  │         ▼
         │   Catch  ▼          │   ┌───────────┐   ┌──────────────┐
         │   HandleFailure     │   │ audit DLQ │──▶│ dlqProcessor │
         └──────────┬──────────┘   └───────────┘   └──────────────┘
                    │ on handler failure
                    ▼
            ┌───────────────┐
            │ workflow DLQ  │
            └───────────────┘

  X-Ray traces every arrow. One correlation id threads every box.
```

## What is here

| Area | Where | What it does |
| --- | --- | --- |
| Sync API | [src/nodejs/src/api/](src/nodejs/src/api/) | Create and read orders; validation, money maths, event publishing |
| Workflow | [src/nodejs/src/workflow/](src/nodejs/src/workflow/) | validate → enrich → notify, plus the compensating failure handler |
| Async consumer | [src/python/audit/](src/python/audit/) | SQS → immutable audit trail, Powertools, partial batch failures |
| DLQ triage | [src/nodejs/src/events/](src/nodejs/src/events/) | Classifies poisoned messages instead of retrying them blindly |
| Terraform | [terraform/](terraform/) | The whole stack, with a per-function least-privilege Lambda module |
| SAM | [sam/](sam/) | The same architecture, for the faster `sam sync` inner loop |
| Cost model | [tools/cost_model.py](tools/cost_model.py) | Line-itemised monthly projection; fails CI over budget |
| Benchmarks | [tools/coldstart_benchmark.py](tools/coldstart_benchmark.py) | p50/p95/p99 cold starts across Node, Python and Go |
| Smoke test | [tools/smoke_test.py](tools/smoke_test.py) | End-to-end gate on every deploy, including the failure paths |

## Quick start

```bash
# 1. Unit tests need nothing installed for the pure domain logic
cd src/nodejs && node --test tests/

# 2. Build every artefact (npm ci, pip install --platform, go build)
make build

# 3. Point Terraform at a state bucket you own
$EDITOR terraform/envs/dev/backend.hcl

# 4. Deploy
make init ENV=dev
make apply ENV=dev

# 5. Prove it works end to end -- including the retry and failure paths
make smoke ENV=dev
```

Then exercise it:

```bash
API=$(terraform -chdir=terraform output -raw api_endpoint)

curl -sS -X POST "$API/orders" \
  -H 'content-type: application/json' \
  -H 'x-correlation-id: my-trace-1' \
  -d '{
        "customerId": "cust-42",
        "items": [{"sku": "WIDGET-1", "quantity": 2, "unitPrice": 19.99}],
        "currency": "EUR"
      }' | jq

# Follow that exact request across all eight functions
make trace CID=my-trace-1 ENV=dev
```

Two SKU prefixes drive the failure paths on demand, which is how the smoke test
exercises retry/catch without waiting for a real outage:

- `OOS-*` → inventory check fails → `ValidationError` → **never retried**, straight to the failure handler
- customer id `FAIL-*` → enrichment dependency throws → `TransientError` → **retried with backoff**, then failed

## Design decisions worth defending

**One IAM role per function, always.** The `lambda_function` module makes it
structurally impossible to share a role: it creates one, attaches a
caller-supplied policy scoped to named ARNs, and adds only its own log group and
X-Ray. `getOrder` cannot write. The workflow steps can `UpdateItem` but not
`PutItem` or `DeleteItem` — they must never be able to create or destroy an
order. The audit consumer cannot read the orders table at all, because the audit
trail must be reconstructible from events alone.

**Three DLQs, not one.** A consumer that ran and failed, an EventBridge target
that could never be reached, and a workflow whose compensating handler itself
broke are three different incidents with three different runbook entries. One
shared DLQ makes triage guesswork.

**`ValidationError` is never retried.** Retrying bad input burns money and
latency to reach the same answer. The state machine distinguishes it from
`TransientError`, which gets exponential backoff with full jitter. The class
`name` is load-bearing — Step Functions matches `Retry`/`Catch` on it — which is
why the error taxonomy lives in one dependency-free
[errors.js](src/nodejs/src/common/errors.js).

**Alarms are pages, so they use burn rates.** A single 500 does not wake anyone.
The availability alarms use the multi-window burn-rate method from the Google
SRE workbook: fast burn (14.4× over 10 minutes) pages, slow burn (6× over 3
hours) opens a ticket. Every alarm sets `treat_missing_data` explicitly, because
the default silently hides a service that has stopped receiving traffic.

**Pure logic has no AWS imports.** Validation, money arithmetic and correlation
extraction live in modules that import nothing but `node:crypto`. The result is
that most of the test suite runs with zero dependencies installed — see
[order_model.js](src/nodejs/src/common/order_model.js).

**Money never touches a float.** Totals are computed in minor units, rounding
each unit price before multiplying, so `0.1 + 0.2` is exactly `30` cents. There
is a test that pins this.

## Observability

Three signals, joined by one correlation id that survives every hop — HTTP
header → event envelope → SQS message attribute → Powertools log key → X-Ray
annotation.

- **Traces.** X-Ray active on every function and on the state machine; SDK
  clients are captured, so DynamoDB, SNS and EventBridge calls appear on the
  service map. `correlationId` is an *annotation*, not metadata, so it is
  indexed and therefore searchable.
- **Logs.** Structured JSON via Powertools, one line per meaningful event.
  Five Insights queries are checked into
  [observability.tf](terraform/observability.tf) — including "trace one request
  by correlation id" and "cold start init durations" — so nobody composes them
  under pressure at 3am.
- **Metrics.** EMF custom metrics for the business funnel (`OrdersCreated` →
  `OrdersValidated` → `OrdersEnriched` → `OrdersCompleted`), which is what
  actually tells you whether the platform is doing its job.

The [dashboard](terraform/dashboard.tf) is ordered the way an incident is
diagnosed: headline SLIs, then the business funnel, then per-component health,
then the failure sinks, then cost drivers, then a live error log.

See [docs/slo.md](docs/slo.md) for the objectives and
[docs/runbook.md](docs/runbook.md) for what to do when one is breached.

## Cold-start benchmarking

```bash
make bench SAMPLES=25          # sweep 3 runtimes × 3 memory sizes
make bench-report              # write docs/benchmarks.md
```

The harness measures what Lambda actually *bills* as `Init Duration`, not a
client-side wall-clock guess. It forces a genuine cold start by publishing a new
function version — every version gets its own execution environment — then
invokes that qualifier and parses the `REPORT` line out of the inline log tail.
Percentiles are nearest-rank: with 25 samples, interpolating invents precision
that is not there. Published versions are cleaned up afterwards, because a sweep
otherwise leaves dozens of copies of the package against your account's code
storage quota.

## Cost model

```bash
make cost ENV=prod
```

CI runs this on every pull request against `tools/profiles/prod.json` and fails
the build if the projection exceeds the budget, then posts the breakdown as a PR
comment. Prices are checked into version control rather than fetched from the
Pricing API, so a projection is reproducible and a price change arrives as a
reviewable diff.

Running it against the prod profile surfaces the finding that matters most here:

| Service | Share of a 2M-order month |
| --- | ---: |
| Step Functions | **60.5%** |
| DynamoDB | 27.0% |
| CloudWatch | 4.5% |
| Everything else | 8.0% |

Lambda is under 2% of the bill. The dominant cost is Step Functions **STANDARD**
state transitions at $25 per million — at this volume, switching the workflow to
EXPRESS (billed on duration, not transitions) is worth roughly $240/month, at
the price of losing the durable execution history that makes the audit story
work. That trade-off is discussed in
[docs/architecture.md](docs/architecture.md#standard-vs-express); the point of
baking the model into CI is that the trade-off is *visible* before it is
expensive.

## Terraform or SAM?

Both are maintained and deploy the same architecture.

- **Terraform** is what CI deploys. It handles the parts SAM cannot express
  cleanly — the per-function IAM module, budgets, saved Insights queries, the
  dashboard, the benchmark matrix — and it sits alongside non-serverless
  infrastructure.
- **SAM** is the faster inner loop: `sam local invoke`, `sam sync --watch`, and
  a template that is much shorter because SAM generates the boilerplate.

Where they differ, [terraform/](terraform/) is the source of truth.

## Layout

```
├── src/
│   ├── nodejs/          API handlers, workflow steps, DLQ processor + tests
│   ├── python/          Audit consumer (Powertools) + tests
│   └── go/              Cold-start benchmark subject
├── terraform/           The stack; modules/lambda_function is the interesting bit
├── sam/                 Same architecture, SAM flavour
├── tools/               cost_model, coldstart_benchmark, smoke_test, profiles
├── scripts/build.sh     Reproducible packaging for all three runtimes
├── docs/                architecture, slo, runbook, benchmarks
└── .github/workflows/   ci (lint, test, scan, cost) and deploy (apply, smoke)
```

## Requirements

Terraform ≥ 1.6, Node 20, Python 3.12, Go 1.22 (optional — only the Go
benchmark needs it), AWS credentials with permission to create the stack.
