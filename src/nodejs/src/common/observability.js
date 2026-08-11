'use strict';

/**
 * Shared observability wiring: Powertools Logger / Tracer / Metrics, plus the
 * handler wrapper that applies the cross-cutting concerns uniformly.
 *
 * The correlation id itself is handled by correlation.js, which is kept free of
 * the Powertools dependency; this module binds it to the logger and the X-Ray
 * segment.
 */

const { Logger } = require('@aws-lambda-powertools/logger');
const { Tracer } = require('@aws-lambda-powertools/tracer');
const { Metrics, MetricUnit } = require('@aws-lambda-powertools/metrics');
const { randomUUID } = require('node:crypto');
const { CORRELATION_HEADER, extractCorrelationId } = require('./correlation');

const SERVICE_NAME = process.env.POWERTOOLS_SERVICE_NAME || 'order-platform';
const NAMESPACE = process.env.POWERTOOLS_METRICS_NAMESPACE || 'OrderPlatform';

const logger = new Logger({ serviceName: SERVICE_NAME });
const tracer = new Tracer({ serviceName: SERVICE_NAME });
const metrics = new Metrics({ serviceName: SERVICE_NAME, namespace: NAMESPACE });

/**
 * Bind the correlation id to the logger and the X-Ray segment so that
 * downstream helpers (the event publisher, in particular) can read it without
 * every function threading it through by hand.
 *
 * Annotating rather than adding metadata is deliberate: X-Ray annotations are
 * indexed, so `annotation.correlationId = "..."` is a filterable trace search.
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
 * Wrap a handler with the standard cross-cutting concerns: cold-start
 * annotation, correlation id, structured error logging and metric flushing.
 *
 * Hand-rolled rather than composed from Middy middleware so the control flow is
 * readable end to end -- in a reference codebase that is worth more than the
 * few lines a middleware stack would save.
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
      // Rethrow: the Lambda Errors metric is what the SLO alarms key on, and
      // swallowing the error here would make a broken function look healthy.
      throw err;
    } finally {
      metrics.addMetric('HandlerDurationMs', MetricUnit.Milliseconds, Date.now() - startedAt);
      metrics.publishStoredMetrics();
      if (subsegment) {
        subsegment.close();
        tracer.setSegment(segment);
      }
      // Execution environments are reused; a stale correlation id on the next
      // invocation would be worse than none at all.
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
