'use strict';

/**
 * Shared observability wiring: Powertools Logger / Tracer / Metrics plus the
 * correlation-id plumbing that lets a single request be followed from
 * API Gateway -> Lambda -> EventBridge -> Step Functions -> SQS.
 *
 * The correlation id is carried in three places so no hop loses it:
 *   1. the `x-correlation-id` HTTP header (inbound + outbound)
 *   2. the `correlationId` field of every domain event envelope
 *   3. a Powertools persistent log attribute, so every log line has it
 */

const { Logger } = require('@aws-lambda-powertools/logger');
const { Tracer } = require('@aws-lambda-powertools/tracer');
const { Metrics, MetricUnit } = require('@aws-lambda-powertools/metrics');
const { randomUUID } = require('node:crypto');

const SERVICE_NAME = process.env.POWERTOOLS_SERVICE_NAME || 'order-platform';
const NAMESPACE = process.env.POWERTOOLS_METRICS_NAMESPACE || 'OrderPlatform';

const logger = new Logger({ serviceName: SERVICE_NAME });
const tracer = new Tracer({ serviceName: SERVICE_NAME });
const metrics = new Metrics({ serviceName: SERVICE_NAME, namespace: NAMESPACE });

/** Header name used consistently across the platform. */
const CORRELATION_HEADER = 'x-correlation-id';

/**
 * Pull a correlation id out of whatever shape of event we were handed,
 * falling back to a fresh UUID for requests that originate here.
 */
function extractCorrelationId(event = {}) {
  const headers = event.headers || {};
  const lowered = {};
  for (const [k, v] of Object.entries(headers)) lowered[k.toLowerCase()] = v;

  return (
    lowered[CORRELATION_HEADER] ||
    event.correlationId ||
    event?.detail?.correlationId ||
    event?.Records?.[0]?.messageAttributes?.correlationId?.stringValue ||
    randomUUID()
  );
}

/**
 * Bind the correlation id to the logger, the X-Ray segment and the process so
 * that downstream helpers (event publisher, DynamoDB writer) can read it
 * without every function threading it through by hand.
 */
function bindCorrelationId(correlationId) {
  logger.appendKeys({ correlationId });
  tracer.putAnnotation('correlationId', correlationId);
  process.env._CURRENT_CORRELATION_ID = correlationId;
  return correlationId;
}

function currentCorrelationId() {
  return process.env._CURRENT_CORRELATION_ID || randomUUID();
}

/**
 * Wrap a handler with the standard cross-cutting concerns:
 * cold-start annotation, correlation id, structured error logging and
 * metric flushing. Deliberately hand-rolled rather than using Middy so the
 * control flow stays readable in a teaching/reference codebase.
 */
function withObservability(handlerName, handler) {
  return async function wrapped(event, context) {
    const correlationId = bindCorrelationId(extractCorrelationId(event));
    logger.addContext(context);

    const segment = tracer.getSegment();
    let subsegment;
    if (segment) {
      subsegment = segment.addNewSubsegment(`## ${handlerName}`);
      tracer.setSegment(subsegment);
      tracer.annotateColdStart();
      tracer.addServiceNameAnnotation();
    }

    metrics.addDimension('handler', handlerName);

    const startedAt = Date.now();
    try {
      const result = await handler(event, context, { correlationId, logger, tracer, metrics });
      metrics.addMetric('HandlerSuccess', MetricUnit.Count, 1);
      return result;
    } catch (err) {
      metrics.addMetric('HandlerError', MetricUnit.Count, 1);
      tracer.addErrorAsMetadata(err);
      logger.error('handler failed', {
        handler: handlerName,
        errorName: err.name,
        errorMessage: err.message,
        stack: err.stack,
      });
      throw err;
    } finally {
      metrics.addMetric('HandlerDurationMs', MetricUnit.Milliseconds, Date.now() - startedAt);
      metrics.publishStoredMetrics();
      if (subsegment) {
        subsegment.close();
        tracer.setSegment(segment);
      }
      logger.removeKeys(['correlationId']);
    }
  };
}

module.exports = {
  logger,
  tracer,
  metrics,
  MetricUnit,
  CORRELATION_HEADER,
  extractCorrelationId,
  bindCorrelationId,
  currentCorrelationId,
  withObservability,
};
