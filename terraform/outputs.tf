# Dev EC2 Outputs
output "dev_ec2_instance_id" {
  description = "Dev EC2 instance ID"
  value       = var.enable_dev_ec2 ? module.ec2_dev[0].instance_id : null
}

output "dev_ec2_public_ip" {
  description = "Dev EC2 Elastic IP (stable across stop/start)"
  value       = var.enable_dev_ec2 ? module.ec2_dev[0].public_ip : null
}

output "dev_ssh_command" {
  description = "SSH command to connect to dev EC2"
  value       = var.enable_dev_ec2 ? module.ec2_dev[0].ssh_command : null
}

output "dev_tunnel_command" {
  description = "SSH tunnel command — run before invoking Python scripts locally"
  value       = var.enable_dev_ec2 ? module.ec2_dev[0].tunnel_command : null
}

output "dev_model_check" {
  description = "Command to verify both Ollama models are ready"
  value       = var.enable_dev_ec2 ? module.ec2_dev[0].model_check_command : null
}

output "dev_bootstrap_log" {
  description = "Command to tail bootstrap log (model pull progress)"
  value       = var.enable_dev_ec2 ? module.ec2_dev[0].user_data_log : null
}

# S3 bucket names (needed for Python env vars)
output "raw_bucket_name" {
  description = "S3 raw bucket name — set as S3_INPUT_BUCKET env var"
  value       = module.s3.raw_bucket_name
}

output "output_bucket_name" {
  description = "S3 output bucket name — set as S3_OUTPUT_BUCKET env var"
  value       = module.s3.output_bucket_name
}

# VPC Outputs
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = module.vpc.vpc_cidr
}

# Public Subnet Outputs
output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

# Private Subnet Outputs
output "db_subnet_ids" {
  description = "Database subnet IDs"
  value       = module.private_subnets.db_subnet_ids
}

output "llm_subnet_ids" {
  description = "LLM subnet IDs"
  value       = module.private_subnets.llm_subnet_ids
}

output "app_subnet_ids" {
  description = "Application subnet IDs"
  value       = module.private_subnets.app_subnet_ids
}

output "frontend_subnet_ids" {
  description = "Frontend subnet IDs"
  value       = module.private_subnets.frontend_subnet_ids
}

# NAT Gateway Outputs
output "nat_gateway_ids" {
  description = "NAT Gateway IDs"
  value       = module.nat_gateway.nat_gateway_ids
}

output "nat_gateway_eips" {
  description = "NAT Gateway Elastic IP addresses"
  value       = module.nat_gateway.eip_addresses
}

# Security Group Outputs
output "frontend_sg_id" {
  description = "Frontend security group ID"
  value       = module.security_groups.frontend_sg_id
}

output "app_sg_id" {
  description = "Application security group ID"
  value       = module.security_groups.app_sg_id
}

output "llm_sg_id" {
  description = "LLM security group ID"
  value       = module.security_groups.llm_sg_id
}

output "rds_sg_id" {
  description = "RDS security group ID"
  value       = module.security_groups.rds_sg_id
}

# S3 Outputs
output "s3_bucket_names" {
  description = "Created S3 bucket names"
  value       = module.s3.bucket_names
}

output "raw_bucket_arn" {
  description = "ARN of raw bucket"
  value       = module.s3.raw_bucket_arn
}

output "output_bucket_arn" {
  description = "ARN of output bucket"
  value       = module.s3.output_bucket_arn
}

# RDS Outputs
output "rds_endpoint" {
  description = "RDS endpoint address"
  value       = module.rds.rds_endpoint
  sensitive   = false
}

output "rds_instance_id" {
  description = "RDS instance identifier"
  value       = module.rds.rds_instance_id
}

output "rds_port" {
  description = "RDS port"
  value       = module.rds.rds_port
}

# ECS Outputs
output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.ecs_cluster.cluster_name
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN"
  value       = module.ecs_cluster.cluster_arn
}

# Ollama Outputs
output "ollama_service_name" {
  description = "Ollama ECS service name"
  value       = module.ollama_fargate.service_name
}

output "ollama_task_definition_arn" {
  description = "Ollama ECS task definition ARN"
  value       = module.ollama_fargate.task_definition_arn
}

output "ollama_container_port" {
  description = "Ollama container port"
  value       = var.ollama_container_port
}

output "ollama_internal_endpoint" {
  description = "Internal DNS name for Ollama service (use from app subnet)"
  value       = module.ollama_fargate.service_name
}
