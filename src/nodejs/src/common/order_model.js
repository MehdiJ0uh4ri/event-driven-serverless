'use strict';

/**
 * The order domain model: pure functions only.
 *
 * Nothing in here touches AWS, which is the point -- validation and money
 * arithmetic are the parts most worth testing, and they should not require a
 * mocked SDK or a network to exercise. src/common/orders.js layers the
 * DynamoDB access on top.
 *
 * Single-table design:
 *   PK = ORDER#<orderId>            SK = ORDER#<orderId>
 *   GSI1PK = CUSTOMER#<customerId>  GSI1SK = <createdAt>
 */

const { randomUUID } = require('node:crypto');
const { ClientError } = require('./errors');

/** PENDING -> VALIDATED -> ENRICHED -> COMPLETED, with FAILED reachable throughout. */
const OrderStatus = Object.freeze({
  PENDING: 'PENDING',
  VALIDATED: 'VALIDATED',
  ENRICHED: 'ENRICHED',
  COMPLETED: 'COMPLETED',
  FAILED: 'FAILED',
});

const ORDER_TTL_DAYS = 90;

const orderKey = (orderId) => ({ pk: `ORDER#${orderId}`, sk: `ORDER#${orderId}` });

/**
 * Validate an inbound create-order payload.
 *
 * Collects every violation rather than throwing on the first: a caller fixing
 * a form should not have to make four round trips to discover four problems.
 */
function validateOrderInput(payload) {
  const errors = [];

  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    throw new ClientError('Payload must be a JSON object');
  }
  if (!payload.customerId || typeof payload.customerId !== 'string') {
    errors.push('customerId is required and must be a string');
  }
  if (!Array.isArray(payload.items) || payload.items.length === 0) {
    errors.push('items must be a non-empty array');
  } else {
    payload.items.forEach((item, idx) => {
      if (!item || typeof item !== 'object') {
        errors.push(`items[${idx}] must be an object`);
        return;
      }
      if (!item.sku || typeof item.sku !== 'string') errors.push(`items[${idx}].sku is required`);
      if (!Number.isInteger(item.quantity) || item.quantity < 1) {
        errors.push(`items[${idx}].quantity must be a positive integer`);
      }
      if (typeof item.unitPrice !== 'number' || item.unitPrice < 0 || !Number.isFinite(item.unitPrice)) {
        errors.push(`items[${idx}].unitPrice must be a non-negative number`);
      }
    });
  }
  if (payload.currency && !/^[A-Z]{3}$/.test(payload.currency)) {
    errors.push('currency must be a 3-letter ISO-4217 code');
  }

  if (errors.length > 0) {
    throw new ClientError('Order payload failed validation', 422, errors);
  }

  // Whitelist the fields we persist: an unknown field in the request must not
  // find its way into the database.
  return {
    customerId: payload.customerId,
    items: payload.items.map((i) => ({
      sku: i.sku,
      quantity: i.quantity,
      unitPrice: i.unitPrice,
    })),
    currency: payload.currency || 'EUR',
    metadata: payload.metadata && typeof payload.metadata === 'object' ? payload.metadata : {},
  };
}

/**
 * Total in minor units (cents). Money is never held as a float: rounding each
 * unit price to minor units *before* multiplying is what keeps 0.1 + 0.2 at
 * exactly 30 rather than 30.000000000000004.
 */
function calculateTotalMinor(items) {
  return items.reduce((sum, i) => sum + Math.round(i.unitPrice * 100) * i.quantity, 0);
}

function buildOrder(input, correlationId) {
  const orderId = randomUUID();
  const now = new Date().toISOString();
  const totalMinor = calculateTotalMinor(input.items);

  return {
    ...orderKey(orderId),
    gsi1pk: `CUSTOMER#${input.customerId}`,
    gsi1sk: now,
    entityType: 'Order',
    orderId,
    customerId: input.customerId,
    items: input.items,
    currency: input.currency,
    totalMinor,
    total: totalMinor / 100,
    status: OrderStatus.PENDING,
    metadata: input.metadata,
    correlationId,
    createdAt: now,
    updatedAt: now,
    // The operational store keeps 90 days; the audit table is the long record.
    ttl: Math.floor(Date.now() / 1000) + ORDER_TTL_DAYS * 24 * 60 * 60,
  };
}

/** Strip internal single-table keys before handing an item to a caller. */
function toPublicOrder(item) {
  if (!item) return item;
  const { pk, sk, gsi1pk, gsi1sk, entityType, ttl, ...rest } = item;
  return rest;
}

module.exports = {
  OrderStatus,
  ORDER_TTL_DAYS,
  orderKey,
  validateOrderInput,
  calculateTotalMinor,
  buildOrder,
  toPublicOrder,
};
