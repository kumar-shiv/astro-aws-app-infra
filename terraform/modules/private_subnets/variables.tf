variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "db_subnet_cidrs" {
  description = "CIDR blocks for database subnets"
  type        = list(string)
}

variable "llm_subnet_cidrs" {
  description = "CIDR blocks for LLM subnets"
  type        = list(string)
}

variable "app_subnet_cidrs" {
  description = "CIDR blocks for application subnets"
  type        = list(string)
}

variable "frontend_subnet_cidrs" {
  description = "CIDR blocks for frontend subnets"
  type        = list(string)
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
}

variable "nat_gateway_ids" {
  description = "NAT Gateway IDs for routing"
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
