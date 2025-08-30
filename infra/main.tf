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
  source_file = "${path.module}/lambda/index.mjs"
  output_path = "${path.module}/build/lambda.zip"
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
resource "aws_lambda_function" "api" {
  function_name    = local.lambda_name
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

# Public function URL (no auth, CORS open — you can tighten to your domain later)
resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.function_name
  authorization_type = "NONE"
  cors {
    allow_origins     = ["*"]   # or your site origin
    allow_methods     = ["GET"] # not "OPTIONS"
    allow_headers     = ["*"]
    expose_headers    = []
    max_age           = 3600
    allow_credentials = false
  }
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.site.id
  key          = "index.html"
  content      = local.rendered_index
  content_type = "text/html; charset=utf-8"
  etag         = md5(local.rendered_index)
}

