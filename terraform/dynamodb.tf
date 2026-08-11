/**
 * Data stores.
 *
 * Two tables rather than one: the operational order table is read/written on
 * the hot path and has a 90-day TTL, while the audit table is append-only with
 * a 1-year TTL and a very different access pattern. Splitting them keeps the
 * IAM grants honest -- the API role cannot touch audit history at all.
 */

resource "aws_dynamodb_table" "orders" {
  name         = "${local.name_prefix}-orders"
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "pk"
  range_key    = "sk"

  # Only key and index attributes are declared; DynamoDB is schemaless for the rest.
  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }
  attribute {
    name = "gsi1pk"
    type = "S"
  }
  attribute {
    name = "gsi1sk"
    type = "S"
  }

  global_secondary_index {
    name            = "gsi1-customer-index"
    hash_key        = "gsi1pk"
    range_key       = "gsi1sk"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = local.is_prod
  }

  server_side_encryption {
    enabled = true
  }

  # Streams are enabled so a future consumer (search projection, CDC) can be
  # added without a table replacement.
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  deletion_protection_enabled = local.is_prod

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-orders" })
}

resource "aws_dynamodb_table" "audit" {
  name         = "${local.name_prefix}-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }
  attribute {
    name = "correlationId"
    type = "S"
  }

  # Lets an operator pull the entire causal chain of a request by correlation id
  # -- the single most useful query during an incident.
  global_secondary_index {
    name            = "correlation-index"
    hash_key        = "correlationId"
    range_key       = "sk"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = local.is_prod
  }

  server_side_encryption {
    enabled = true
  }

  deletion_protection_enabled = local.is_prod

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-audit" })
}
