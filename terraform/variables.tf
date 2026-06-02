variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "aws-slm-app"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones for multi-AZ deployment"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

# Subnet CIDR variables
variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "db_subnet_cidrs" {
  description = "CIDR blocks for database private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "llm_subnet_cidrs" {
  description = "CIDR blocks for LLM private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "app_subnet_cidrs" {
  description = "CIDR blocks for application private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.31.0/24", "10.0.32.0/24"]
}

variable "frontend_subnet_cidrs" {
  description = "CIDR blocks for frontend private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.41.0/24", "10.0.42.0/24"]
}

# RDS variables
variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS in GB"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Master username for RDS"
  type        = string
  default     = "postgres"
  sensitive   = true
}

variable "db_password" {
  description = "Master password for RDS"
  type        = string
  sensitive   = true
}

variable "db_backup_retention_days" {
  description = "Backup retention period in days"
  type        = number
  default     = 7
}

variable "db_multi_az" {
  description = "Enable Multi-AZ RDS deployment"
  type        = bool
  default     = true
}

variable "db_engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "15.3"
}

# S3 variables
variable "s3_bucket_names" {
  description = "List of S3 bucket names to create"
  type        = list(string)
  default     = ["raw", "output", "wiki"]
}

variable "s3_enable_versioning" {
  description = "Enable versioning on S3 buckets"
  type        = bool
  default     = true
}

variable "s3_enable_encryption" {
  description = "Enable encryption on S3 buckets"
  type        = bool
  default     = true
}

# Ollama variables
variable "ollama_container_image" {
  description = "Docker image for Ollama"
  type        = string
  default     = "ollama/ollama:latest"
}

variable "ollama_container_port" {
  description = "Port for Ollama API"
  type        = number
  default     = 11434
}

variable "ollama_cpu" {
  description = "CPU units for Ollama Fargate task (256 = 0.25 vCPU)"
  type        = string
  default     = "2048" # 2 vCPU
}

variable "ollama_memory" {
  description = "Memory in MB for Ollama Fargate task"
  type        = string
  default     = "8192" # 8 GB
}

variable "ollama_model" {
  description = "Ollama model to load"
  type        = string
  default     = "llama2"
}

variable "ollama_desired_count" {
  description = "Desired number of Ollama tasks"
  type        = number
  default     = 2
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnet internet access"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
