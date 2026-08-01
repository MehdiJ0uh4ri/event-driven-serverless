'use strict';

/**
 * Step Functions Catch target.
 *
 * Marks the order FAILED, emits `order.failed` so alerting and any compensating
 * consumers can react, and returns a structured summary that becomes the
 * execution output. Never throws for business failures — if this step threw,
 * the failure detail would be replaced by this function's own error and the
 * original cause would be lost.
 */

const { withObservability, logger, metrics, MetricUnit } = require('../common/observability');
const { OrderStatus, updateOrderStatus } = require('../common/orders');
const { EventType, buildEnvelope, publish } = require('../common/events');

/** Step Functions serialises the Cause as a JSON string for Lambda errors. */
function parseCause(rawCause) {
  if (!rawCause) return {};
  try {
    const parsed = JSON.parse(rawCause);
    return {
      errorType: parsed.errorType,
      errorMessage: parsed.errorMessage,
      trace: Array.isArray(parsed.trace) ? parsed.trace.slice(0, 5) : undefined,
    };
  } catch {
    return { errorMessage: String(rawCause).slice(0, 1024) };
  }
}

async function handle(event, _context, { correlationId }) {
  const order = event.order?.detail?.data || event.order?.data || event.order || {};
  const orderId = order.orderId || event.orderId;
  const error = event.error || {};
  const cause = parseCause(error.Cause);

  const failure = {
    stage: event.stage || 'unknown',
    error: error.Error || cause.errorType || 'UnknownError',
    message: cause.errorMessage || 'No cause supplied',
    failedAt: new Date().toISOString(),
    correlationId,
  };

  logger.error('workflow failed', { orderId, ...failure, trace: cause.trace });
  metrics.addMetric('OrdersFailed', MetricUnit.Count, 1);
  metrics.addMetadata('failureStage', failure.stage);

  if (orderId) {
    try {
      await updateOrderStatus(orderId, OrderStatus.FAILED, { failure });
    } catch (err) {
      // The order may never have been written (validation rejected the input).
      logger.warn('could not mark order failed', { orderId, reason: err.message });
    }

    try {
      await publish(
        buildEnvelope(
          EventType.ORDER_FAILED,
          { orderId, customerId: order.customerId, ...failure },
          { correlationId }
        )
      );
    } catch (err) {
      logger.error('could not publish order.failed', { orderId, reason: err.message });
    }
  }

  return { orderId, status: OrderStatus.FAILED, failure, correlationId };
}

exports.handler = withObservability('handleFailure', handle);
exports.parseCause = parseCause;
