'use strict';

/**
 * Dead-letter queue processor.
 *
 * Triggered by the DLQ that collects messages the audit consumer could not
 * handle after its redrive policy was exhausted. It does not retry blindly:
 * it classifies each poisoned message, records it as a structured log line
 * queryable in CloudWatch Insights, and emits a metric that the SLO alarm
 * watches. Manual redrive is deliberate — see docs/runbook.md.
 *
 * Uses partial batch responses so one unparseable message does not force the
 * whole batch back onto the queue.
 */

const { withObservability, logger, metrics, MetricUnit } = require('../common/observability');

/** Best-effort classification so the runbook can route the alert. */
function classify(body) {
  if (!body || typeof body !== 'object') return 'MALFORMED_PAYLOAD';
  const detail = body.detail || body;
  if (!detail.eventType) return 'MISSING_EVENT_TYPE';
  if (!detail.data?.orderId) return 'MISSING_ORDER_ID';
  return 'DOWNSTREAM_FAILURE';
}

async function handle(event, _context, { correlationId }) {
  const records = event.Records || [];
  const batchItemFailures = [];
  const byReason = {};

  logger.warn('processing dead-letter batch', { count: records.length });

  for (const record of records) {
    let body;
    try {
      body = JSON.parse(record.body);
    } catch {
      body = null;
    }

    const reason = classify(body);
    byReason[reason] = (byReason[reason] || 0) + 1;

    const messageCorrelationId =
      body?.detail?.correlationId ||
      body?.correlationId ||
      record.messageAttributes?.correlationId?.stringValue ||
      correlationId;

    // One line per poisoned message: this is what the Insights query in
    // docs/runbook.md greps for.
    logger.error('dead_letter_message', {
      reason,
      messageId: record.messageId,
      correlationId: messageCorrelationId,
      eventType: body?.detail?.eventType || body?.eventType || null,
      orderId: body?.detail?.data?.orderId || body?.data?.orderId || null,
      approximateReceiveCount: record.attributes?.ApproximateReceiveCount,
      sentTimestamp: record.attributes?.SentTimestamp,
      sourceQueue: record.eventSourceARN,
      bodyPreview: String(record.body).slice(0, 512),
    });
  }

  metrics.addMetric('DeadLetterMessages', MetricUnit.Count, records.length);
  for (const [reason, count] of Object.entries(byReason)) {
    metrics.addMetadata(`dlqReason_${reason}`, count);
  }

  // Every message is accepted: they are recorded, and deleting them from the
  // DLQ prevents an infinite alarm loop. The record lives in CloudWatch Logs.
  return { batchItemFailures };
}

exports.handler = withObservability('dlqProcessor', handle);
exports.classify = classify;
