'use strict';

/**
 * DynamoDB access for orders.
 *
 * The pure domain model (validation, money, item shape) lives in
 * order_model.js and is re-exported here so callers have one import.
 */

const { GetCommand, PutCommand, UpdateCommand, QueryCommand } = require('@aws-sdk/lib-dynamodb');
const { ddb } = require('./clients');
const model = require('./order_model');

const TABLE_NAME = process.env.TABLE_NAME;
const GSI1_NAME = process.env.GSI1_NAME || 'gsi1-customer-index';

const { orderKey } = model;

async function putOrder(order) {
  await ddb.send(
    new PutCommand({
      TableName: TABLE_NAME,
      Item: order,
      // Refuse to overwrite: a duplicate orderId is a bug, not an update.
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
      ScanIndexForward: false, // newest first
      Limit: Math.min(limit, 100),
    })
  );
  return Items || [];
}

/**
 * Advance the order's status.
 *
 * `attribute_exists(pk)` makes the write safe under Step Functions retries: a
 * replayed transition updates the same item rather than resurrecting an order
 * that was deleted or never created.
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
  ...model,
  TABLE_NAME,
  GSI1_NAME,
  putOrder,
  getOrder,
  listOrdersByCustomer,
  updateOrderStatus,
};
