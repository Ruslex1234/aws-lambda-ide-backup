variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "backup_bucket" {
  type        = string
  description = "S3 bucket name to store backups"
}

variable "dest_prefix" {
  type        = string
  default     = "lambda-code-backups"
  description = "S3 key prefix for backups"
}

variable "watcher_name" {
  type        = string
  default     = "lambda-code-watcher"
  description = "Watcher Lambda function name"
}

variable "log_retention_days" {
  type        = number
  default     = 30
}

variable "target_function_arns" {
  type        = list(string)
  default     = []
  description = "List of Lambda ARNs the watcher may read (lambda:GetFunction). Leave empty to allow none (update later)."
}

variable "target_function_names" {
  type        = list(string)
  default     = []
  description = "Optional: specific Lambda names for EventBridge filter (if you choose to filter)."
}

# Uncomment if using SSE-KMS on the bucket
# variable "kms_key_arn" {
#   type        = string
#   default     = null
#   description = "KMS key ARN for S3 encryption"
# }
