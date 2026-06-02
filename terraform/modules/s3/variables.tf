variable "bucket_names" {
  description = "List of S3 bucket names to create"
  type        = list(string)
  default     = ["raw", "output", "wiki"]
}

variable "enable_versioning" {
  description = "Enable versioning on S3 buckets"
  type        = bool
  default     = true
}

variable "enable_encryption" {
  description = "Enable encryption on S3 buckets"
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "VPC ID for bucket policy conditions"
  type        = string
}

variable "app_subnet_cidr_blocks" {
  description = "CIDR blocks for app subnets (for future use with more restrictive policies)"
  type        = list(string)
  default     = []
}

variable "project_name" {
  description = "Project name for naming resources"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
