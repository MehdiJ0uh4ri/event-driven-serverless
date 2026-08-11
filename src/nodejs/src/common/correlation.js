'use strict';

/**
 * Correlation-id plumbing. Dependency-free so every layer can use it and so it
 * can be unit-tested without a runtime.
 *
 * One id follows a request through every hop, carried in three places because
 * no single one survives the whole path:
 *   1. the `x-correlation-id` HTTP header       (client -> API Gateway -> Lambda)
 *   2. the `correlationId` field of the event   (Lambda -> EventBridge -> anything)
 *   3. an SQS message attribute                 (EventBridge -> SQS -> consumer)
 */

const { randomUUID } = require('node:crypto');

/** Header name used consistently across the platform. */
const CORRELATION_HEADER = 'x-correlation-id';

/**
 * Pull the correlation id out of whatever event shape we were handed, falling
 * back to a fresh UUID for requests that genuinely originate here.
 *
 * Order matters: the HTTP header wins, because a caller that supplied its own
 * id is trying to join our traces to theirs.
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

module.exports = { CORRELATION_HEADER, extractCorrelationId };
