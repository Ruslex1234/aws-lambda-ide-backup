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

# --- S3 bucket with versioning ---
resource "aws_s3_bucket" "backups" {
  bucket = var.backup_bucket
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration { status = "Enabled" }
}

# --- CloudWatch Logs (explicit to control retention) ---
resource "aws_cloudwatch_log_group" "watcher" {
  name              = "/aws/lambda/${var.watcher_name}"
  retention_in_days = var.log_retention_days
}

# --- IAM role for watcher Lambda ---
data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service", identifiers = ["lambda.amazonaws.com"] }
  }
}

resource "aws_iam_role" "watcher" {
  name               = "${var.watcher_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

# Managed logs policy
resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.watcher.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Inline least-privilege policy
data "aws_iam_policy_document" "watcher_inline" {
  statement {
    sid       = "ReadTargetLambdaCode"
    actions   = ["lambda:GetFunction"]
    resources = var.target_function_arns
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

  # Uncomment if bucket uses a customer-managed KMS key
  # statement {
  #   sid       = "KmsForS3Objects"
  #   actions   = ["kms:Encrypt", "kms:GenerateDataKey", "kms:Decrypt"]
  #   resources = [var.kms_key_arn]
  # }
}

resource "aws_iam_role_policy" "watcher_inline" {
  name   = "${var.watcher_name}-inline"
  role   = aws_iam_role.watcher.id
  policy = data.aws_iam_policy_document.watcher_inline.json
}

# --- Package Lambda from source directory ---
data "archive_file" "zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/lambda/code_watcher"
  output_path = "${path.module}/lambda-code-watcher.zip"
}

# --- Lambda function ---
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
      # Keep TARGET_FUNCTION(S) unset for EventBridge; set in testing if needed
    }
  }

  depends_on = [aws_cloudwatch_log_group.watcher]
}

# --- EventBridge rule (CloudTrail management events) ---
# Broad pattern: back up on any function code update/publish (you can inject a filtered pattern instead)
locals {
  event_pattern = jsonencode({
    source       = ["aws.lambda"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["lambda.amazonaws.com"]
      eventName   = [
        { prefix = "UpdateFunctionCode" },
        { prefix = "PublishVersion" }
      ]
      # To filter specific functions, add requestParameters.functionName of names/ARNs
      # requestParameters = { functionName = concat(var.target_function_names, var.target_function_arns) }
    }
  })
}

resource "aws_cloudwatch_event_rule" "lambda_code_updates" {
  name           = "${var.watcher_name}-code-updates"
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
