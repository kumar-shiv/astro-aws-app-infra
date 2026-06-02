output "db_subnet_ids" {
  description = "Database subnet IDs"
  value       = aws_subnet.db[*].id
}

output "db_subnet_cidrs" {
  description = "Database subnet CIDR blocks"
  value       = aws_subnet.db[*].cidr_block
}

output "llm_subnet_ids" {
  description = "LLM subnet IDs"
  value       = aws_subnet.llm[*].id
}

output "llm_subnet_cidrs" {
  description = "LLM subnet CIDR blocks"
  value       = aws_subnet.llm[*].cidr_block
}

output "app_subnet_ids" {
  description = "Application subnet IDs"
  value       = aws_subnet.app[*].id
}

output "app_subnet_cidrs" {
  description = "Application subnet CIDR blocks"
  value       = aws_subnet.app[*].cidr_block
}

output "frontend_subnet_ids" {
  description = "Frontend subnet IDs"
  value       = aws_subnet.frontend[*].id
}

output "frontend_subnet_cidrs" {
  description = "Frontend subnet CIDR blocks"
  value       = aws_subnet.frontend[*].cidr_block
}

output "db_route_table_ids" {
  description = "Database route table IDs"
  value       = [aws_route_table.db.id]
}

output "llm_route_table_ids" {
  description = "LLM route table IDs"
  value       = [aws_route_table.llm.id]
}

output "app_route_table_ids" {
  description = "Application route table IDs"
  value       = [aws_route_table.app.id]
}

output "frontend_route_table_ids" {
  description = "Frontend route table IDs"
  value       = [aws_route_table.frontend.id]
}
