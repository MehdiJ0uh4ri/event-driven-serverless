'use strict';

/**
 * Unit tests for the pure domain logic. No AWS mocking: everything tested here
 * is a function of its inputs, which is exactly why validation and money maths
 * were kept out of the handlers.
 *
 * Run: node --test tests/
 */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

// Imported from order_model, not orders: the pure model has no AWS SDK
// dependency, so these tests run with nothing installed.
const {
  validateOrderInput,
  calculateTotalMinor,
  buildOrder,
  toPublicOrder,
  OrderStatus,
} = require('../src/common/order_model');

const validPayload = () => ({
  customerId: 'cust-123',
  items: [
    { sku: 'WIDGET-1', quantity: 2, unitPrice: 19.99 },
    { sku: 'GIZMO-2', quantity: 1, unitPrice: 5.0 },
  ],
  currency: 'EUR',
});

describe('validateOrderInput', () => {
  test('accepts a well-formed order', () => {
    const result = validateOrderInput(validPayload());
    assert.equal(result.customerId, 'cust-123');
    assert.equal(result.items.length, 2);
    assert.equal(result.currency, 'EUR');
  });

  test('defaults the currency to EUR when omitted', () => {
    const payload = validPayload();
    delete payload.currency;
    assert.equal(validateOrderInput(payload).currency, 'EUR');
  });

  test('strips unknown fields from items', () => {
    const payload = validPayload();
    payload.items[0].internalNote = 'should not survive';
    const result = validateOrderInput(payload);
    assert.equal(result.items[0].internalNote, undefined);
  });

  test('rejects a missing customerId', () => {
    const payload = validPayload();
    delete payload.customerId;
    assert.throws(() => validateOrderInput(payload), (err) => {
      assert.equal(err.name, 'ClientError');
      assert.equal(err.statusCode, 422);
      assert.ok(err.details.some((d) => d.includes('customerId')));
      return true;
    });
  });

  test('rejects an empty item list', () => {
    assert.throws(
      () => validateOrderInput({ customerId: 'c', items: [] }),
      (err) => err.details.some((d) => d.includes('non-empty'))
    );
  });

  test('rejects a non-integer quantity', () => {
    const payload = validPayload();
    payload.items[0].quantity = 1.5;
    assert.throws(
      () => validateOrderInput(payload),
      (err) => err.details.some((d) => d.includes('positive integer'))
    );
  });

  test('rejects a negative price', () => {
    const payload = validPayload();
    payload.items[1].unitPrice = -1;
    assert.throws(
      () => validateOrderInput(payload),
      (err) => err.details.some((d) => d.includes('non-negative'))
    );
  });

  test('rejects a malformed currency code', () => {
    const payload = validPayload();
    payload.currency = 'euro';
    assert.throws(
      () => validateOrderInput(payload),
      (err) => err.details.some((d) => d.includes('ISO-4217'))
    );
  });

  test('reports every violation at once rather than the first', () => {
    assert.throws(
      () => validateOrderInput({ items: [{ sku: '', quantity: 0, unitPrice: -5 }] }),
      (err) => {
        assert.ok(err.details.length >= 4, `expected several violations, got ${err.details.length}`);
        return true;
      }
    );
  });

  test('rejects a non-object payload', () => {
    assert.throws(() => validateOrderInput('not an object'), { name: 'ClientError' });
    assert.throws(() => validateOrderInput(null), { name: 'ClientError' });
  });
});

describe('calculateTotalMinor', () => {
  test('sums line items in minor units', () => {
    assert.equal(calculateTotalMinor([{ quantity: 2, unitPrice: 19.99 }]), 3998);
  });

  test('avoids float drift on prices that cannot be represented exactly', () => {
    // 0.1 + 0.2 !== 0.3 in float; in minor units it is exactly 30.
    const total = calculateTotalMinor([
      { quantity: 1, unitPrice: 0.1 },
      { quantity: 1, unitPrice: 0.2 },
    ]);
    assert.equal(total, 30);
  });

  test('handles a large basket without precision loss', () => {
    const items = Array.from({ length: 100 }, () => ({ quantity: 3, unitPrice: 9.99 }));
    assert.equal(calculateTotalMinor(items), 299700);
  });

  test('returns zero for an empty basket', () => {
    assert.equal(calculateTotalMinor([]), 0);
  });
});

describe('buildOrder', () => {
  test('produces a complete, keyed item', () => {
    const order = buildOrder(validateOrderInput(validPayload()), 'corr-1');

    assert.match(order.orderId, /^[0-9a-f-]{36}$/);
    assert.equal(order.pk, `ORDER#${order.orderId}`);
    assert.equal(order.sk, `ORDER#${order.orderId}`);
    assert.equal(order.gsi1pk, 'CUSTOMER#cust-123');
    assert.equal(order.gsi1sk, order.createdAt);
    assert.equal(order.status, OrderStatus.PENDING);
    assert.equal(order.correlationId, 'corr-1');
    assert.equal(order.totalMinor, 4498);
    assert.equal(order.total, 44.98);
  });

  test('sets a TTL roughly 90 days out', () => {
    const order = buildOrder(validateOrderInput(validPayload()), 'corr-1');
    const days = (order.ttl - Date.now() / 1000) / 86400;
    assert.ok(days > 89 && days < 91, `expected ~90 days, got ${days.toFixed(1)}`);
  });

  test('generates a distinct id per call', () => {
    const input = validateOrderInput(validPayload());
    assert.notEqual(buildOrder(input, 'c').orderId, buildOrder(input, 'c').orderId);
  });
});

describe('toPublicOrder', () => {
  test('removes the single-table keys', () => {
    const order = buildOrder(validateOrderInput(validPayload()), 'corr-1');
    const publicView = toPublicOrder(order);

    for (const key of ['pk', 'sk', 'gsi1pk', 'gsi1sk', 'entityType', 'ttl']) {
      assert.equal(publicView[key], undefined, `${key} must not be exposed`);
    }
    assert.equal(publicView.orderId, order.orderId);
    assert.equal(publicView.total, order.total);
  });

  test('passes null and undefined through unchanged', () => {
    assert.equal(toPublicOrder(null), null);
    assert.equal(toPublicOrder(undefined), undefined);
  });
});
