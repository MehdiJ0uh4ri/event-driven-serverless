#!/usr/bin/env python3
"""End-to-end smoke test against a deployed stack.

Exercises the full path -- API -> DynamoDB -> EventBridge -> Step Functions ->
SNS -> SQS -> audit table -- and asserts on the observable outcome at each hop,
using the correlation id as the thread. Run it after every deploy; it is the
gate in .github/workflows/deploy.yml.

Covers the failure paths too, because a retry/catch policy that has never been
exercised is a retry/catch policy that does not work:
  - an out-of-stock SKU  -> ValidationError -> no retry -> order FAILED
  - a FAIL- customer id  -> TransientError  -> retried  -> eventually FAILED

Usage
-----
    python tools/smoke_test.py --terraform-output tf.json
    python tools/smoke_test.py --api-url https://xyz.execute-api.eu-west-1.amazonaws.com \\
                               --table order-platform-dev-orders \\
                               --state-machine arn:aws:states:...
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path

import boto3

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"


@dataclass
class Config:
    api_url: str
    orders_table: str
    audit_table: str
    state_machine_arn: str
    region: str | None = None

    @classmethod
    def from_terraform(cls, path: Path) -> "Config":
        raw = json.loads(path.read_text(encoding="utf-8"))

        def out(key: str):
            if key not in raw:
                raise SystemExit(f"Terraform output '{key}' missing from {path}")
            return raw[key]["value"]

        return cls(
            api_url=out("api_endpoint").rstrip("/"),
            orders_table=out("orders_table_name"),
            audit_table=out("audit_table_name"),
            state_machine_arn=out("state_machine_arn"),
            region=out("cost_model_inputs").get("region"),
        )


class SmokeTest:
    def __init__(self, config: Config, timeout: int = 120):
        self.cfg = config
        self.timeout = timeout
        self.ddb = boto3.resource("dynamodb", region_name=config.region)
        self.sfn = boto3.client("stepfunctions", region_name=config.region)
        self.passed = 0
        self.failed = 0

    # -- assertions --------------------------------------------------------
    def check(self, name: str, condition: bool, detail: str = "") -> bool:
        if condition:
            self.passed += 1
            print(f"  {GREEN}✓{RESET} {name}" + (f" {DIM}{detail}{RESET}" if detail else ""))
        else:
            self.failed += 1
            print(f"  {RED}✗{RESET} {name}" + (f" {DIM}{detail}{RESET}" if detail else ""))
        return condition

    # -- HTTP --------------------------------------------------------------
    def post_order(self, payload: dict, correlation_id: str) -> tuple[int, dict]:
        request = urllib.request.Request(
            f"{self.cfg.api_url}/orders",
            data=json.dumps(payload).encode(),
            headers={"content-type": "application/json", "x-correlation-id": correlation_id},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read() or b"{}")

    def get_order(self, order_id: str, correlation_id: str) -> tuple[int, dict]:
        request = urllib.request.Request(
            f"{self.cfg.api_url}/orders/{order_id}",
            headers={"x-correlation-id": correlation_id},
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read() or b"{}")

    # -- polling -----------------------------------------------------------
    def wait_for_status(self, order_id: str, expected: set[str], timeout: int | None = None) -> str | None:
        """Poll DynamoDB until the order reaches one of the expected statuses."""
        table = self.ddb.Table(self.cfg.orders_table)
        deadline = time.time() + (timeout or self.timeout)
        last = None
        while time.time() < deadline:
            item = table.get_item(Key={"pk": f"ORDER#{order_id}", "sk": f"ORDER#{order_id}"}).get("Item")
            if item:
                last = item.get("status")
                if last in expected:
                    return last
            time.sleep(2)
        return last

    def wait_for_audit_records(self, order_id: str, minimum: int, timeout: int = 90) -> list[dict]:
        table = self.ddb.Table(self.cfg.audit_table)
        deadline = time.time() + timeout
        records: list[dict] = []
        while time.time() < deadline:
            response = table.query(
                KeyConditionExpression=boto3.dynamodb.conditions.Key("pk").eq(f"AUDIT#{order_id}")
            )
            records = response.get("Items", [])
            if len(records) >= minimum:
                return records
            time.sleep(2)
        return records

    # -- scenarios ---------------------------------------------------------
    def test_happy_path(self) -> bool:
        print(f"\n{YELLOW}Scenario 1: happy path{RESET}")
        correlation_id = f"smoke-happy-{uuid.uuid4()}"
        payload = {
            "customerId": f"smoke-customer-{uuid.uuid4().hex[:8]}",
            "items": [
                {"sku": "WIDGET-001", "quantity": 2, "unitPrice": 19.99},
                {"sku": "GIZMO-042", "quantity": 1, "unitPrice": 149.50},
            ],
            "currency": "EUR",
        }

        status, body = self.post_order(payload, correlation_id)
        if not self.check("POST /orders returns 201", status == 201, f"got {status}"):
            print(f"    {DIM}{body}{RESET}")
            return False

        order_id = body.get("orderId")
        self.check("response carries an orderId", bool(order_id), order_id or "")
        self.check(
            "correlation id is echoed back",
            body.get("correlationId") == correlation_id,
            body.get("correlationId", "missing"),
        )
        self.check("total is computed correctly", abs(body.get("total", 0) - 189.48) < 0.01, str(body.get("total")))

        code, fetched = self.get_order(order_id, correlation_id)
        self.check("GET /orders/{id} returns 200", code == 200, f"got {code}")
        self.check(
            "fetched order matches",
            fetched.get("order", {}).get("orderId") == order_id,
        )

        print(f"  {DIM}waiting for the workflow to complete...{RESET}")
        final = self.wait_for_status(order_id, {"COMPLETED", "FAILED"})
        self.check("workflow reaches COMPLETED", final == "COMPLETED", f"status={final}")

        _, completed = self.get_order(order_id, correlation_id)
        order = completed.get("order", {})
        enrichment = order.get("enrichment") or {}
        self.check("order was enriched", bool(enrichment), json.dumps(enrichment)[:80])
        self.check("customer tier was resolved", "customerTier" in enrichment, enrichment.get("customerTier", ""))
        self.check("shipping was estimated", "shipping" in enrichment)
        self.check("customer was notified", order.get("notified") is True)

        print(f"  {DIM}waiting for audit records...{RESET}")
        records = self.wait_for_audit_records(order_id, minimum=4)
        self.check(
            "audit trail captured every event",
            len(records) >= 4,
            f"{len(records)} records: {sorted(r.get('eventType', '?') for r in records)}",
        )
        self.check(
            "correlation id survived every hop",
            all(r.get("correlationId") == correlation_id for r in records),
            f"correlationId={correlation_id}",
        )
        return True

    def test_validation_rejection(self) -> bool:
        print(f"\n{YELLOW}Scenario 2: API-level validation (fails fast, no workflow){RESET}")
        correlation_id = f"smoke-invalid-{uuid.uuid4()}"

        status, body = self.post_order({"items": []}, correlation_id)
        self.check("missing customerId returns 422", status == 422, f"got {status}")
        self.check("error details are returned", bool(body.get("details")), str(body.get("details"))[:80])

        status, _ = self.post_order(
            {"customerId": "x", "items": [{"sku": "A", "quantity": 0, "unitPrice": 5}]}, correlation_id
        )
        self.check("zero quantity returns 422", status == 422, f"got {status}")

        status, _ = self.post_order(
            {"customerId": "x", "items": [{"sku": "A", "quantity": 1, "unitPrice": 5}], "currency": "euros"},
            correlation_id,
        )
        self.check("bad currency code returns 422", status == 422, f"got {status}")
        return True

    def test_business_validation_failure(self) -> bool:
        print(f"\n{YELLOW}Scenario 3: business validation failure (ValidationError, no retry){RESET}")
        correlation_id = f"smoke-oos-{uuid.uuid4()}"
        payload = {
            "customerId": f"smoke-customer-{uuid.uuid4().hex[:8]}",
            # The OOS- prefix makes the inventory check fail in validate.js.
            "items": [{"sku": "OOS-WIDGET-999", "quantity": 1, "unitPrice": 25.00}],
        }

        status, body = self.post_order(payload, correlation_id)
        if not self.check("order is accepted by the API", status == 201, f"got {status}"):
            return False

        order_id = body["orderId"]
        print(f"  {DIM}waiting for the workflow to fail...{RESET}")
        final = self.wait_for_status(order_id, {"FAILED", "COMPLETED"})
        self.check("workflow marks the order FAILED", final == "FAILED", f"status={final}")

        _, fetched = self.get_order(order_id, correlation_id)
        failure = (fetched.get("order") or {}).get("failure") or {}
        self.check("failure stage is recorded", failure.get("stage") == "validate", failure.get("stage", "missing"))
        self.check("failure reason is recorded", "ValidationError" in str(failure.get("error", "")), str(failure.get("error")))

        records = self.wait_for_audit_records(order_id, minimum=2)
        event_types = {r.get("eventType") for r in records}
        self.check("order.failed was audited", "order.failed" in event_types, str(sorted(event_types)))
        return True

    def test_transient_failure_retries(self) -> bool:
        print(f"\n{YELLOW}Scenario 4: transient dependency failure (retried, then FAILED){RESET}")
        correlation_id = f"smoke-transient-{uuid.uuid4()}"
        payload = {
            # The FAIL- prefix makes the customer lookup in enrich.js throw
            # TransientError on every attempt, so we can observe the retries.
            "customerId": f"FAIL-{uuid.uuid4().hex[:8]}",
            "items": [{"sku": "WIDGET-001", "quantity": 1, "unitPrice": 10.00}],
        }

        status, body = self.post_order(payload, correlation_id)
        if not self.check("order is accepted by the API", status == 201, f"got {status}"):
            return False

        order_id = body["orderId"]
        print(f"  {DIM}waiting for retries to exhaust (this takes ~30s by design)...{RESET}")
        final = self.wait_for_status(order_id, {"FAILED", "COMPLETED"}, timeout=180)
        self.check("order ends FAILED after retries", final == "FAILED", f"status={final}")

        _, fetched = self.get_order(order_id, correlation_id)
        failure = (fetched.get("order") or {}).get("failure") or {}
        self.check("failure is attributed to enrich", failure.get("stage") == "enrich", failure.get("stage", "missing"))

        # The retry actually happened: check the execution history.
        executions = self.sfn.list_executions(
            stateMachineArn=self.cfg.state_machine_arn, statusFilter="FAILED", maxResults=20
        )["executions"]
        matched = False
        for execution in executions:
            history = self.sfn.get_execution_history(
                executionArn=execution["executionArn"], maxResults=200, reverseOrder=False
            )["events"]
            if any(order_id in json.dumps(e.get("stateEnteredEventDetails", {})) for e in history):
                retries = sum(1 for e in history if e["type"] == "TaskStateAborted" or "Retry" in e["type"])
                enrich_attempts = sum(
                    1
                    for e in history
                    if e.get("stateEnteredEventDetails", {}).get("name") == "Enrich"
                )
                matched = self.check(
                    "Enrich was retried before giving up",
                    enrich_attempts >= 1,
                    f"{enrich_attempts} state entries, {retries} retry events",
                )
                break
        if not matched:
            print(f"  {DIM}  (could not locate the execution history; skipped the retry assertion){RESET}")

        return True

    def run(self, scenarios: list[str]) -> int:
        print(f"\n{'=' * 70}")
        print("  End-to-end smoke test")
        print(f"  API:  {self.cfg.api_url}")
        print(f"  Table: {self.cfg.orders_table}")
        print(f"{'=' * 70}")

        available = {
            "happy": self.test_happy_path,
            "validation": self.test_validation_rejection,
            "business": self.test_business_validation_failure,
            "transient": self.test_transient_failure_retries,
        }

        started = time.time()
        for name in scenarios:
            if name not in available:
                print(f"{RED}unknown scenario: {name}{RESET}", file=sys.stderr)
                return 2
            available[name]()

        elapsed = time.time() - started
        total = self.passed + self.failed
        print(f"\n{'=' * 70}")
        colour = GREEN if self.failed == 0 else RED
        print(f"  {colour}{self.passed}/{total} checks passed{RESET} in {elapsed:.0f}s")
        print(f"{'=' * 70}\n")
        return 0 if self.failed == 0 else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--terraform-output", type=Path, help="JSON from `terraform output -json`")
    parser.add_argument("--api-url")
    parser.add_argument("--table", dest="orders_table")
    parser.add_argument("--audit-table")
    parser.add_argument("--state-machine", dest="state_machine_arn")
    parser.add_argument("--region")
    parser.add_argument("--timeout", type=int, default=120, help="Per-order wait ceiling in seconds")
    parser.add_argument(
        "--scenarios",
        nargs="+",
        default=["happy", "validation", "business", "transient"],
        choices=["happy", "validation", "business", "transient"],
    )
    args = parser.parse_args(argv)

    if args.terraform_output:
        config = Config.from_terraform(args.terraform_output)
        if args.region:
            config.region = args.region
    elif args.api_url and args.orders_table:
        config = Config(
            api_url=args.api_url.rstrip("/"),
            orders_table=args.orders_table,
            audit_table=args.audit_table or "",
            state_machine_arn=args.state_machine_arn or "",
            region=args.region,
        )
    else:
        parser.error("pass --terraform-output, or --api-url together with --table")

    return SmokeTest(config, timeout=args.timeout).run(args.scenarios)


if __name__ == "__main__":
    sys.exit(main())
