output "service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.ollama.name
}

output "service_cluster_arn" {
  description = "ECS cluster ARN where service is running"
  value       = aws_ecs_service.ollama.cluster
}

output "task_definition_arn" {
  description = "ECS task definition ARN"
  value       = aws_ecs_task_definition.ollama.arn
}

output "task_definition_revision" {
  description = "ECS task definition revision"
  value       = aws_ecs_task_definition.ollama.revision
}

output "container_port" {
  description = "Container port for Ollama"
  value       = var.container_port
}

output "service_endpoint_internal" {
  description = "Internal service endpoint for inter-container communication"
  value       = "${aws_ecs_service.ollama.name}.local:${var.container_port}"
}
