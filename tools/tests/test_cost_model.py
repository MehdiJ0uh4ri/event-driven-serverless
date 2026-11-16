"""Tests for the cost model.

The model gates CI, so its arithmetic has to be trustworthy. These tests pin
the properties that matter: monotonicity, the direction of the architecture and
batching effects, and the budget verdict.

Run: python -m pytest tools/tests -q
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from cost_model import (  # noqa: E402
    PRICES,
    StackShape,
    TrafficProfile,
    _billed_ms,
    _invocation_counts,
    _role_of,
    compute,
)


@pytest.fixture
def stack():
    return StackShape.default()


@pytest.fixture
def profile():
    return TrafficProfile(name="test", orders_per_month=1_000_000, reads_per_month=3_000_000)


class TestHelpers:
    def test_billed_ms_rounds_up(self):
        assert _billed_ms(0.4) == 1
        assert _billed_ms(1.1) == 2
        assert _billed_ms(120.0) == 120

    def test_billed_ms_has_a_floor_of_one(self):
        assert _billed_ms(0) == 1

    def test_role_is_derived_from_the_function_suffix(self):
        assert _role_of("order-platform-prod-create-order") == "create-order"
        assert _role_of("order-platform-dev-audit-consumer") == "audit-consumer"

    def test_unknown_names_fall_through_unchanged(self):
        assert _role_of("something-else") == "something-else"


class TestInvocationCounts:
    def test_enrich_runs_only_for_orders_that_pass_validation(self, profile):
        profile.failure_rate = 0.1
        counts = _invocation_counts(profile)
        assert counts["validate-order"] == profile.orders_per_month
        assert counts["enrich-order"] == pytest.approx(profile.orders_per_month * 0.9)

    def test_audit_invocations_reflect_batching(self, profile):
        counts = _invocation_counts(profile)
        # 10 events per invocation, so audit invocations are ~1/10 of events.
        assert counts["audit-consumer"] == pytest.approx(counts["_events"] / 10)

    def test_failure_rate_splits_the_order_volume(self, profile):
        profile.failure_rate = 0.25
        counts = _invocation_counts(profile)
        assert counts["_successes"] + counts["_failures"] == profile.orders_per_month


class TestCompute:
    def test_produces_a_positive_total(self, profile, stack):
        items, total = compute(profile, stack)
        assert total > 0
        assert len(items) > 10

    def test_cost_grows_with_traffic(self, stack):
        small = TrafficProfile(orders_per_month=100_000, reads_per_month=300_000)
        large = TrafficProfile(orders_per_month=10_000_000, reads_per_month=30_000_000)
        _, small_total = compute(small, stack)
        _, large_total = compute(large, stack)
        assert large_total > small_total * 10

    def test_arm64_is_cheaper_than_x86(self, profile):
        arm = StackShape.default()
        arm.architecture = "arm64"
        x86 = StackShape.default()
        x86.architecture = "x86_64"

        _, arm_total = compute(profile, arm, apply_free_tier=False)
        _, x86_total = compute(profile, x86, apply_free_tier=False)

        assert arm_total < x86_total
        # Graviton is ~20% off the compute component, not the whole bill.
        assert 0.90 < arm_total / x86_total < 1.0

    def test_free_tier_reduces_the_total(self, profile, stack):
        _, with_free = compute(profile, stack, apply_free_tier=True)
        _, without_free = compute(profile, stack, apply_free_tier=False)
        assert with_free < without_free

    def test_more_memory_costs_more(self, profile):
        cheap = StackShape.default()
        expensive = StackShape.default()
        for cfg in expensive.functions.values():
            cfg["memory_mb"] *= 2

        _, cheap_total = compute(profile, cheap, apply_free_tier=False)
        _, expensive_total = compute(profile, expensive, apply_free_tier=False)
        assert expensive_total > cheap_total

    def test_step_functions_transitions_are_a_real_line_item(self, profile, stack):
        items, _ = compute(profile, stack)
        sfn = [i for i in items if i.service == "Step Functions"]
        assert len(sfn) == 1
        assert sfn[0].monthly_usd > 0

    def test_every_expected_service_is_represented(self, profile, stack):
        items, _ = compute(profile, stack)
        services = {i.service for i in items}
        assert services >= {
            "Lambda",
            "API Gateway",
            "DynamoDB",
            "EventBridge",
            "SQS",
            "SNS",
            "Step Functions",
            "CloudWatch",
            "X-Ray",
        }

    def test_line_items_sum_to_the_total(self, profile, stack):
        items, total = compute(profile, stack)
        assert sum(i.monthly_usd for i in items) == pytest.approx(total)

    def test_zero_traffic_still_costs_the_fixed_components(self, stack):
        idle = TrafficProfile(orders_per_month=0, reads_per_month=0)
        _, total = compute(idle, stack)
        # Alarms and metrics are billed whether or not anyone calls the API.
        assert total > 0


class TestBudget:
    def test_a_small_stack_fits_a_generous_budget(self, stack):
        stack.budget_usd = 1000
        _, total = compute(TrafficProfile(orders_per_month=10_000, reads_per_month=30_000), stack)
        assert total < stack.budget_usd

    def test_a_large_stack_breaches_a_tight_budget(self, stack):
        stack.budget_usd = 10
        _, total = compute(TrafficProfile(orders_per_month=50_000_000, reads_per_month=150_000_000), stack)
        assert total > stack.budget_usd


class TestPriceBook:
    def test_prices_carry_a_verification_date(self):
        assert PRICES["_meta"]["verified"]

    def test_graviton_is_priced_below_x86(self):
        assert PRICES["lambda"]["gb_second_arm"] < PRICES["lambda"]["gb_second_x86"]

    def test_no_price_is_negative(self):
        def walk(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    if key.startswith("_"):
                        continue
                    walk(value)
            elif isinstance(node, (int, float)):
                assert node >= 0

        walk(PRICES)
