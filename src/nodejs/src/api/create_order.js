'use strict';

/**
 * POST /orders
 *
 * Writes the order to DynamoDB, then publishes `order.created` onto the custom
 * event bus. The write happens first: an order that exists without an event can
 * be replayed by the reconciler, but an event without an order is a phantom.
 */

const { withObservability, logger, metrics, MetricUnit } = require('../common/observability');
const { created, errorResponse, parseJsonBody } = require('../common/http');
const { validateOrderInput, buildOrder, putOrder } = require('../common/orders');
const { EventType, buildEnvelope, publish } = require('../common/events');

async function handle(event, _context, { correlationId }) {
  try {
    const payload = parseJsonBody(event);
    const input = validateOrderInput(payload);
    const order = buildOrder(input, correlationId);

    await putOrder(order);
    logger.info('order persisted', {
      orderId: order.orderId,
      customerId: order.customerId,
      totalMinor: order.totalMinor,
    });

    await publish(
      buildEnvelope(
        EventType.ORDER_CREATED,
        {
          orderId: order.orderId,
          customerId: order.customerId,
          items: order.items,
          currency: order.currency,
          totalMinor: order.totalMinor,
          status: order.status,
          createdAt: order.createdAt,
        },
        { correlationId }
      )
    );

    metrics.addMetric('OrdersCreated', MetricUnit.Count, 1);
    metrics.addMetric('OrderValueMinor', MetricUnit.Count, order.totalMinor);

    return created(
      {
        orderId: order.orderId,
        status: order.status,
        total: order.total,
        currency: order.currency,
        createdAt: order.createdAt,
        correlationId,
      },
      correlationId,
      `/orders/${order.orderId}`
    );
  } catch (err) {
    if (err.name === 'ClientError') {
      metrics.addMetric('OrdersRejected', MetricUnit.Count, 1);
      logger.warn('order rejected', { reason: err.message, details: err.details });
      return errorResponse(err, correlationId);
    }
    throw err;
  }
}

exports.handler = withObservability('createOrder', handle);
