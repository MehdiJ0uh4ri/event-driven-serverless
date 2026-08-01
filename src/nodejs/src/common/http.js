'use strict';

/** HTTP response helpers for API Gateway (HTTP API / payload format 2.0). */

const { CORRELATION_HEADER } = require('./observability');

/** Errors thrown with this class produce a 4xx instead of a 500. */
class ClientError extends Error {
  constructor(message, statusCode = 400, details = undefined) {
    super(message);
    this.name = 'ClientError';
    this.statusCode = statusCode;
    this.details = details;
  }
}

function respond(statusCode, body, correlationId, extraHeaders = {}) {
  return {
    statusCode,
    headers: {
      'content-type': 'application/json',
      [CORRELATION_HEADER]: correlationId,
      'cache-control': 'no-store',
      ...extraHeaders,
    },
    body: JSON.stringify(body),
  };
}

const ok = (body, cid) => respond(200, body, cid);
const created = (body, cid, location) =>
  respond(201, body, cid, location ? { location } : {});
const notFound = (message, cid) => respond(404, { error: 'not_found', message }, cid);

function errorResponse(err, correlationId) {
  if (err instanceof ClientError) {
    return respond(
      err.statusCode,
      { error: 'bad_request', message: err.message, details: err.details, correlationId },
      correlationId
    );
  }
  // Never leak internals to the caller; the correlation id is the handle they
  // quote to support, and it is already in the logs.
  return respond(
    500,
    { error: 'internal_error', message: 'Unexpected error', correlationId },
    correlationId
  );
}

function parseJsonBody(event) {
  if (!event.body) throw new ClientError('Request body is required');
  const raw = event.isBase64Encoded
    ? Buffer.from(event.body, 'base64').toString('utf8')
    : event.body;
  try {
    return JSON.parse(raw);
  } catch {
    throw new ClientError('Request body must be valid JSON');
  }
}

module.exports = { ClientError, respond, ok, created, notFound, errorResponse, parseJsonBody };
