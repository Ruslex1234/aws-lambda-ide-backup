region           = "us-east-1"
backup_bucket    = "YOUR_BACKUP_BUCKET"
dest_prefix      = "lambda-code-backups"
watcher_name     = "lambda-code-watcher"
log_retention_days = 14

# Tighten IAM to your target Lambdas
target_function_arns = [
  "arn:aws:lambda:REGION:ACCOUNT_ID:function:FUNCTION_NAME"
]

# Optional: filter EventBridge to specific functions (names)
target_function_names = [
  "FUNCTION_NAME"
]
