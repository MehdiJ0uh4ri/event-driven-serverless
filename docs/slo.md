# Service level objectives

Four SLIs, each with an objective, an error budget, and an alarm that fires on
budget *burn rate* rather than on raw error counts. Thresholds live in
[terraform/variables.tf](../terraform/variables.tf); the alarms are in
[terraform/observability.tf](../terraform/observability.tf).

## Why burn rates

An alarm on "5 errors in 5 minutes" pages at 3am for a blip that consumed 0.01%
of the month's budget, and stays silent through a slow leak that consumes all of
it. The multi-window burn-rate method from the Google SRE workbook fixes both:
alert when the *rate of budget consumption* implies the budget will be gone
before the window closes.

For a 99.5% availability target, the error budget is 0.5% of requests. A burn
rate of 1× exhausts it in exactly 30 days.

| Burn rate | Budget gone in | Window | Action | Threshold at 99.5% |
| ---: | --- | --- | --- | ---: |
| 14.4× | ~2 days | 10 min (2 × 5min) | **Page** | 7.2% error rate |
| 6× | ~5 days | 3 h (3 × 1h) | Ticket | 3.0% error rate |

Both are computed in [locals.tf](../terraform/locals.tf) from
`slo_availability_target`, so changing the objective moves the alarms with it.

---

## SLO 1 — API availability

**SLI.** `1 − (API Gateway 5xx / API Gateway Count)`, measured at the edge.

4xx responses are deliberately excluded. A client sending an invalid order is
the platform working correctly; counting it against availability would mean a
badly-behaved integration could exhaust our budget.

| Environment | Objective | Monthly budget |
| --- | ---: | ---: |
| prod | 99.9% | 43m 12s of total failure |
| dev | 95% | — |

**Alarms.** `slo-availability-fast-burn` (page), `slo-availability-slow-burn`
(ticket). Both `treat_missing_data = notBreaching`: no traffic is not an outage.

**Runbook.** [#availability](runbook.md#availability)

---

## SLO 2 — API latency

**SLI.** p99 of API Gateway `Latency` (the full round trip, including the
integration).

| Environment | Objective |
| --- | ---: |
| prod | p99 ≤ 800ms |
| dev | p99 ≤ 2000ms |

p99 rather than p95 because the tail is where cold starts live, and a cold start
is exactly the serverless failure mode a user notices. The benchmark data in
[benchmarks.md](benchmarks.md) is what makes this objective achievable — it is
how the memory sizes in [functions.tf](../terraform/functions.tf) were chosen.

**Alarm.** `slo-api-latency-p99`, 2 of 3 five-minute periods.

**Runbook.** [#latency](runbook.md#latency)

---

## SLO 3 — Workflow success rate

**SLI.** `ExecutionsSucceeded / ExecutionsStarted` on the order state machine,
over 15-minute windows.

| Environment | Objective |
| --- | ---: |
| prod | 99.5% |
| dev | 90% |

This is the SLO that matters most to the business and the one a naive
availability metric misses entirely: the API can be returning a clean 201 for
every request while every single order silently fails to be fulfilled.

Orders that fail *business* validation still count as failed executions. That is
intentional — a spike in rejected orders is something the team needs to know
about, whether the cause is a bug or a bad upstream feed.

**Alarm.** `slo-workflow-success-rate` (page).

**Runbook.** [#workflow-failures](runbook.md#workflow-failures)

---

## SLO 4 — Event freshness

**SLI.** `ApproximateAgeOfOldestMessage` on the audit queue.

| Environment | Objective |
| --- | ---: |
| prod | ≤ 60s |
| dev | ≤ 300s |

Age, not depth. A queue holding 10,000 messages that is draining at 10,000/s is
healthy; a queue holding 3 messages that has not moved in an hour is broken.
Depth alone cannot tell those apart, so it is charted but not alarmed on.

**Alarm.** `slo-event-freshness`, 3 consecutive one-minute periods.

**Runbook.** [#backlog](runbook.md#backlog)

---

## Alarms that are not SLOs

These fire on *any* occurrence, because any occurrence means data is stuck and a
human has to look:

| Alarm | Why it is binary |
| --- | --- |
| `dlq-{audit,eventbridge,workflow}-not-empty` | A message on a DLQ is data that will be lost when retention expires |
| `eventbridge-{rule}-failed` | EventBridge could not reach a target at all — usually IAM or a deleted target |
| `{function}-throttled` | Requests are being rejected before the code ever runs |
| `audit-consumer-error-rate` | Catches a consumer that runs but fails every record, quietly draining to the DLQ |

## Error budget policy

A suggested policy, worth agreeing with whoever owns the roadmap *before* the
first incident:

- **Budget > 50% remaining** — ship freely.
- **Budget < 50%** — new work continues; reliability items get priority in the
  backlog.
- **Budget exhausted** — feature freeze until the budget recovers, with the
  exception of changes that improve reliability. The freeze is the mechanism
  that makes an SLO real rather than decorative.

## Reviewing the targets

Revisit quarterly. Two failure modes to watch for:

- **Never breached in six months.** The target is too loose to constrain
  anything, and is buying reliability nobody asked for. Tighten it.
- **Breached constantly.** Either the target is aspirational rather than
  achievable, or there is real work to do. Decide which — an SLO that is
  permanently red trains everyone to ignore alarms.
