'use strict';

/**
 * Step Functions task 3/3: notify.
 *
 * Publishes the customer-facing notification to SNS and closes the order out.
 * Idempotent: re-running it re-sends a notification with the same
 * deduplication key, and the DynamoDB update is a fixed-value SET.
 */

const { PublishCommand } = require('@aws-sdk/client-sns');
const { withObservability, logger, metrics, MetricUnit } = require('../common/observability');
const { sns } = require('../common/clients');
const { OrderStatus, updateOrderStatus } = require('../common/orders');
const { EventType, buildEnvelope, publish } = require('../common/events');
const { TransientError } = require('../common/errors');

const TOPIC_ARN = process.env.NOTIFICATION_TOPIC_ARN;

function renderMessage(order) {
  const e = order.enrichment || {};
  const payable = ((e.payableMinor ?? order.totalMinor) / 100).toFixed(2);
  return {
    subject: `Order ${order.orderId} confirmed`,
    body: [
      `Your order ${order.orderId} is confirmed.`,
      `Items: ${(order.items || []).length}`,
      `Total: ${payable} ${order.currency || 'EUR'}`,
      e.shipping ? `Shipping: ${e.shipping.carrier}, ETA ${e.shipping.etaDays} day(s)` : null,
      e.customerTier ? `Tier: ${e.customerTier}` : null,
    ]
      .filter(Boolean)
      .join('\n'),
  };
}

async function handle(event, _context, { correlationId }) {
  const order = event.detail?.data || event.data || event;
  const { orderId, customerId } = order;

  const message = renderMessage(order);

  try {
    await sns.send(
      new PublishCommand({
        TopicArn: TOPIC_ARN,
        Subject: message.subject.slice(0, 100),
        Message: JSON.stringify({ ...message, orderId, customerId, correlationId }),
        MessageAttributes: {
          orderId: { DataType: 'String', StringValue: orderId },
          correlationId: { DataType: 'String', StringValue: correlationId },
          eventType: { DataType: 'String', StringValue: 'order.notification' },
        },
      })
    );
  } catch (err) {
    // SNS throttling and 5xx are worth another attempt; anything else is not.
    if (err.$metadata?.httpStatusCode >= 500 || err.name === 'ThrottlingException') {
      throw new TransientError(`SNS publish failed transiently: ${err.message}`);
    }
    throw err;
  }

  const completedAt = new Date().toISOString();
  await updateOrderStatus(orderId, OrderStatus.COMPLETED, { completedAt, notified: true });

  await publish(
    buildEnvelope(
      EventType.ORDER_COMPLETED,
      {
        orderId,
        customerId,
        payableMinor: order.enrichment?.payableMinor ?? order.totalMinor,
        completedAt,
      },
      { correlationId, causationId: event.detail?.eventId }
    )
  );

  metrics.addMetric('OrdersCompleted', MetricUnit.Count, 1);
  metrics.addMetric('NotificationsSent', MetricUnit.Count, 1);
  logger.info('order completed', { orderId, customerId });

  return { ...order, status: OrderStatus.COMPLETED, correlationId, completedAt, notified: true };
}

exports.handler = withObservability('notifyCustomer', handle);
exports.TransientError = TransientError;
