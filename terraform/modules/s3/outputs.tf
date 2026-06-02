output "bucket_names" {
  description = "S3 bucket names"
  value = {
    for k, v in aws_s3_bucket.main : k => v.id
  }
}

output "bucket_arns" {
  description = "S3 bucket ARNs"
  value = {
    for k, v in aws_s3_bucket.main : k => v.arn
  }
}

output "raw_bucket_name" {
  description = "Raw S3 bucket name"
  value       = try(aws_s3_bucket.main["raw"].id, "")
}

output "raw_bucket_arn" {
  description = "Raw S3 bucket ARN"
  value       = try(aws_s3_bucket.main["raw"].arn, "")
}

output "output_bucket_name" {
  description = "Output S3 bucket name"
  value       = try(aws_s3_bucket.main["output"].id, "")
}

output "output_bucket_arn" {
  description = "Output S3 bucket ARN"
  value       = try(aws_s3_bucket.main["output"].arn, "")
}

output "wiki_bucket_name" {
  description = "Wiki S3 bucket name"
  value       = try(aws_s3_bucket.main["wiki"].id, "")
}

output "wiki_bucket_arn" {
  description = "Wiki S3 bucket ARN"
  value       = try(aws_s3_bucket.main["wiki"].arn, "")
}
