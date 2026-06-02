# Security group for VPC Endpoints
resource "aws_security_group" "vpc_endpoint" {
  name_prefix = "${var.project_name}-vpc-endpoint-"
  description = "Security group for VPC endpoints"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # Allow from entire VPC
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-vpc-endpoint-sg"
    }
  )
}

# Security group for RDS
resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  description = "Security group for RDS database"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-rds-sg"
    }
  )
}

# Security group for LLM services
resource "aws_security_group" "llm" {
  name_prefix = "${var.project_name}-llm-"
  description = "Security group for LLM services (Ollama)"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-llm-sg"
    }
  )
}

# Security group for application services
resource "aws_security_group" "app" {
  name_prefix = "${var.project_name}-app-"
  description = "Security group for application services"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-app-sg"
    }
  )
}

# Security group for frontend services
resource "aws_security_group" "frontend" {
  name_prefix = "${var.project_name}-frontend-"
  description = "Security group for frontend services"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-frontend-sg"
    }
  )
}

# Ingress Rules
# LLM SG: Allow inbound from App SG on LLM port
resource "aws_security_group_rule" "llm_from_app" {
  type                     = "ingress"
  from_port                = var.ollama_port
  to_port                  = var.ollama_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.llm.id

  description = "Allow inbound from app to LLM API"
}

# RDS SG: Allow inbound from App SG on PostgreSQL port
resource "aws_security_group_rule" "rds_from_app" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.rds.id

  description = "Allow inbound from app to RDS"
}

# App SG: Allow inbound from Frontend SG
resource "aws_security_group_rule" "app_from_frontend" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.frontend.id
  security_group_id        = aws_security_group.app.id

  description = "Allow inbound from frontend on HTTP"
}

resource "aws_security_group_rule" "app_from_frontend_https" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.frontend.id
  security_group_id        = aws_security_group.app.id

  description = "Allow inbound from frontend on HTTPS"
}

# Allow app services to communicate with each other on any port (optional, for flexibility)
resource "aws_security_group_rule" "app_internal" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = ["10.0.31.0/24", "10.0.32.0/24"]
  security_group_id = aws_security_group.app.id

  description = "Allow internal app subnet communication"
}
