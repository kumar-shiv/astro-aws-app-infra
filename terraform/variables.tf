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
  default     = "astro-app"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones. Single AZ for Phase 1 (cost); expand to 2 at Phase 5."
  type        = list(string)
  default     = ["us-east-1a"]
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
  description = "RDS instance class. db.t4g.micro (~$12/mo) sufficient for 10K records; upgrade via tfvars."
  type        = string
  default     = "db.t4g.micro"
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
  description = "Enable Multi-AZ RDS deployment. Off for Phase 1; enable at Phase 5."
  type        = bool
  default     = false
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
  default     = "translategemma:latest"
}

variable "ollama_desired_count" {
  description = "Desired number of Ollama Fargate tasks. 0 = stopped (default); set to 1 before a batch run."
  type        = number
  default     = 0
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway. False: pipeline tasks use public subnets with direct IGW egress."
  type        = bool
  default     = false
}

# S3 bucket policy VPC ID — decoupled from vpc module so S3 can be applied independently.
# For dev:  run `aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query Vpcs[0].VpcId --output text`
# For prod: set to the custom VPC ID after applying the vpc module.
variable "s3_vpc_id" {
  description = "VPC ID passed to S3 bucket policies (extra Allow; IAM roles grant actual access)"
  type        = string
}

# Dev EC2 variables
variable "enable_dev_ec2" {
  description = "Create the dev EC2 instance (EC2 + EIP + SG + IAM). Destroy with terraform destroy -target=module.ec2_dev"
  type        = bool
  default     = false
}

variable "dev_ec2_instance" {
  description = "EC2 instance type for dev. m7g.xlarge for gemma3:12b; m7g.large if 4b is sufficient."
  type        = string
  default     = "m7g.xlarge"
}

variable "dev_ec2_key_name" {
  description = "Name of the SSH key pair to register in AWS"
  type        = string
  default     = "astro-dev-key"
}

variable "dev_ssh_public_key" {
  description = "SSH public key material. Contents of ~/.ssh/astro-dev-key.pub. Never commit this value."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
