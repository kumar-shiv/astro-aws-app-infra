output "vpc_endpoint_sg_id" {
  description = "VPC Endpoint security group ID"
  value       = aws_security_group.vpc_endpoint.id
}

output "rds_sg_id" {
  description = "RDS security group ID"
  value       = aws_security_group.rds.id
}

output "llm_sg_id" {
  description = "LLM security group ID"
  value       = aws_security_group.llm.id
}

output "app_sg_id" {
  description = "Application security group ID"
  value       = aws_security_group.app.id
}

output "frontend_sg_id" {
  description = "Frontend security group ID"
  value       = aws_security_group.frontend.id
}
