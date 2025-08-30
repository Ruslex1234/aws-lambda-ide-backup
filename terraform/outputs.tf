output "bucket_name" {
  value       = aws_s3_bucket.backups.bucket
  description = "Backup bucket"
}

output "watcher_function_name" {
  value       = aws_lambda_function.watcher.function_name
  description = "Watcher Lambda name"
}

output "event_rule_arn" {
  value       = aws_cloudwatch_event_rule.lambda_code_updates.arn
  description = "EventBridge rule ARN"
}
