'use strict';

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

// http.js and errors.js are dependency-free by design, so this file runs
// without npm install. extractCorrelationId is re-tested here against the
// shapes every entry point actually receives.
const { ok, created, notFound, errorResponse, parseJsonBody } = require('../src/common/http');
const { ClientError } = require('../src/common/errors');
const { extractCorrelationId, CORRELATION_HEADER } = require('../src/common/correlation');

describe('parseJsonBody', () => {
  test('parses a plain JSON body', () => {
    assert.deepEqual(parseJsonBody({ body: '{"a":1}' }), { a: 1 });
  });

  test('decodes a base64-encoded body', () => {
    const event = { body: Buffer.from('{"a":2}').toString('base64'), isBase64Encoded: true };
    assert.deepEqual(parseJsonBody(event), { a: 2 });
  });

  test('rejects a missing body', () => {
    assert.throws(() => parseJsonBody({}), { name: 'ClientError' });
  });

  test('rejects invalid JSON with a 400, not a crash', () => {
    assert.throws(() => parseJsonBody({ body: '{oops' }), (err) => {
      assert.equal(err.statusCode, 400);
      return true;
    });
  });
});

describe('responses', () => {
  test('ok returns 200 with the correlation header', () => {
    const response = ok({ hello: 'world' }, 'corr-1');
    assert.equal(response.statusCode, 200);
    assert.equal(response.headers[CORRELATION_HEADER], 'corr-1');
    assert.equal(response.headers['content-type'], 'application/json');
    assert.deepEqual(JSON.parse(response.body), { hello: 'world' });
  });

  test('created returns 201 and a location header', () => {
    const response = created({ orderId: 'o-1' }, 'corr-1', '/orders/o-1');
    assert.equal(response.statusCode, 201);
    assert.equal(response.headers.location, '/orders/o-1');
  });

  test('notFound returns a structured 404', () => {
    const response = notFound('Order o-9 not found', 'corr-1');
    assert.equal(response.statusCode, 404);
    assert.equal(JSON.parse(response.body).error, 'not_found');
  });

  test('errorResponse surfaces ClientError detail to the caller', () => {
    const response = errorResponse(new ClientError('bad input', 422, ['field x']), 'corr-1');
    const body = JSON.parse(response.body);
    assert.equal(response.statusCode, 422);
    assert.deepEqual(body.details, ['field x']);
  });

  test('errorResponse hides internal errors behind a generic 500', () => {
    const response = errorResponse(new Error('DynamoDB credentials are wrong'), 'corr-1');
    const body = JSON.parse(response.body);
    assert.equal(response.statusCode, 500);
    assert.equal(body.message, 'Unexpected error');
    assert.ok(!response.body.includes('credentials'), 'internal detail must not leak');
    // The caller still gets a handle they can quote to support.
    assert.equal(body.correlationId, 'corr-1');
  });
});

describe('extractCorrelationId', () => {
  test('reads the header case-insensitively', () => {
    assert.equal(extractCorrelationId({ headers: { 'X-Correlation-ID': 'abc' } }), 'abc');
    assert.equal(extractCorrelationId({ headers: { 'x-correlation-id': 'def' } }), 'def');
  });

  test('reads it from an EventBridge detail', () => {
    assert.equal(extractCorrelationId({ detail: { correlationId: 'from-event' } }), 'from-event');
  });

  test('reads it from an SQS message attribute', () => {
    const event = {
      Records: [{ messageAttributes: { correlationId: { stringValue: 'from-sqs' } } }],
    };
    assert.equal(extractCorrelationId(event), 'from-sqs');
  });

  test('generates a UUID when no id is present', () => {
    assert.match(extractCorrelationId({}), /^[0-9a-f-]{36}$/);
  });

  test('generates a distinct id per call when absent', () => {
    assert.notEqual(extractCorrelationId({}), extractCorrelationId({}));
  });
});
