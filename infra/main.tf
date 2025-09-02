// Configuration and Provider Blocks

terraform {

  backend "remote" {
    organization = "Who-Stream-It"
    workspaces {
      name = "dev"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}




// Locals Block

locals {
  bucket_name = "${var.project}-site-${random_id.rand.hex}"
  lambda_name = "${var.project}-lambda"
  # Load raw HTML template and replace placeholder with API URL
  raw_index      = file("${path.module}/web/index.html.tftpl")
  # Replace the placeholder ($${function_url}) with the real API URL
  rendered_index = replace(local.raw_index, "@@FUNCTION_URL@@", aws_apigatewayv2_api.http.api_endpoint)
  static_files = fileset("${path.module}/web", "**")
}




// Data Block

data "aws_iam_policy_document" "public_read" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Package watch Lambda with core.js
data "archive_file" "lambda_watch_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/build/watch.zip"
}

# Package search Lambda with core.js
data "archive_file" "lambda_search_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/build/search.zip"
}




// Resources Block

resource "random_id" "rand" {
  byte_length = 4
}

resource "aws_s3_bucket" "site" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_website_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  index_document {
    suffix = "index.html"
  }
  error_document {
    key = "index.html"
  }
}

resource "aws_s3_object" "assets" {
  for_each     = { for f in local.static_files : f => f }
  bucket       = aws_s3_bucket.site.id
  key          = each.value
  source       = "${path.module}/web/${each.value}"
  etag         = filemd5("${path.module}/web/${each.value}")
  content_type = lookup({
    html = "text/html",
    js   = "application/javascript",
    css  = "text/css",
    png  = "image/png",
    jpg  = "image/jpeg",
    jpeg = "image/jpeg",
    gif  = "image/gif",
    svg  = "image/svg+xml"
  }, lower(split(".", each.value)[length(split(".", each.value)) - 1]), "application/octet-stream")
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.site.id
  key          = "index.html"
  content      = local.rendered_index
  content_type = "text/html; charset=utf-8"
  etag         = md5(local.rendered_index)
}


# Allow public reads (website hosting)
resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.public_read.json
}

# --- Lambda role ---

resource "aws_iam_role" "lambda" {
  name               = "${var.project}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Basic logging
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- Lambda function (Node 18) ---
resource "aws_lambda_function" "watch" {
  function_name    = "${var.project}-watch"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs18.x"
  handler          = "watch.handler"
  filename         = data.archive_file.lambda_watch_zip.output_path
  source_code_hash = data.archive_file.lambda_watch_zip.output_base64sha256

  environment {
    variables = merge(var.lambda_env, {
      TMDB_KEY = var.tmdb_key
    })
  }

  # optional memory/timeout tweaks
  memory_size = 256
  timeout     = 10
}

# Search Lambda function
resource "aws_lambda_function" "search" {
  function_name    = "${var.project}-search"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs18.x"
  handler          = "search.handler"
  filename         = data.archive_file.lambda_search_zip.output_path
  source_code_hash = data.archive_file.lambda_search_zip.output_base64sha256
  environment {
    variables = merge(var.lambda_env, {
      TMDB_KEY = var.tmdb_key
    })
  }
  memory_size = 256
  timeout     = 10
}

// Create CloudWatch Log Group for the watch Lambda
resource "aws_cloudwatch_log_group" "watch_lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.watch.function_name}"
  retention_in_days = 14
}

// Create CloudWatch Log Group for the search Lambda
resource "aws_cloudwatch_log_group" "search_lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.search.function_name}"
  retention_in_days = 14
}

# HTTP API Gateway for search and watch endpoints
resource "aws_apigatewayv2_api" "http" {
  name          = "${var.project}-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins  = ["*"]
    allow_methods  = ["GET", "OPTIONS"]
    allow_headers  = ["*"]
  }
}

// Create a CloudWatch Log Group for API Gateway access logs
resource "aws_cloudwatch_log_group" "api_gw_access" {
  name              = "/aws/http-api/${aws_apigatewayv2_api.http.id}"
  retention_in_days = 14
}
// Create CloudWatch Log Group for API Gateway execution logs
resource "aws_cloudwatch_log_group" "api_gw_execution" {
  name              = "/aws/http-api/${aws_apigatewayv2_api.http.id}/default"
  retention_in_days = 14
}

resource "aws_apigatewayv2_integration" "search" {
  api_id           = aws_apigatewayv2_api.http.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.search.invoke_arn
  payload_format_version = "2.0"
}
resource "aws_apigatewayv2_route" "search" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "GET /search"
  target    = "integrations/${aws_apigatewayv2_integration.search.id}"
}

resource "aws_apigatewayv2_integration" "watch" {
  api_id           = aws_apigatewayv2_api.http.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.watch.invoke_arn
  payload_format_version = "2.0"
}
resource "aws_apigatewayv2_route" "watch" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "GET /watch"
  target    = "integrations/${aws_apigatewayv2_integration.watch.id}"
}

// Deploy and configure logs for the default stage
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
  depends_on = [
    aws_apigatewayv2_route.search,
    aws_apigatewayv2_route.watch,
  ]

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw_execution.arn
    format = jsonencode({
      requestId          = "$context.requestId",
      requestTime        = "$context.requestTime",
      httpMethod         = "$context.httpMethod",
      routeKey           = "$context.routeKey",
      status             = "$context.status",
      integrationStatus  = "$context.integrationStatus",
      integrationLatency = "$context.integrationLatency",
      responseLatency    = "$context.responseLatency",
      responseLength     = "$context.responseLength"
    })
  }

  default_route_settings {
    data_trace_enabled       = true
    detailed_metrics_enabled = true
    logging_level            = "INFO"
    throttling_rate_limit    = 10000  # increase per-second rate limit
    throttling_burst_limit   = 20000  # increase burst capacity
  }
  # Enable execution logging per route
  route_settings {
    route_key                 = "GET /search"
    data_trace_enabled        = true
    detailed_metrics_enabled  = true
    logging_level             = "INFO"
    throttling_rate_limit     = 10000
    throttling_burst_limit    = 20000
  }
  route_settings {
    route_key                 = "GET /watch"
    data_trace_enabled        = true
    detailed_metrics_enabled  = true
    logging_level             = "INFO"
    throttling_rate_limit     = 10000
    throttling_burst_limit    = 20000
  }
}

// Permission for API Gateway to invoke the search lambda
resource "aws_lambda_permission" "search_api" {
  statement_id  = "AllowInvokeSearch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.search.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/GET/search"
}
// Permission for API Gateway to invoke the watch lambda
resource "aws_lambda_permission" "watch_api" {
  statement_id  = "AllowInvokeWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.watch.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/GET/watch"
}
