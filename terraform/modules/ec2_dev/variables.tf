variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. m7g.xlarge (4 vCPU/16 GB) for gemma3:12b; m7g.large (2 vCPU/8 GB) if 4b is sufficient"
  type        = string
  default     = "m7g.xlarge"
}

variable "key_name" {
  description = "Name of the SSH key pair to create in AWS"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key material (contents of ~/.ssh/astro-dev-key.pub)"
  type        = string
  sensitive   = true
}

variable "root_volume_size_gb" {
  description = "EBS root volume size in GB. Must fit OS + both Ollama models (~11 GB) with headroom"
  type        = number
  default     = 30
}

variable "raw_bucket_arn" {
  description = "ARN of the S3 raw bucket (transcript inputs)"
  type        = string
}

variable "output_bucket_arn" {
  description = "ARN of the S3 output bucket (JSONL results)"
  type        = string
}

variable "ollama_model" {
  description = "Ollama model to pull on first boot"
  type        = string
  default     = "translategemma:latest"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
