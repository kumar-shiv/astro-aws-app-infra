variable "vpc_id" {
  description = "VPC ID"
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

variable "ollama_port" {
  description = "Port for Ollama API"
  type        = number
  default     = 11434
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
