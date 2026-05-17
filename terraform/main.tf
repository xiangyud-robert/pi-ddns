terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # Partial backend — supply bucket/key/region via:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "pi-ddns"
      ManagedBy = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------
# Lambda
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "pi-ddns-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "route53_upsert" {
  statement {
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
  }
  statement {
    actions   = ["route53:ListResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
  }
}

resource "aws_iam_role_policy" "route53_upsert" {
  name   = "route53-upsert"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.route53_upsert.json
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/dist/handler.js"
  output_path = "${path.module}/../lambda/dist/handler.zip"
}

resource "aws_lambda_function" "ddns" {
  function_name    = "pi-ddns"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.handler"
  runtime          = "nodejs24.x"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      HOSTED_ZONE_ID = var.hosted_zone_id
      RECORD_NAME    = var.record_name
      TTL            = tostring(var.ttl)
    }
  }
}

# ---------------------------------------------------------------------------
# API Gateway (REST — required for usage plans + API keys)
# ---------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "ddns" {
  name        = "pi-ddns"
  description = "DDNS update endpoint"
}

resource "aws_api_gateway_resource" "update" {
  rest_api_id = aws_api_gateway_rest_api.ddns.id
  parent_id   = aws_api_gateway_rest_api.ddns.root_resource_id
  path_part   = "update"
}

resource "aws_api_gateway_method" "post" {
  rest_api_id      = aws_api_gateway_rest_api.ddns.id
  resource_id      = aws_api_gateway_resource.update.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id             = aws_api_gateway_rest_api.ddns.id
  resource_id             = aws_api_gateway_resource.update.id
  http_method             = aws_api_gateway_method.post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.ddns.invoke_arn
}

resource "aws_api_gateway_deployment" "ddns" {
  rest_api_id = aws_api_gateway_rest_api.ddns.id

  # Force redeploy when the integration changes
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.update.id,
      aws_api_gateway_method.post.id,
      aws_api_gateway_integration.lambda.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.ddns.id
  deployment_id = aws_api_gateway_deployment.ddns.id
  stage_name    = "prod"
}

resource "aws_api_gateway_method_settings" "prod" {
  rest_api_id = aws_api_gateway_rest_api.ddns.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = var.api_throttle_rate_limit
    throttling_burst_limit = var.api_throttle_burst_limit
  }
}

# Usage plan (quota + throttle enforced at the key level)
resource "aws_api_gateway_usage_plan" "ddns" {
  name = "pi-ddns-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.ddns.id
    stage  = aws_api_gateway_stage.prod.stage_name
  }

  throttle_settings {
    rate_limit  = var.api_throttle_rate_limit
    burst_limit = var.api_throttle_burst_limit
  }

  quota_settings {
    limit  = var.api_quota_limit
    period = "DAY"
  }
}

resource "aws_api_gateway_api_key" "home_server" {
  name    = "pi-ddns-home-server"
  enabled = true
}

resource "aws_api_gateway_usage_plan_key" "home_server" {
  key_id        = aws_api_gateway_api_key.home_server.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.ddns.id
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ddns.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.ddns.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC role
# ---------------------------------------------------------------------------

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "pi-ddns-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

data "aws_iam_policy_document" "github_actions_permissions" {
  # Lambda: update function code + configuration
  statement {
    actions = [
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
    ]
    resources = [aws_lambda_function.ddns.arn]
  }
  # Terraform state bucket (supplied via backend config)
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = ["*"] # narrowed to specific bucket in backend.hcl at init time
  }
  # Read API key value for cron setup output
  statement {
    actions   = ["apigateway:GET"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "pi-ddns-deploy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}
