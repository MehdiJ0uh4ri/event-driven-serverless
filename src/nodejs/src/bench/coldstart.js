'use strict';

/**
 * Cold-start benchmark subject — Node.js 20.
 *
 * Deliberately minimal and dependency-free: the point is to measure the
 * runtime's own init cost, so pulling in Powertools or the SDK here would
 * measure the bundle instead. Module-scope work below is what Lambda bills as
 * `Init Duration` and is what tools/coldstart_benchmark.py reads back out of
 * the REPORT log line.
 */

const INIT_STARTED_AT = Date.now();
const RUNTIME = `nodejs${process.versions.node.split('.')[0]}`;

// A small, representative amount of init work: every real function parses
// config and warms at least one structure.
const CONFIG = Object.freeze({
  region: process.env.AWS_REGION,
  memoryMb: Number(process.env.AWS_LAMBDA_FUNCTION_MEMORY_SIZE || 0),
  version: process.env.AWS_LAMBDA_FUNCTION_VERSION,
  // BENCH_NONCE is bumped by the harness to force a new execution environment.
  nonce: process.env.BENCH_NONCE || 'none',
});

const INIT_DURATION_MS = Date.now() - INIT_STARTED_AT;
let invocationCount = 0;

exports.handler = async (event, context) => {
  invocationCount += 1;
  const isColdStart = invocationCount === 1;

  // Structured single line so the harness can parse either this or the REPORT.
  console.log(
    JSON.stringify({
      level: 'INFO',
      message: 'bench_invocation',
      runtime: RUNTIME,
      coldStart: isColdStart,
      moduleInitMs: INIT_DURATION_MS,
      memoryMb: CONFIG.memoryMb,
      nonce: CONFIG.nonce,
      requestId: context.awsRequestId,
    })
  );

  return {
    runtime: RUNTIME,
    coldStart: isColdStart,
    moduleInitMs: INIT_DURATION_MS,
    memoryMb: CONFIG.memoryMb,
    invocationCount,
    echo: event?.ping ?? null,
  };
};
