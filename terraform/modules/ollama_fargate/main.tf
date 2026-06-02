# ECS Task Definition for Ollama
resource "aws_ecs_task_definition" "ollama" {
  family                   = "${var.project_name}-ollama"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.container_cpu
  memory                   = var.container_memory

  execution_role_arn = var.task_execution_role_arn
  task_role_arn      = var.task_role_arn

  container_definitions = jsonencode([
    {
      name      = "ollama"
      image     = var.container_image
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "OLLAMA_HOST"
          value = "0.0.0.0:${var.container_port}"
        },
        {
          name  = "OLLAMA_KEEP_ALIVE"
          value = "5m"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.cloudwatch_log_group
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ollama"
        }
      }

      # Health check for Ollama API
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/api/tags || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-ollama-task"
    }
  )
}

# ECS Service for Ollama
resource "aws_ecs_service" "ollama" {
  name            = "${var.project_name}-ollama-service"
  cluster         = var.ecs_cluster_name
  task_definition = aws_ecs_task_definition.ollama.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = var.subnets
    security_groups = [var.security_group_id]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-ollama-service"
    }
  )

  depends_on = [aws_ecs_task_definition.ollama]
}

# Auto Scaling Target for Ollama service (optional, for scaling based on metrics)
resource "aws_appautoscaling_target" "ollama" {
  max_capacity       = 4
  min_capacity       = var.desired_count
  resource_id        = "service/${var.ecs_cluster_name}/${aws_ecs_service.ollama.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.ollama]
}

# CPU-based scaling policy
resource "aws_appautoscaling_policy" "ollama_cpu" {
  name               = "${var.project_name}-ollama-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ollama.resource_id
  scalable_dimension = aws_appautoscaling_target.ollama.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ollama.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

# Memory-based scaling policy
resource "aws_appautoscaling_policy" "ollama_memory" {
  name               = "${var.project_name}-ollama-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ollama.resource_id
  scalable_dimension = aws_appautoscaling_target.ollama.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ollama.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value = 80.0
  }
}

data "aws_region" "current" {}
