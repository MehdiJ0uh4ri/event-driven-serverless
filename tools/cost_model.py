#!/usr/bin/env python3
"""Projected monthly cost model for the event-driven order platform.

Runs in CI on every pull request. Reads the stack shape from Terraform outputs
(or a JSON file), applies a traffic profile, and prints a line-itemised monthly
projection. Exits non-zero when the projection exceeds the configured budget,
so a change that quietly makes the platform 5x more expensive fails the build
instead of surprising someone on the invoice.

The model is deliberately explicit rather than calling the AWS Pricing API:
prices are checked into version control, so a projection is reproducible and a
price change shows up as a reviewable diff.

Usage
-----
    # From a live stack
    terraform -chdir=terraform output -json > /tmp/tf.json
    python tools/cost_model.py --terraform-output /tmp/tf.json --profile profiles/prod.json

    # Standalone, using the defaults
    python tools/cost_model.py --requests-per-month 5000000 --budget 250

    # CI mode: machine-readable, non-zero exit on breach
    python tools/cost_model.py --terraform-output tf.json --format json --fail-on-breach
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Price book. us-east-1 / eu-west-1 on-demand, USD, verified 2026-07.
# Update deliberately, in one place, with the date you checked.
# ---------------------------------------------------------------------------
PRICES: dict[str, Any] = {
    "_meta": {"currency": "USD", "verified": "2026-07", "regions": ["us-east-1", "eu-west-1"]},
    "lambda": {
        # Per GB-second of billed duration.
        "gb_second_x86": 0.0000166667,
        "gb_second_arm": 0.0000133334,  # Graviton: ~20% cheaper
        # Per request.
        "request": 0.0000002,
        # Free tier, applied once per account per month.
        "free_gb_seconds": 400_000,
        "free_requests": 1_000_000,
    },
    "api_gateway_http": {
        # First 300M requests/month.
        "per_request": 0.0000010,
        "per_request_over_300m": 0.0000009,
    },
    "dynamodb_on_demand": {
        # Per write request unit / read request unit.
        "wru": 0.00000125,
        "rru": 0.00000025,
        "storage_gb_month": 0.25,
    },
    "eventbridge": {
        # Custom-bus events. Rule evaluations and archive replay are free;
        # archive *storage* is not.
        "per_event": 0.000001,
        "archive_gb_month": 0.10,
    },
    "sqs": {
        # Per request, where one request moves up to 10 messages (batching!).
        "per_request": 0.0000004,
        "free_requests": 1_000_000,
    },
    "sns": {
        "per_request": 0.0000005,
        "free_requests": 1_000_000,
    },
    "step_functions_standard": {
        # Per state transition. The dominant cost of a STANDARD workflow.
        "per_transition": 0.000025,
        "free_transitions": 4_000,
    },
    "cloudwatch": {
        "logs_ingest_gb": 0.50,
        "logs_storage_gb_month": 0.03,
        "custom_metric_month": 0.30,
        "alarm_month": 0.10,
        "dashboard_month": 3.00,  # first 3 dashboards are free
        "free_dashboards": 3,
    },
    "xray": {
        "traces_recorded": 0.000005,
        "traces_scanned": 0.0000005,
        "free_traces": 100_000,
    },
}

# States traversed per successful execution of the order workflow:
# Validate, Enrich, CheckOrderValue, Notify, Succeeded = 5.
# A failing execution traverses Validate, MarkXFailed, HandleFailure, Failed = 4.
TRANSITIONS_PER_SUCCESS = 5
TRANSITIONS_PER_FAILURE = 4


@dataclass
class TrafficProfile:
    """Assumptions about load. This is where the honest uncertainty lives."""

    name: str = "default"
    orders_per_month: int = 1_000_000
    # Reads are usually the larger number; customers poll their order status.
    reads_per_month: int = 3_000_000
    # Fraction of orders that fail the workflow.
    failure_rate: float = 0.02
    # Fraction of events that end up dead-lettered.
    dlq_rate: float = 0.001
    # Measured p50 durations in ms, per function role. Replace these with real
    # numbers from CloudWatch as soon as you have them -- see --from-cloudwatch.
    durations_ms: dict[str, float] = field(
        default_factory=lambda: {
            "create-order": 120.0,
            "get-order": 45.0,
            "validate-order": 80.0,
            "enrich-order": 150.0,
            "notify-customer": 110.0,
            "handle-failure": 90.0,
            "audit-consumer": 200.0,  # per batch of 10, not per message
            "dlq-processor": 60.0,
        }
    )
    # Average bytes of log emitted per invocation.
    log_bytes_per_invocation: int = 2_048
    # Average size of an order record and an audit record, in bytes.
    order_item_bytes: int = 1_500
    audit_item_bytes: int = 1_200
    # X-Ray sampling: 1 request/sec plus 5% of the rest, the AWS default.
    xray_sample_rate: float = 0.05

    @classmethod
    def from_file(cls, path: Path) -> "TrafficProfile":
        data = json.loads(path.read_text(encoding="utf-8"))
        known = {f for f in cls.__dataclass_fields__}
        unknown = set(data) - known
        if unknown:
            raise SystemExit(f"Unknown keys in profile {path}: {', '.join(sorted(unknown))}")
        return cls(**data)


@dataclass
class StackShape:
    """The deployed stack, as reported by Terraform."""

    region: str = "eu-west-1"
    environment: str = "dev"
    architecture: str = "arm64"
    budget_usd: float = 50.0
    # function name -> {"memory_mb": int, "runtime": str}
    functions: dict[str, dict[str, Any]] = field(default_factory=dict)
    alarm_count: int = 12
    dashboard_count: int = 1
    custom_metric_count: int = 14

    @classmethod
    def from_terraform_output(cls, path: Path) -> "StackShape":
        raw = json.loads(path.read_text(encoding="utf-8"))
        if "cost_model_inputs" not in raw:
            raise SystemExit(
                f"{path} has no 'cost_model_inputs' output. "
                "Run: terraform -chdir=terraform output -json > tf.json"
            )
        inputs = raw["cost_model_inputs"]["value"]
        return cls(
            region=inputs.get("region", "eu-west-1"),
            environment=inputs.get("environment", "dev"),
            architecture=inputs.get("architecture", "arm64"),
            budget_usd=float(inputs.get("budget_usd", 50)),
            functions=inputs.get("functions", {}),
        )

    @classmethod
    def default(cls) -> "StackShape":
        """The shape terraform/functions.tf produces, for standalone runs."""
        return cls(
            functions={
                "create-order": {"memory_mb": 1024, "runtime": "nodejs20.x"},
                "get-order": {"memory_mb": 512, "runtime": "nodejs20.x"},
                "validate-order": {"memory_mb": 512, "runtime": "nodejs20.x"},
                "enrich-order": {"memory_mb": 512, "runtime": "nodejs20.x"},
                "notify-customer": {"memory_mb": 512, "runtime": "nodejs20.x"},
                "handle-failure": {"memory_mb": 256, "runtime": "nodejs20.x"},
                "audit-consumer": {"memory_mb": 512, "runtime": "python3.12"},
                "dlq-processor": {"memory_mb": 256, "runtime": "nodejs20.x"},
            }
        )


@dataclass
class LineItem:
    service: str
    detail: str
    quantity: float
    unit: str
    monthly_usd: float


def _role_of(function_name: str) -> str:
    """Map a full function name back to its role key in the durations table."""
    for role in (
        "create-order",
        "get-order",
        "validate-order",
        "enrich-order",
        "notify-customer",
        "handle-failure",
        "audit-consumer",
        "dlq-processor",
    ):
        if function_name.endswith(role):
            return role
    return function_name


def _billed_ms(duration_ms: float) -> float:
    """Lambda bills in 1ms increments, rounded up."""
    return max(1.0, math.ceil(duration_ms))


def _invocation_counts(profile: TrafficProfile) -> dict[str, float]:
    """How many times each function runs per month, derived from the profile."""
    orders = profile.orders_per_month
    failures = orders * profile.failure_rate
    successes = orders - failures

    # Domain events published per order:
    #   success: created, validated, enriched, completed  = 4
    #   failure: created, (maybe validated), failed       ~ 2.5
    events = successes * 4 + failures * 2.5

    # The audit consumer batches up to 10 events per invocation. This single
    # factor is the difference between a $5 and a $50 audit pipeline.
    audit_invocations = events / 10

    return {
        "create-order": orders,
        "get-order": profile.reads_per_month,
        "validate-order": orders,
        "enrich-order": successes,  # skipped when validation fails
        "notify-customer": successes,
        "handle-failure": failures,
        "audit-consumer": audit_invocations,
        "dlq-processor": max(1.0, events * profile.dlq_rate / 10),
        "_events": events,
        "_successes": successes,
        "_failures": failures,
    }


def compute(profile: TrafficProfile, stack: StackShape, apply_free_tier: bool = True) -> tuple[list[LineItem], float]:
    """Return line items and the total projected monthly cost in USD."""
    items: list[LineItem] = []
    counts = _invocation_counts(profile)
    events = counts["_events"]
    successes = counts["_successes"]
    failures = counts["_failures"]

    gb_second_price = (
        PRICES["lambda"]["gb_second_arm"]
        if stack.architecture == "arm64"
        else PRICES["lambda"]["gb_second_x86"]
    )

    # --- Lambda -----------------------------------------------------------
    total_gb_seconds = 0.0
    total_invocations = 0.0

    for fn_name, cfg in (stack.functions or StackShape.default().functions).items():
        role = _role_of(fn_name)
        invocations = counts.get(role, 0.0)
        if invocations <= 0:
            continue
        duration = profile.durations_ms.get(role, 100.0)
        memory_gb = cfg.get("memory_mb", 512) / 1024
        gb_seconds = invocations * (_billed_ms(duration) / 1000) * memory_gb

        total_gb_seconds += gb_seconds
        total_invocations += invocations

        items.append(
            LineItem(
                service="Lambda",
                detail=f"{role} ({cfg.get('memory_mb', 512)}MB, {duration:.0f}ms)",
                quantity=round(gb_seconds, 1),
                unit="GB-s",
                monthly_usd=gb_seconds * gb_second_price,
            )
        )

    billable_gb_seconds = total_gb_seconds
    billable_invocations = total_invocations
    if apply_free_tier:
        billable_gb_seconds = max(0.0, total_gb_seconds - PRICES["lambda"]["free_gb_seconds"])
        billable_invocations = max(0.0, total_invocations - PRICES["lambda"]["free_requests"])
        # Re-scale the per-function compute lines so they sum to the billable total.
        if total_gb_seconds > 0:
            scale = billable_gb_seconds / total_gb_seconds
            for item in items:
                if item.service == "Lambda":
                    item.monthly_usd *= scale

    items.append(
        LineItem(
            service="Lambda",
            detail="invocation requests" + (" (after free tier)" if apply_free_tier else ""),
            quantity=round(billable_invocations),
            unit="requests",
            monthly_usd=billable_invocations * PRICES["lambda"]["request"],
        )
    )

    # --- API Gateway ------------------------------------------------------
    api_requests = profile.orders_per_month + profile.reads_per_month
    items.append(
        LineItem(
            service="API Gateway",
            detail="HTTP API requests",
            quantity=api_requests,
            unit="requests",
            monthly_usd=api_requests * PRICES["api_gateway_http"]["per_request"],
        )
    )

    # --- DynamoDB ---------------------------------------------------------
    # 1 WRU per 1KB written. The GSI doubles the write cost on the orders table.
    order_wru_per_write = math.ceil(profile.order_item_bytes / 1024)
    order_writes = profile.orders_per_month * order_wru_per_write * 2  # base + GSI
    status_updates = (successes * 3 + failures * 1) * order_wru_per_write * 2
    audit_wru = math.ceil(profile.audit_item_bytes / 1024)
    # Audit table has one GSI too.
    audit_writes = events * audit_wru * 2

    total_wru = order_writes + status_updates + audit_writes
    items.append(
        LineItem(
            service="DynamoDB",
            detail="write request units (incl. GSI replication)",
            quantity=round(total_wru),
            unit="WRU",
            monthly_usd=total_wru * PRICES["dynamodb_on_demand"]["wru"],
        )
    )

    # 1 RRU per 4KB, eventually-consistent reads are half an RRU.
    rru = profile.reads_per_month * max(1, math.ceil(profile.order_item_bytes / 4096)) * 0.5
    items.append(
        LineItem(
            service="DynamoDB",
            detail="read request units",
            quantity=round(rru),
            unit="RRU",
            monthly_usd=rru * PRICES["dynamodb_on_demand"]["rru"],
        )
    )

    # Storage: 90-day TTL on orders, 365-day on audit, at steady state.
    order_storage_gb = (profile.orders_per_month * 3 * profile.order_item_bytes) / 1e9
    audit_storage_gb = (events * 12 * profile.audit_item_bytes) / 1e9
    storage_gb = order_storage_gb + audit_storage_gb
    items.append(
        LineItem(
            service="DynamoDB",
            detail="storage at steady state",
            quantity=round(storage_gb, 2),
            unit="GB-month",
            monthly_usd=storage_gb * PRICES["dynamodb_on_demand"]["storage_gb_month"],
        )
    )

    # --- EventBridge ------------------------------------------------------
    items.append(
        LineItem(
            service="EventBridge",
            detail="custom bus events published",
            quantity=round(events),
            unit="events",
            monthly_usd=events * PRICES["eventbridge"]["per_event"],
        )
    )

    archive_gb = (events * 1_500) / 1e9  # ~1.5KB per archived event
    items.append(
        LineItem(
            service="EventBridge",
            detail="archive storage",
            quantity=round(archive_gb, 2),
            unit="GB-month",
            monthly_usd=archive_gb * PRICES["eventbridge"]["archive_gb_month"],
        )
    )

    # --- SQS --------------------------------------------------------------
    # Send (1 per event, EventBridge does not batch) + receive + delete.
    # Receives and deletes are batched at 10.
    sqs_requests = events + (events / 10) * 2
    billable_sqs = max(0.0, sqs_requests - PRICES["sqs"]["free_requests"]) if apply_free_tier else sqs_requests
    items.append(
        LineItem(
            service="SQS",
            detail="requests (batched receive/delete)",
            quantity=round(billable_sqs),
            unit="requests",
            monthly_usd=billable_sqs * PRICES["sqs"]["per_request"],
        )
    )

    # --- SNS --------------------------------------------------------------
    sns_requests = successes + failures  # customer notification + ops alert
    billable_sns = max(0.0, sns_requests - PRICES["sns"]["free_requests"]) if apply_free_tier else sns_requests
    items.append(
        LineItem(
            service="SNS",
            detail="publishes",
            quantity=round(billable_sns),
            unit="requests",
            monthly_usd=billable_sns * PRICES["sns"]["per_request"],
        )
    )

    # --- Step Functions ---------------------------------------------------
    transitions = successes * TRANSITIONS_PER_SUCCESS + failures * TRANSITIONS_PER_FAILURE
    billable_transitions = (
        max(0.0, transitions - PRICES["step_functions_standard"]["free_transitions"])
        if apply_free_tier
        else transitions
    )
    items.append(
        LineItem(
            service="Step Functions",
            detail=f"STANDARD state transitions ({TRANSITIONS_PER_SUCCESS}/success, {TRANSITIONS_PER_FAILURE}/failure)",
            quantity=round(billable_transitions),
            unit="transitions",
            monthly_usd=billable_transitions * PRICES["step_functions_standard"]["per_transition"],
        )
    )

    # --- CloudWatch -------------------------------------------------------
    log_gb = (total_invocations * profile.log_bytes_per_invocation) / 1e9
    items.append(
        LineItem(
            service="CloudWatch",
            detail="log ingestion",
            quantity=round(log_gb, 2),
            unit="GB",
            monthly_usd=log_gb * PRICES["cloudwatch"]["logs_ingest_gb"],
        )
    )

    # Stored logs at steady state, assuming the configured retention.
    stored_gb = log_gb * 0.5
    items.append(
        LineItem(
            service="CloudWatch",
            detail="log storage",
            quantity=round(stored_gb, 2),
            unit="GB-month",
            monthly_usd=stored_gb * PRICES["cloudwatch"]["logs_storage_gb_month"],
        )
    )

    items.append(
        LineItem(
            service="CloudWatch",
            detail="alarms",
            quantity=stack.alarm_count,
            unit="alarms",
            monthly_usd=stack.alarm_count * PRICES["cloudwatch"]["alarm_month"],
        )
    )

    billable_dashboards = max(0, stack.dashboard_count - PRICES["cloudwatch"]["free_dashboards"])
    items.append(
        LineItem(
            service="CloudWatch",
            detail="dashboards (first 3 free)",
            quantity=billable_dashboards,
            unit="dashboards",
            monthly_usd=billable_dashboards * PRICES["cloudwatch"]["dashboard_month"],
        )
    )

    items.append(
        LineItem(
            service="CloudWatch",
            detail="custom EMF metrics",
            quantity=stack.custom_metric_count,
            unit="metrics",
            monthly_usd=stack.custom_metric_count * PRICES["cloudwatch"]["custom_metric_month"],
        )
    )

    # --- X-Ray ------------------------------------------------------------
    traces = api_requests * profile.xray_sample_rate
    billable_traces = max(0.0, traces - PRICES["xray"]["free_traces"]) if apply_free_tier else traces
    items.append(
        LineItem(
            service="X-Ray",
            detail=f"traces recorded ({profile.xray_sample_rate:.0%} sampling)",
            quantity=round(billable_traces),
            unit="traces",
            monthly_usd=billable_traces * PRICES["xray"]["traces_recorded"],
        )
    )

    total = sum(i.monthly_usd for i in items)
    return items, total


def render_table(items: list[LineItem], total: float, stack: StackShape, profile: TrafficProfile) -> str:
    by_service: dict[str, float] = {}
    for item in items:
        by_service[item.service] = by_service.get(item.service, 0.0) + item.monthly_usd

    out: list[str] = []
    out.append("")
    out.append(f"  Projected monthly cost — {stack.environment} ({stack.region}, {stack.architecture})")
    out.append(f"  Profile: {profile.name} — {profile.orders_per_month:,} orders/mo, {profile.reads_per_month:,} reads/mo")
    out.append("  " + "─" * 84)
    out.append(f"  {'SERVICE':<16} {'LINE ITEM':<44} {'QUANTITY':>12} {'USD/MO':>9}")
    out.append("  " + "─" * 84)

    for item in sorted(items, key=lambda i: (-by_service[i.service], -i.monthly_usd)):
        qty = f"{item.quantity:,.0f}" if item.quantity >= 1000 else f"{item.quantity:,.2f}"
        out.append(f"  {item.service:<16} {item.detail[:44]:<44} {qty:>12} {item.monthly_usd:>9.2f}")

    out.append("  " + "─" * 84)
    out.append(f"  {'SUBTOTAL BY SERVICE':<16}")
    for service, cost in sorted(by_service.items(), key=lambda kv: -kv[1]):
        share = (cost / total * 100) if total else 0
        bar = "█" * int(share / 2.5)
        out.append(f"  {service:<16} {bar:<40} {cost:>8.2f}  {share:>5.1f}%")

    out.append("  " + "─" * 84)
    out.append(f"  {'TOTAL':<16} {'':<44} {'':>12} {total:>9.2f}")
    out.append(f"  {'BUDGET':<16} {'':<44} {'':>12} {stack.budget_usd:>9.2f}")

    headroom = stack.budget_usd - total
    if headroom >= 0:
        out.append(f"  {'HEADROOM':<16} {'':<44} {'':>12} {headroom:>9.2f}  ✓ within budget")
    else:
        out.append(f"  {'OVER BUDGET BY':<16} {'':<44} {'':>12} {-headroom:>9.2f}  ✗ BREACH")

    out.append("")
    out.append(f"  Cost per order: ${total / max(1, profile.orders_per_month) * 1000:.4f} per 1,000 orders")
    out.append(f"  Prices verified {PRICES['_meta']['verified']}. Free tier: applied.")
    out.append("")
    return "\n".join(out)


def render_markdown(items: list[LineItem], total: float, stack: StackShape, profile: TrafficProfile) -> str:
    """GitHub-flavoured markdown, for posting as a PR comment."""
    by_service: dict[str, float] = {}
    for item in items:
        by_service[item.service] = by_service.get(item.service, 0.0) + item.monthly_usd

    breach = total > stack.budget_usd
    verdict = "❌ **OVER BUDGET**" if breach else "✅ Within budget"

    lines = [
        f"### 💰 Projected monthly cost: **${total:,.2f}** / ${stack.budget_usd:,.2f} budget",
        "",
        f"{verdict} — `{stack.environment}` · {stack.region} · {stack.architecture} · profile `{profile.name}`",
        "",
        f"Assumes **{profile.orders_per_month:,}** orders/mo and **{profile.reads_per_month:,}** reads/mo "
        f"at a {profile.failure_rate:.1%} workflow failure rate.",
        "",
        "| Service | USD/mo | Share |",
        "| --- | ---: | ---: |",
    ]
    for service, cost in sorted(by_service.items(), key=lambda kv: -kv[1]):
        share = (cost / total * 100) if total else 0
        lines.append(f"| {service} | {cost:,.2f} | {share:.1f}% |")
    lines.append(f"| **Total** | **{total:,.2f}** | 100% |")
    lines.append("")
    lines.append(f"Cost per 1,000 orders: **${total / max(1, profile.orders_per_month) * 1000:.4f}**")
    lines.append("")
    lines.append("<details><summary>Full line items</summary>")
    lines.append("")
    lines.append("| Service | Line item | Quantity | Unit | USD/mo |")
    lines.append("| --- | --- | ---: | --- | ---: |")
    for item in sorted(items, key=lambda i: -i.monthly_usd):
        lines.append(
            f"| {item.service} | {item.detail} | {item.quantity:,.2f} | {item.unit} | {item.monthly_usd:,.4f} |"
        )
    lines.append("")
    lines.append("</details>")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--terraform-output", type=Path, help="JSON from `terraform output -json`")
    parser.add_argument("--profile", type=Path, help="Traffic profile JSON")
    parser.add_argument("--orders-per-month", type=int, help="Override orders/month")
    parser.add_argument("--reads-per-month", type=int, help="Override reads/month")
    parser.add_argument("--budget", type=float, help="Override the monthly budget in USD")
    parser.add_argument("--architecture", choices=["arm64", "x86_64"], help="Override architecture")
    parser.add_argument("--no-free-tier", action="store_true", help="Ignore the AWS free tier")
    parser.add_argument("--format", choices=["table", "json", "markdown"], default="table")
    parser.add_argument(
        "--fail-on-breach",
        action="store_true",
        help="Exit 1 when the projection exceeds the budget (use this in CI)",
    )
    parser.add_argument("--output", type=Path, help="Write the rendered report here as well as stdout")
    args = parser.parse_args(argv)

    stack = (
        StackShape.from_terraform_output(args.terraform_output)
        if args.terraform_output
        else StackShape.default()
    )
    profile = TrafficProfile.from_file(args.profile) if args.profile else TrafficProfile()

    if args.orders_per_month:
        profile.orders_per_month = args.orders_per_month
    if args.reads_per_month:
        profile.reads_per_month = args.reads_per_month
    if args.budget is not None:
        stack.budget_usd = args.budget
    if args.architecture:
        stack.architecture = args.architecture

    items, total = compute(profile, stack, apply_free_tier=not args.no_free_tier)

    if args.format == "json":
        report = json.dumps(
            {
                "environment": stack.environment,
                "region": stack.region,
                "architecture": stack.architecture,
                "profile": profile.name,
                "orders_per_month": profile.orders_per_month,
                "total_monthly_usd": round(total, 2),
                "budget_usd": stack.budget_usd,
                "within_budget": total <= stack.budget_usd,
                "cost_per_1000_orders_usd": round(total / max(1, profile.orders_per_month) * 1000, 4),
                "line_items": [asdict(i) for i in items],
            },
            indent=2,
        )
    elif args.format == "markdown":
        report = render_markdown(items, total, stack, profile)
    else:
        report = render_table(items, total, stack, profile)

    print(report)
    if args.output:
        args.output.write_text(report, encoding="utf-8")

    if total > stack.budget_usd:
        print(
            f"\nProjected ${total:,.2f}/mo exceeds the ${stack.budget_usd:,.2f} budget "
            f"by ${total - stack.budget_usd:,.2f}.",
            file=sys.stderr,
        )
        if args.fail_on_breach:
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
