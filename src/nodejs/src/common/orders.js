'use strict';

/**
 * Order domain model + DynamoDB access.
 *
 * Single-table design:
 *   PK = ORDER#<orderId>            SK = ORDER#<orderId>        (the order item)
 *   GSI1PK = CUSTOMER#<customerId>  GSI1SK = <createdAt>        (orders by customer)
 *
 * Status is a small state machine: PENDING -> VALIDATED -> ENRICHED -> COMPLETED,
 * with FAILED reachable from any state.
 */

const { randomUUID } = require('node:crypto');
const { GetCommand, PutCommand, UpdateCommand, QueryCommand } = require('@aws-sdk/lib-dynamodb');
const { ddb } = require('./clients');
const { ClientError } = require('./http');

const TABLE_NAME = process.env.TABLE_NAME;
const GSI1_NAME = process.env.GSI1_NAME || 'gsi1-customer-index';

const OrderStatus = Object.freeze({
  PENDING: 'PENDING',
  VALIDATED: 'VALIDATED',
  ENRICHED: 'ENRICHED',
  COMPLETED: 'COMPLETED',
  FAILED: 'FAILED',
});

const orderKey = (orderId) => ({ pk: `ORDER#${orderId}`, sk: `ORDER#${orderId}` });

/**
 * Validate an inbound create-order payload. Pure function so it is trivially
 * unit-testable without any AWS mocking.
 */
function validateOrderInput(payload) {
  const errors = [];

  if (!payload || typeof payload !== 'object') {
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
      if (typeof item.unitPrice !== 'number' || item.unitPrice < 0) {
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

/** Total in minor units to avoid float drift on money. */
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
    // 90-day retention on the operational store; the audit trail lives in S3.
    ttl: Math.floor(Date.now() / 1000) + 90 * 24 * 60 * 60,
  };
}

async function putOrder(order) {
  await ddb.send(
    new PutCommand({
      TableName: TABLE_NAME,
      Item: order,
      ConditionExpression: 'attribute_not_exists(pk)',
    })
  );
  return order;
}

async function getOrder(orderId) {
  const { Item } = await ddb.send(new GetCommand({ TableName: TABLE_NAME, Key: orderKey(orderId) }));
  return Item || null;
}

async function listOrdersByCustomer(customerId, limit = 25) {
  const { Items } = await ddb.send(
    new QueryCommand({
      TableName: TABLE_NAME,
      IndexName: GSI1_NAME,
      KeyConditionExpression: 'gsi1pk = :pk',
      ExpressionAttributeValues: { ':pk': `CUSTOMER#${customerId}` },
      ScanIndexForward: false,
      Limit: Math.min(limit, 100),
    })
  );
  return Items || [];
}

/**
 * Advance the order's status. The condition expression makes the write
 * idempotent under Step Functions retries: replaying the same transition is a
 * no-op rather than a corruption.
 */
async function updateOrderStatus(orderId, status, attributes = {}) {
  const names = { '#status': 'status', '#updatedAt': 'updatedAt' };
  const values = { ':status': status, ':updatedAt': new Date().toISOString() };
  const sets = ['#status = :status', '#updatedAt = :updatedAt'];

  Object.entries(attributes).forEach(([key, value], idx) => {
    names[`#a${idx}`] = key;
    values[`:a${idx}`] = value;
    sets.push(`#a${idx} = :a${idx}`);
  });

  const { Attributes } = await ddb.send(
    new UpdateCommand({
      TableName: TABLE_NAME,
      Key: orderKey(orderId),
      UpdateExpression: `SET ${sets.join(', ')}`,
      ExpressionAttributeNames: names,
      ExpressionAttributeValues: values,
      ConditionExpression: 'attribute_exists(pk)',
      ReturnValues: 'ALL_NEW',
    })
  );

  return Attributes;
}

module.exports = {
  OrderStatus,
  TABLE_NAME,
  orderKey,
  validateOrderInput,
  calculateTotalMinor,
  buildOrder,
  putOrder,
  getOrder,
  listOrdersByCustomer,
  updateOrderStatus,
};
