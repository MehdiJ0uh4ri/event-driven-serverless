/**
 * HTTP API (API Gateway v2).
 *
 * v2 rather than REST: ~70% cheaper per million requests, lower latency, and
 * we need none of the REST-only features (no request validation models here --
 * validation is business logic and lives in the function).
 */

resource "aws_apigatewayv2_api" "orders" {
  name          = "${local.name_prefix}-api"
  description   = "Order platform public API"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins  = local.is_prod ? ["https://orders.example.com"] : ["*"]
    allow_methods  = ["GET", "POST", "OPTIONS"]
    allow_headers  = ["content-type", "authorization", "x-correlation-id"]
    expose_headers = ["x-correlation-id"]
    max_age        = 300
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name_prefix}-api"
  retention_in_days = local.log_retention_days
  tags              = local.common_tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.orders.id
  name        = "$default"
  auto_deploy = true

  # Structured access logs. The correlation id is captured from the request
  # header (or the response, when the API generated it) so an entry in this log
  # can be joined to the Lambda logs and the X-Ray trace.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      correlationId      = "$context.requestHeaderOverride.header.x-correlation-id"
      extendedRequestId  = "$context.extendedRequestId"
      ip                 = "$context.identity.sourceIp"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      routeKey           = "$context.routeKey"
      path               = "$context.path"
      status             = "$context.status"
      protocol           = "$context.protocol"
      responseLength     = "$context.responseLength"
      responseLatency    = "$context.responseLatency"
      integrationLatency = "$context.integrationLatency"
      integrationStatus  = "$context.integrationStatus"
      integrationError   = "$context.integrationErrorMessage"
      xrayTraceId        = "$context.xrayTraceId"
    })
  }

  default_route_settings {
    detailed_metrics_enabled = true
    # The single most effective cost control on the whole stack: a runaway
    # client cannot generate unbounded Lambda invocations.
    throttling_rate_limit  = var.api_throttle_rate_limit
    throttling_burst_limit = var.api_throttle_burst_limit
  }

  tags = local.common_tags

  depends_on = [aws_cloudwatch_log_group.api_access]
}

# ---------------------------------------------------------------------------
# Integrations
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_integration" "create_order" {
  api_id                 = aws_apigatewayv2_api.orders.id
  integration_type       = "AWS_PROXY"
  integration_uri        = module.fn_create_order.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

resource "aws_apigatewayv2_integration" "get_order" {
  api_id                 = aws_apigatewayv2_api.orders.id
  integration_type       = "AWS_PROXY"
  integration_uri        = module.fn_get_order.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_route" "create_order" {
  api_id    = aws_apigatewayv2_api.orders.id
  route_key = "POST /orders"
  target    = "integrations/${aws_apigatewayv2_integration.create_order.id}"
}

resource "aws_apigatewayv2_route" "get_order" {
  api_id    = aws_apigatewayv2_api.orders.id
  route_key = "GET /orders/{orderId}"
  target    = "integrations/${aws_apigatewayv2_integration.get_order.id}"
}

resource "aws_apigatewayv2_route" "list_orders" {
  api_id    = aws_apigatewayv2_api.orders.id
  route_key = "GET /orders"
  target    = "integrations/${aws_apigatewayv2_integration.get_order.id}"
}

# ---------------------------------------------------------------------------
# Invoke permissions -- scoped to the exact route, not the whole API.
# ---------------------------------------------------------------------------
resource "aws_lambda_permission" "create_order" {
  statement_id  = "AllowAPIGatewayInvokeCreateOrder"
  action        = "lambda:InvokeFunction"
  function_name = module.fn_create_order.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.orders.execution_arn}/*/POST/orders"
}

resource "aws_lambda_permission" "get_order" {
  statement_id  = "AllowAPIGatewayInvokeGetOrder"
  action        = "lambda:InvokeFunction"
  function_name = module.fn_get_order.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.orders.execution_arn}/*/GET/orders*"
}
