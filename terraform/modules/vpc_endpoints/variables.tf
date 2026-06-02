variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for interface endpoints"
  type        = list(string)
}

variable "route_table_ids" {
  description = "Route table IDs for S3 gateway endpoint"
  type        = list(string)
}

variable "vpc_endpoint_security_group_id" {
  description = "Security group ID for VPC endpoints"
  type        = string
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
