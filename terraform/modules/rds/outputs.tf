output "rds_endpoint" {
  description = "RDS endpoint address"
  value       = aws_db_instance.main.endpoint
}

output "rds_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.main.identifier
}

output "rds_port" {
  description = "RDS port"
  value       = aws_db_instance.main.port
}

output "rds_engine" {
  description = "RDS engine"
  value       = aws_db_instance.main.engine
}

output "rds_engine_version" {
  description = "RDS engine version"
  value       = aws_db_instance.main.engine_version_actual
}

output "db_subnet_group_name" {
  description = "Database subnet group name"
  value       = aws_db_subnet_group.main.name
}
