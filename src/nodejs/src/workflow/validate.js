'use strict';

/**
 * Step Functions task 1/3: validate.
 *
 * Business validation that goes beyond the syntactic check the API already did:
 * inventory limits, order value ceilings, customer standing. Distinguishes two
 * failure classes so the state machine can react differently:
 *
 *   ValidationError  -> terminal, do NOT retry (Catch -> fail path)
 *   TransientError   -> retryable, the state machine backs off and tries again
 */

const { withObservability, logger, metrics, MetricUnit } = require('../common/observability');
const { OrderStatus, updateOrderStatus } = require('../common/orders');
const { EventType, buildEnvelope, publish } = require('../common/events');

class ValidationError extends Error {
  constructor(message, violations = []) {
    super(message);
    this.name = 'ValidationError';
    this.violations = violations;
  }
}

class TransientError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TransientError';
  }
}

const MAX_ITEMS_PER_ORDER = Number(process.env.MAX_ITEMS_PER_ORDER || 50);
const MAX_ORDER_VALUE_MINOR = Number(process.env.MAX_ORDER_VALUE_MINOR || 1_000_000); // 10k

/**
 * Stand-in for a real inventory/credit service call. Isolated behind a function
 * so swapping in an HTTP client later does not disturb the state machine shape.
 */
async function checkInventory(items) {
  const unavailable = items.filter((i) => i.sku.startsWith('OOS-'));
  return { available: unavailable.length === 0, unavailable: unavailable.map((i) => i.sku) };
}

async function handle(event, _context, { correlationId }) {
  // The state machine passes the EventBridge detail through unchanged.
  const order = event.detail?.data || event.data || event;
  const { orderId } = order;

  if (!orderId) throw new ValidationError('Input is missing orderId');

  logger.info('validating order', { orderId, itemCount: order.items?.length });

  const violations = [];
  const items = order.items || [];

  if (items.length > MAX_ITEMS_PER_ORDER) {
    violations.push(`Order has ${items.length} line items, limit is ${MAX_ITEMS_PER_ORDER}`);
  }
  if (order.totalMinor > MAX_ORDER_VALUE_MINOR) {
    violations.push(
      `Order value ${order.totalMinor} exceeds ceiling ${MAX_ORDER_VALUE_MINOR} (minor units)`
    );
  }

  const inventory = await checkInventory(items);
  if (!inventory.available) {
    violations.push(`Out of stock: ${inventory.unavailable.join(', ')}`);
  }

  if (violations.length > 0) {
    metrics.addMetric('OrdersFailedValidation', MetricUnit.Count, 1);
    logger.warn('order failed business validation', { orderId, violations });
    throw new ValidationError(`Order ${orderId} failed validation`, violations);
  }

  await updateOrderStatus(orderId, OrderStatus.VALIDATED, { validatedAt: new Date().toISOString() });
  await publish(
    buildEnvelope(
      EventType.ORDER_VALIDATED,
      { orderId, customerId: order.customerId, totalMinor: order.totalMinor },
      { correlationId, causationId: event.detail?.eventId }
    )
  );

  metrics.addMetric('OrdersValidated', MetricUnit.Count, 1);

  return {
    ...order,
    status: OrderStatus.VALIDATED,
    correlationId,
    validation: { passed: true, checkedAt: new Date().toISOString() },
  };
}

exports.handler = withObservability('validateOrder', handle);
exports.ValidationError = ValidationError;
exports.TransientError = TransientError;
