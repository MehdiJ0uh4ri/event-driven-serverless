"""Audit consumer -- Python 3.12 + AWS Lambda Powertools.

Subscribes (via SQS) to every domain event on the bus and writes an immutable
audit record to DynamoDB. Deliberately written in Python while the rest of the
platform is Node, because that is the realistic case: teams mix runtimes, and
the correlation id has to survive the language boundary.

Partial batch failure is enabled: one bad message is returned as a
batchItemFailure so the other nine are still deleted from the queue. Messages
that exhaust the redrive policy land on the DLQ handled by
src/nodejs/src/events/dlq_processor.js.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone
from typing import Any

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.batch import BatchProcessor, EventType, process_partial_response
from aws_lambda_powertools.utilities.data_classes.sqs_event import SQSRecord
from aws_lambda_powertools.utilities.typing import LambdaContext
from botocore.config import Config

SERVICE_NAME = os.environ.get("POWERTOOLS_SERVICE_NAME", "order-platform")
AUDIT_TABLE_NAME = os.environ["AUDIT_TABLE_NAME"]
AUDIT_RETENTION_DAYS = int(os.environ.get("AUDIT_RETENTION_DAYS", "365"))

logger = Logger(service=SERVICE_NAME)
tracer = Tracer(service=SERVICE_NAME)
metrics = Metrics(service=SERVICE_NAME)

# Clients at module scope: created once per execution environment.
_boto_config = Config(retries={"max_attempts": 3, "mode": "adaptive"}, tcp_keepalive=True)
_dynamodb = boto3.resource("dynamodb", config=_boto_config)
_audit_table = _dynamodb.Table(AUDIT_TABLE_NAME)

processor = BatchProcessor(event_type=EventType.SQS)


class MalformedEventError(Exception):
    """Raised when a message cannot be interpreted as a domain event."""


def _unwrap(record: SQSRecord) -> dict[str, Any]:
    """Unwrap the EventBridge envelope that SQS delivered.

    EventBridge puts the whole event in the SQS body, with our own envelope
    nested under `detail`. Direct SQS sends (tests, replays) carry the envelope
    at the top level, so both shapes are accepted.
    """
    try:
        body = json.loads(record.body)
    except (json.JSONDecodeError, TypeError) as exc:
        raise MalformedEventError(f"body is not JSON: {exc}") from exc

    if not isinstance(body, dict):
        raise MalformedEventError("body is not a JSON object")

    envelope = body.get("detail", body)
    if not isinstance(envelope, dict) or "eventType" not in envelope:
        raise MalformedEventError("no domain event envelope found (missing eventType)")

    return envelope


def _ttl_epoch(days: int) -> int:
    return int((datetime.now(timezone.utc) + timedelta(days=days)).timestamp())


@tracer.capture_method
def record_handler(record: SQSRecord) -> dict[str, Any]:
    """Persist one domain event as an audit row. Idempotent on eventId."""
    envelope = _unwrap(record)

    event_id = envelope.get("eventId") or record.message_id
    event_type = envelope["eventType"]
    correlation_id = envelope.get("correlationId", "unknown")
    data = envelope.get("data") or {}
    order_id = data.get("orderId", "unknown")

    # Bind for every subsequent log line in this record's scope.
    logger.append_keys(correlation_id=correlation_id, order_id=order_id, event_type=event_type)
    tracer.put_annotation("correlationId", correlation_id)
    tracer.put_annotation("eventType", event_type)

    item = {
        "pk": f"AUDIT#{order_id}",
        "sk": f"{envelope.get('occurredAt', datetime.now(timezone.utc).isoformat())}#{event_id}",
        "eventId": event_id,
        "eventType": event_type,
        "eventVersion": envelope.get("eventVersion", "1.0"),
        "correlationId": correlation_id,
        "causationId": envelope.get("causationId"),
        "orderId": order_id,
        "source": envelope.get("source", "unknown"),
        "occurredAt": envelope.get("occurredAt"),
        "recordedAt": datetime.now(timezone.utc).isoformat(),
        "payload": json.dumps(data, default=str)[:32_000],
        "ttl": _ttl_epoch(AUDIT_RETENTION_DAYS),
    }

    try:
        _audit_table.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(pk) OR attribute_not_exists(sk)",
        )
        metrics.add_metric(name="AuditRecordsWritten", unit=MetricUnit.Count, value=1)
        logger.info("audit record written", extra={"event_id": event_id})
    except _audit_table.meta.client.exceptions.ConditionalCheckFailedException:
        # At-least-once delivery replayed a message we already stored.
        metrics.add_metric(name="AuditDuplicatesSkipped", unit=MetricUnit.Count, value=1)
        logger.info("duplicate event ignored", extra={"event_id": event_id})
    finally:
        logger.remove_keys(["correlation_id", "order_id", "event_type"])

    return {"eventId": event_id, "eventType": event_type}


@logger.inject_lambda_context(log_event=False, correlation_id_path='Records[0].messageAttributes.correlationId.stringValue')
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict[str, Any], context: LambdaContext) -> dict[str, Any]:
    record_count = len(event.get("Records", []))
    logger.info("audit batch received", extra={"record_count": record_count})
    metrics.add_metric(name="AuditBatchSize", unit=MetricUnit.Count, value=record_count)

    return process_partial_response(
        event=event,
        record_handler=record_handler,
        processor=processor,
        context=context,
    )
