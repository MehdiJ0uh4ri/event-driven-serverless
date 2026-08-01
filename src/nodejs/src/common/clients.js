'use strict';

/**
 * AWS SDK clients are created once per execution environment (module scope) so
 * that the TLS handshake and credential resolution are paid on the cold start
 * only. Every client is captured by X-Ray so downstream calls appear on the
 * service map.
 */

const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient } = require('@aws-sdk/lib-dynamodb');
const { EventBridgeClient } = require('@aws-sdk/client-eventbridge');
const { SNSClient } = require('@aws-sdk/client-sns');
const { tracer } = require('./observability');

const REGION = process.env.AWS_REGION || 'us-east-1';

// Keep-alive is on by default in Node 18+ SDK v3, but pin the socket settings
// so behaviour does not drift between runtimes.
const baseConfig = {
  region: REGION,
  maxAttempts: 3,
};

const ddbClient = tracer.captureAWSv3Client(new DynamoDBClient(baseConfig));

const ddb = DynamoDBDocumentClient.from(ddbClient, {
  marshallOptions: { removeUndefinedValues: true, convertClassInstanceToMap: true },
});

const eventBridge = tracer.captureAWSv3Client(new EventBridgeClient(baseConfig));
const sns = tracer.captureAWSv3Client(new SNSClient(baseConfig));

module.exports = { ddb, eventBridge, sns, REGION };
