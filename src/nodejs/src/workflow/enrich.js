'use strict';

/**
 * Step Functions task 2/3: enrich.
 *
 * Decorates the validated order with data from downstream systems (customer
 * tier, pricing adjustments, shipping estimate). This is the step most likely
 * to hit a flaky dependency, so it throws TransientError on dependency trouble
 * and lets the state machine's Retry block handle the backoff.
 */

const { withObservability, logger, metrics, MetricUnit } = require('../common/observability');
const { OrderStatus, updateOrderStatus } = require('../common/orders');
const { EventType, buildEnvelope, publish } = require('../common/events');

class TransientError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TransientError';
  }
}

const TIER_DISCOUNT_BPS = { PLATINUM: 1000, GOLD: 500, SILVER: 200, STANDARD: 0 };

/**
 * Simulated customer-profile lookup. `FAIL-` prefixed customer ids model a
 * dependency outage so the retry/catch behaviour can be exercised end to end.
 */
async function fetchCustomerProfile(customerId) {
  if (customerId.startsWith('FAIL-')) {
    throw new TransientError(`Customer service unavailable for ${customerId}`);
  }
  const hash = [...customerId].reduce((a, c) => a + c.charCodeAt(0), 0);
  const tiers = ['STANDARD', 'SILVER', 'GOLD', 'PLATINUM'];
  return {
    customerId,
    tier: tiers[hash % tiers.length],
    region: hash % 2 === 0 ? 'eu-west' : 'eu-central',
    lifetimeOrders: hash % 137,
  };
}

function estimateShipping(items, region) {
  const units = items.reduce((sum, i) => sum + i.quantity, 0);
  const base = region === 'eu-west' ? 499 : 599;
  return { carrier: 'DHL', costMinor: base + Math.max(0, units - 1) * 120, etaDays: units > 10 ? 5 : 2 };
}

async function handle(event, _context, { correlationId }) {
  const order = event.detail?.data || event.data || event;
  const { orderId, customerId } = order;

  logger.info('enriching order', { orderId, customerId });

  const profile = await fetchCustomerProfile(customerId);
  const discountBps = TIER_DISCOUNT_BPS[profile.tier] ?? 0;
  const discountMinor = Math.round((order.totalMinor * discountBps) / 10_000);
  const shipping = estimateShipping(order.items || [], profile.region);
  const payableMinor = order.totalMinor - discountMinor + shipping.costMinor;

  const enrichment = {
    customerTier: profile.tier,
    customerRegion: profile.region,
    lifetimeOrders: profile.lifetimeOrders,
    discountBps,
    discountMinor,
    shipping,
    payableMinor,
    enrichedAt: new Date().toISOString(),
  };

  await updateOrderStatus(orderId, OrderStatus.ENRICHED, { enrichment });
  await publish(
    buildEnvelope(
      EventType.ORDER_ENRICHED,
      { orderId, customerId, payableMinor, customerTier: profile.tier },
      { correlationId, causationId: event.detail?.eventId }
    )
  );

  metrics.addMetric('OrdersEnriched', MetricUnit.Count, 1);
  metrics.addMetric('DiscountAppliedMinor', MetricUnit.Count, discountMinor);
  logger.info('order enriched', { orderId, tier: profile.tier, payableMinor });

  return { ...order, status: OrderStatus.ENRICHED, correlationId, enrichment };
}

exports.handler = withObservability('enrichOrder', handle);
exports.TransientError = TransientError;
