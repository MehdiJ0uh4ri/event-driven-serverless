'use strict';

/**
 * GET /orders/{orderId}
 * GET /orders?customerId=...   (list by customer, via GSI1)
 */

const { withObservability, logger, metrics, MetricUnit } = require('../common/observability');
const { ok, notFound, errorResponse } = require('../common/http');
const { ClientError } = require('../common/errors');
const { getOrder, listOrdersByCustomer, toPublicOrder } = require('../common/orders');

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
      return ok({ order: toPublicOrder(order), correlationId }, correlationId);
    }

    if (customerId) {
      const limit = Number(event.queryStringParameters?.limit || 25);
      if (!Number.isInteger(limit) || limit < 1) {
        throw new ClientError('limit must be a positive integer');
      }
      const orders = await listOrdersByCustomer(customerId, limit);
      logger.info('orders listed', { customerId, count: orders.length });
      return ok(
        { orders: orders.map(toPublicOrder), count: orders.length, correlationId },
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

