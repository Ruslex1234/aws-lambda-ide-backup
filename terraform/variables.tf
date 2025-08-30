variable "region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "backup_bucket" {
  type        = string
  description = "S3 bucket name to store backups"
}

variable "dest_prefix" {
  type        = string
  description = "S3 key prefix for backups"
  default     = "lambda-code-backups"
}

variable "watcher_name" {
  type        = string
  description = "Lambda function name for the watcher"
  default     = "lambda-code-watcher"
}

variable "eventbridge_rule_name" {
  type        = string
  description = "EventBridge rule name"
  default     = "lambda-code-watcher-code-updates"
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention"
  default     = 30
}

# For optional rule filtering and IAM tightening (no secrets)
variable "account_id" {
  type        = string
  description = "AWS Account ID (used to build ARNs if function_name is provided)"
  default     = ""
}

variable "function_name" {
  type        = string
  description = "Target Lambda name to filter the EventBridge rule (leave empty to match ALL Lambdas)"
  default     = ""
}

# Optional: KMS for S3 bucket
variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN for S3 encryption (optional)"
  default     = null
}
