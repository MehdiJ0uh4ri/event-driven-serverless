'use strict';

/**
 * Domain event envelope + publisher.
 *
 * Every event on the bus shares one envelope so that EventBridge rules can be
 * written against stable fields and consumers can rely on a schema:
 *
 *   {
 *     eventId, eventType, eventVersion, occurredAt,
 *     correlationId, causationId, source, data: { ... }
 *   }
 */

const { randomUUID } = require('node:crypto');
const { PutEventsCommand } = require('@aws-sdk/client-eventbridge');
const { eventBridge } = require('./clients');
const { logger, metrics, MetricUnit, currentCorrelationId } = require('./observability');

const EVENT_BUS_NAME = process.env.EVENT_BUS_NAME;
const EVENT_SOURCE = process.env.EVENT_SOURCE || 'order.platform';
const EVENT_VERSION = '1.0';

/** Event types the platform publishes. Kept here so producers cannot typo one. */
const EventType = Object.freeze({
  ORDER_CREATED: 'order.created',
  ORDER_VALIDATED: 'order.validated',
  ORDER_ENRICHED: 'order.enriched',
  ORDER_COMPLETED: 'order.completed',
  ORDER_FAILED: 'order.failed',
});

function buildEnvelope(eventType, data, { correlationId, causationId } = {}) {
  return {
    eventId: randomUUID(),
    eventType,
    eventVersion: EVENT_VERSION,
    occurredAt: new Date().toISOString(),
    correlationId: correlationId || currentCorrelationId(),
    causationId: causationId || null,
    source: EVENT_SOURCE,
    data,
  };
}

/**
 * Publish one or more domain events. EventBridge accepts at most 10 entries per
 * call, so batches are chunked. Partial failures are surfaced loudly: silently
 * dropping an event is the failure mode that costs the most to debug later.
 */
async function publish(events) {
  const list = Array.isArray(events) ? events : [events];
  if (list.length === 0) return { published: 0, failed: 0 };

  let published = 0;
  let failed = 0;

  for (let i = 0; i < list.length; i += 10) {
    const chunk = list.slice(i, i + 10);
    const response = await eventBridge.send(
      new PutEventsCommand({
        Entries: chunk.map((evt) => ({
          EventBusName: EVENT_BUS_NAME,
          Source: evt.source,
          DetailType: evt.eventType,
          Detail: JSON.stringify(evt),
          // Trace header lets X-Ray stitch the producer to the consumer.
          TraceHeader: process.env._X_AMZN_TRACE_ID,
        })),
      })
    );

    published += chunk.length - (response.FailedEntryCount || 0);
    failed += response.FailedEntryCount || 0;

    if (response.FailedEntryCount > 0) {
      const rejected = (response.Entries || [])
        .map((entry, idx) => ({ entry, evt: chunk[idx] }))
        .filter(({ entry }) => entry.ErrorCode);

      for (const { entry, evt } of rejected) {
        logger.error('event rejected by EventBridge', {
          eventId: evt.eventId,
          eventType: evt.eventType,
          errorCode: entry.ErrorCode,
          errorMessage: entry.ErrorMessage,
        });
      }
    }
  }

  metrics.addMetric('EventsPublished', MetricUnit.Count, published);
  if (failed > 0) metrics.addMetric('EventsRejected', MetricUnit.Count, failed);

  if (failed > 0) {
    throw new Error(`EventBridge rejected ${failed}/${list.length} entries`);
  }

  logger.info('events published', { count: published, bus: EVENT_BUS_NAME });
  return { published, failed };
}

module.exports = { EventType, EVENT_SOURCE, buildEnvelope, publish };
