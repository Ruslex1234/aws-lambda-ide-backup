terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

provider "aws" {
  region = var.region
}

# -------- S3 bucket (versioning) --------
resource "aws_s3_bucket" "backups" {
  bucket = var.backup_bucket
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Optional: server-side encryption (uncomment to use a customer KMS key)
# resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
#   count  = var.kms_key_arn != null ? 1 : 0
#   bucket = aws_s3_bucket.backups.id
#   rule {
#     apply_server_side_encryption_by_default {
#       sse_algorithm     = "aws:kms"
#       kms_master_key_id = var.kms_key_arn
#     }
#   }
# }

# -------- CloudWatch Logs for watcher --------
resource "aws_cloudwatch_log_group" "watcher" {
  name              = "/aws/lambda/${var.watcher_name}"
  retention_in_days = var.log_retention_days
}

# -------- IAM role for watcher Lambda --------
data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "watcher" {
  name               = "${var.watcher_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

# Managed policy for logs
resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.watcher.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Build optional scoped ARNs if function_name + account_id provided
locals {
  target_function_arns_effective = var.function_name != "" && var.account_id != "" ? [
    "arn:aws:lambda:${var.region}:${var.account_id}:function:${var.function_name}"
  ] : []

  # Fallback to "*" if no function scope was provided (you can tighten later)
  read_lambda_resources = length(local.target_function_arns_effective) > 0 ? local.target_function_arns_effective : ["*"]
}

# Inline least-privilege policy for the watcher
data "aws_iam_policy_document" "watcher_inline" {
  statement {
    sid       = "ReadTargetLambdaCode"
    actions   = ["lambda:GetFunction"]
    resources = local.read_lambda_resources
  }

  statement {
    sid       = "BucketVersioning"
    actions   = ["s3:GetBucketVersioning", "s3:PutBucketVersioning"]
    resources = ["arn:aws:s3:::${var.backup_bucket}"]
  }

  statement {
    sid       = "ListStatePrefixOnly"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.backup_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [
        "${var.dest_prefix}/.state",
        "${var.dest_prefix}/.state/*"
      ]
    }
  }

  statement {
    sid       = "WriteAndReadBackups"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:GetObjectVersion"]
    resources = ["arn:aws:s3:::${var.backup_bucket}/${var.dest_prefix}/*"]
  }

  # Optional: include only if you enabled KMS encryption on the bucket
  # statement {
  #   sid       = "KmsForS3Objects"
  #   actions   = ["kms:Encrypt", "kms:GenerateDataKey", "kms:Decrypt"]
  #   resources = [var.kms_key_arn]
  #   condition {
  #     test     = "StringEquals"
  #     variable = "kms:ViaService"
  #     values   = ["s3.${var.region}.amazonaws.com"]
  #   }
  # }
}

resource "aws_iam_role_policy" "watcher_inline" {
  name   = "${var.watcher_name}-inline"
  role   = aws_iam_role.watcher.id
  policy = data.aws_iam_policy_document.watcher_inline.json
}

# -------- Package Lambda from source directory --------
data "archive_file" "zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/lambda/code_watcher"
  output_path = "${path.module}/lambda-code-watcher.zip"
}

# -------- Lambda function --------
resource "aws_lambda_function" "watcher" {
  function_name = var.watcher_name
  role          = aws_iam_role.watcher.arn
  runtime       = "python3.11"
  handler       = "handler.lambda_handler"
  filename      = data.archive_file.zip.output_path
  timeout       = 60
  memory_size   = 256
  architectures = ["arm64"]

  environment {
    variables = {
      DEST_BUCKET  = aws_s3_bucket.backups.bucket
      DEST_PREFIX  = var.dest_prefix
      STATE_PREFIX = "${var.dest_prefix}/.state"
    }
  }

  depends_on = [aws_cloudwatch_log_group.watcher]
}

# -------- EventBridge rule (CloudTrail management events) --------
# Build pattern; include function filter only if provided
locals {
  event_detail_base = {
    eventSource = ["lambda.amazonaws.com"]
    eventName   = [
      { prefix = "UpdateFunctionCode" },
      { prefix = "PublishVersion" }
    ]
  }

  event_detail_filtered = var.function_name != "" && var.account_id != ""
    ? merge(local.event_detail_base, {
        requestParameters = {
          functionName = [
            var.function_name,
            "arn:aws:lambda:${var.region}:${var.account_id}:function:${var.function_name}"
          ]
        }
      })
    : local.event_detail_base

  event_pattern = jsonencode({
    source        = ["aws.lambda"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail        = local.event_detail_filtered
  })
}

resource "aws_cloudwatch_event_rule" "lambda_code_updates" {
  name           = var.eventbridge_rule_name
  event_bus_name = "default"
  event_pattern  = local.event_pattern
}

resource "aws_cloudwatch_event_target" "to_watcher" {
  rule      = aws_cloudwatch_event_rule.lambda_code_updates.name
  target_id = "watcher"
  arn       = aws_lambda_function.watcher.arn
}

resource "aws_lambda_permission" "allow_events" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.watcher.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_code_updates.arn
}
