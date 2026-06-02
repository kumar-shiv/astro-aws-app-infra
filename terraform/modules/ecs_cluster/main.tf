# CloudWatch Log Group for ECS
resource "aws_cloudwatch_log_group" "ecs" {
  name_prefix = "/ecs/${var.project_name}-"
  retention_in_days = 7

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-ecs-logs"
    }
  )
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-ecs-cluster"
    }
  )
}

# ECS Cluster Capacity Providers (for Fargate)
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}
