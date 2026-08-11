'use strict';

/**
 * Error taxonomy, with zero dependencies on purpose.
 *
 * The class name is load-bearing: Step Functions matches Retry/Catch blocks on
 * `err.name`, so renaming one of these silently changes the state machine's
 * behaviour. Keep them in sync with terraform/stepfunctions.tf.
 */

/** A 4xx: the caller sent something wrong. Never retried. */
class ClientError extends Error {
  constructor(message, statusCode = 400, details = undefined) {
    super(message);
    this.name = 'ClientError';
    this.statusCode = statusCode;
    this.details = details;
  }
}

/** Business rules rejected the order. Terminal -- the input will not improve. */
class ValidationError extends Error {
  constructor(message, violations = []) {
    super(message);
    this.name = 'ValidationError';
    this.violations = violations;
  }
}

/** A dependency was briefly unavailable. Retried with backoff by the workflow. */
class TransientError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TransientError';
  }
}

module.exports = { ClientError, ValidationError, TransientError };
