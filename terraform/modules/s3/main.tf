# Create S3 buckets dynamically based on bucket_names variable
resource "aws_s3_bucket" "main" {
  for_each = toset(var.bucket_names)

  bucket = "${var.project_name}-${each.value}-${data.aws_caller_identity.current.account_id}"

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${each.value}"
      Type = each.value
    }
  )
}

# Enable versioning
resource "aws_s3_bucket_versioning" "main" {
  for_each = var.enable_versioning ? aws_s3_bucket.main : {}

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enable encryption by default
resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  for_each = var.enable_encryption ? aws_s3_bucket.main : {}

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "main" {
  for_each = aws_s3_bucket.main

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket policy for raw bucket - Allow read from app subnet
resource "aws_s3_bucket_policy" "raw" {
  bucket = aws_s3_bucket.main["raw"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAppSubnetReadRawBucket"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.main["raw"].arn,
          "${aws_s3_bucket.main["raw"].arn}/*"
        ]
        Condition = {
          StringEquals = {
            "aws:SourceVpc" = var.vpc_id
          }
        }
      }
    ]
  })
}

# Bucket policy for output bucket - Allow write and read from app subnet
resource "aws_s3_bucket_policy" "output" {
  bucket = aws_s3_bucket.main["output"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAppSubnetWriteOutputBucket"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.main["output"].arn,
          "${aws_s3_bucket.main["output"].arn}/*"
        ]
        Condition = {
          StringEquals = {
            "aws:SourceVpc" = var.vpc_id
          }
        }
      }
    ]
  })
}

data "aws_caller_identity" "current" {}

locals {
  raw_bucket    = try(aws_s3_bucket.main["raw"].id, "")
  output_bucket = try(aws_s3_bucket.main["output"].id, "")
  wiki_bucket   = try(aws_s3_bucket.main["wiki"].id, "")
}
