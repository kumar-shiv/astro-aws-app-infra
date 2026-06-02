variable "ecs_cluster_name" {
  description = "ECS cluster name"
  type        = string
}

variable "ecs_cluster_arn" {
  description = "ECS cluster ARN"
  type        = string
}

variable "subnets" {
  description = "Subnet IDs for Fargate task placement"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID for Fargate tasks"
  type        = string
}

variable "container_image" {
  description = "Docker image for Ollama"
  type        = string
  default     = "ollama/ollama:latest"
}

variable "container_port" {
  description = "Port for Ollama container"
  type        = number
  default     = 11434
}

variable "container_cpu" {
  description = "CPU units for Fargate task"
  type        = string
  default     = "2048" # 2 vCPU
}

variable "container_memory" {
  description = "Memory in MB for Fargate task"
  type        = string
  default     = "8192" # 8 GB
}

variable "model" {
  description = "Ollama model to load"
  type        = string
  default     = "llama2"
}

variable "desired_count" {
  description = "Desired number of tasks"
  type        = number
  default     = 2
}

variable "cloudwatch_log_group" {
  description = "CloudWatch log group name for ECS logging"
  type        = string
}

variable "task_execution_role_arn" {
  description = "ARN of ECS task execution role"
  type        = string
}

variable "task_role_arn" {
  description = "ARN of ECS task role"
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
