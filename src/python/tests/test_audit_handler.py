"""Unit tests for the audit consumer's parsing logic.

The DynamoDB write itself is not mocked -- what is worth testing here is the
envelope unwrapping, because that is where the SQS/EventBridge shape mismatch
actually bites in production.

Run: python -m pytest src/python/tests -q
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

os.environ.setdefault("AUDIT_TABLE_NAME", "test-audit-table")
os.environ.setdefault("AWS_DEFAULT_REGION", "eu-west-1")

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "audit"))


@pytest.fixture(scope="module")
def audit_module():
    """Import lazily so the env vars above are set first."""
    boto3 = pytest.importorskip("boto3")
    pytest.importorskip("aws_lambda_powertools")
    # Stub the resource call so importing the module does not need credentials.
    original = boto3.resource
    boto3.resource = lambda *a, **kw: SimpleNamespace(Table=lambda name: SimpleNamespace(name=name))
    try:
        import handler  # noqa: PLC0415 -- deliberate late import

        return handler
    finally:
        boto3.resource = original


def _record(body: str | dict, message_id: str = "msg-1"):
    """Build the minimal SQSRecord shape the handler touches."""
    return SimpleNamespace(
        body=body if isinstance(body, str) else json.dumps(body),
        message_id=message_id,
    )


class TestUnwrap:
    def test_unwraps_an_eventbridge_delivery(self, audit_module):
        envelope = audit_module._unwrap(
            _record(
                {
                    "detail": {
                        "eventId": "e-1",
                        "eventType": "order.created",
                        "correlationId": "corr-1",
                        "data": {"orderId": "o-1"},
                    }
                }
            )
        )
        assert envelope["eventType"] == "order.created"
        assert envelope["correlationId"] == "corr-1"

    def test_accepts_a_top_level_envelope(self, audit_module):
        """Direct SQS sends -- replays and tests -- have no `detail` wrapper."""
        envelope = audit_module._unwrap(
            _record({"eventId": "e-2", "eventType": "order.completed", "data": {"orderId": "o-2"}})
        )
        assert envelope["eventType"] == "order.completed"

    def test_rejects_non_json(self, audit_module):
        with pytest.raises(audit_module.MalformedEventError, match="not JSON"):
            audit_module._unwrap(_record("this is not json"))

    def test_rejects_a_json_array(self, audit_module):
        with pytest.raises(audit_module.MalformedEventError, match="not a JSON object"):
            audit_module._unwrap(_record("[1, 2, 3]"))

    def test_rejects_an_envelope_without_an_event_type(self, audit_module):
        with pytest.raises(audit_module.MalformedEventError, match="missing eventType"):
            audit_module._unwrap(_record({"detail": {"data": {"orderId": "o-3"}}}))


class TestTtl:
    def test_ttl_is_in_the_future(self, audit_module):
        import time

        ttl = audit_module._ttl_epoch(365)
        days_out = (ttl - time.time()) / 86400
        assert 364 < days_out < 366

    def test_zero_days_is_now(self, audit_module):
        import time

        assert abs(audit_module._ttl_epoch(0) - time.time()) < 5
