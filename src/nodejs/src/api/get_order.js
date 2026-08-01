'use strict';

/**
 * GET /orders/{orderId}
 * GET /orders?customerId=...   (list by customer, via GSI1)
 */

const { withObservability, logger, metrics, MetricUnit } = require('../common/observability');
const { ok, notFound, errorResponse, ClientError } = require('../common/http');
const { getOrder, listOrdersByCustomer } = require('../common/orders');

/** Strip internal single-table keys before handing the item to a caller. */
function toPublic(item) {
  if (!item) return item;
  const { pk, sk, gsi1pk, gsi1sk, entityType, ttl, ...rest } = item;
  return rest;
}

async function handle(event, _context, { correlationId }) {
  try {
    const orderId = event.pathParameters?.orderId;
    const customerId = event.queryStringParameters?.customerId;

    if (orderId) {
      const order = await getOrder(orderId);
      if (!order) {
        metrics.addMetric('OrderNotFound', MetricUnit.Count, 1);
        return notFound(`Order ${orderId} not found`, correlationId);
      }
      logger.info('order fetched', { orderId, status: order.status });
      return ok({ order: toPublic(order), correlationId }, correlationId);
    }

    if (customerId) {
      const limit = Number(event.queryStringParameters?.limit || 25);
      if (!Number.isInteger(limit) || limit < 1) {
        throw new ClientError('limit must be a positive integer');
      }
      const orders = await listOrdersByCustomer(customerId, limit);
      logger.info('orders listed', { customerId, count: orders.length });
      return ok(
        { orders: orders.map(toPublic), count: orders.length, correlationId },
        correlationId
      );
    }

    throw new ClientError('Provide either a path orderId or a customerId query parameter');
  } catch (err) {
    if (err.name === 'ClientError') return errorResponse(err, correlationId);
    throw err;
  }
}

exports.handler = withObservability('getOrder', handle);
