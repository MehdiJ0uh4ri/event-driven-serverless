'use strict';

/**
 * Tests for the pure helpers inside the async handlers.
 *
 * These require the Powertools/AWS SDK dependencies (the handler modules import
 * them at load time), so run `npm ci` first. `node --test tests/` skips nothing
 * silently -- if these fail to import, the suite fails loudly, which is the
 * behaviour you want in CI.
 */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

// Handler modules read configuration at import time.
process.env.TABLE_NAME = 'test-table';
process.env.EVENT_BUS_NAME = 'test-bus';
process.env.AWS_REGION = 'eu-west-1';
process.env.NOTIFICATION_TOPIC_ARN = 'arn:aws:sns:eu-west-1:000000000000:test';

const { classify } = require('../src/events/dlq_processor');
const { parseCause } = require('../src/workflow/handle_failure');

describe('dlq_processor.classify', () => {
  test('flags a null or non-object body as malformed', () => {
    assert.equal(classify(null), 'MALFORMED_PAYLOAD');
    assert.equal(classify('a string'), 'MALFORMED_PAYLOAD');
    assert.equal(classify(42), 'MALFORMED_PAYLOAD');
  });

  test('flags a missing event type', () => {
    assert.equal(classify({ detail: { data: { orderId: '1' } } }), 'MISSING_EVENT_TYPE');
  });

  test('flags a missing order id', () => {
    assert.equal(classify({ detail: { eventType: 'order.created', data: {} } }), 'MISSING_ORDER_ID');
  });

  test('treats a well-formed event as a downstream failure', () => {
    assert.equal(
      classify({ detail: { eventType: 'order.created', data: { orderId: 'o-1' } } }),
      'DOWNSTREAM_FAILURE'
    );
  });

  test('accepts an envelope at the top level as well as under detail', () => {
    assert.equal(
      classify({ eventType: 'order.created', data: { orderId: 'o-1' } }),
      'DOWNSTREAM_FAILURE'
    );
  });
});

describe('handle_failure.parseCause', () => {
  test('extracts the error type and message from a Lambda cause', () => {
    const cause = JSON.stringify({
      errorType: 'ValidationError',
      errorMessage: 'Order o-1 failed validation',
      trace: ['1', '2', '3', '4', '5', '6'],
    });
    const parsed = parseCause(cause);
    assert.equal(parsed.errorType, 'ValidationError');
    assert.equal(parsed.errorMessage, 'Order o-1 failed validation');
    assert.equal(parsed.trace.length, 5, 'trace is truncated to 5 frames to bound the log line');
  });

  test('falls back to the raw string when the cause is not JSON', () => {
    // States.Timeout and other service-level errors are bare strings.
    assert.equal(parseCause('States.Timeout').errorMessage, 'States.Timeout');
  });

  test('returns an empty object for a missing cause', () => {
    assert.deepEqual(parseCause(undefined), {});
    assert.deepEqual(parseCause(null), {});
    assert.deepEqual(parseCause(''), {});
  });

  test('truncates an oversized non-JSON cause', () => {
    assert.equal(parseCause('x'.repeat(5000)).errorMessage.length, 1024);
  });
});
