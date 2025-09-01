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
  rendered_index = templatefile("${path.module}/web/index.html.tftpl", {
    function_url = aws_lambda_function_url.api.function_url
  })
  static_files = fileset("${path.module}/web", ["**"])
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

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/watch.mjs"
  output_path = "${path.module}/build/watch.zip"
}

# Archive for search Lambda
data "archive_file" "search_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/search.mjs"
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
  handler          = "index.handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

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
  handler          = "index.handler"
  filename         = data.archive_file.search_zip.output_path
  source_code_hash = data.archive_file.search_zip.output_base64sha256
  environment {
    variables = merge(var.lambda_env, {
      TMDB_KEY = var.tmdb_key
    })
  }
  memory_size = 256
  timeout     = 10
}

# HTTP API Gateway for search and watch endpoints
resource "aws_apigatewayv2_api" "http" {
  name          = "${var.project}-api"
  protocol_type = "HTTP"
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

resource "aws_lambda_permission" "allow_api" {
  for_each       = { for route in [aws_apigatewayv2_route.search, aws_apigatewayv2_route.watch] : route.id => route }
  statement_id  = "AllowInvoke-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.route_key == "GET /search" ? aws_lambda_function.search.function_name : aws_lambda_function.watch.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/${each.value.route_key}"
}
