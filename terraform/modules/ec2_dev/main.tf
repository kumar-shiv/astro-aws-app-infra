data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "defaultForAz"
    values = ["true"]
  }
}

# Amazon Linux 2023 ARM64 — latest AMI resolved at apply time
data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_region" "current" {}

# SSH key pair — public key supplied via tfvars, private key stays on laptop
resource "aws_key_pair" "dev" {
  key_name   = var.key_name
  public_key = var.ssh_public_key

  tags = merge(var.tags, { Name = "${var.project_name}-dev-key" })
}

# Security group — SSH inbound only; Ollama binds to localhost, never exposed
resource "aws_security_group" "dev" {
  name_prefix = "${var.project_name}-dev-"
  description = "Dev EC2: SSH inbound only. Ollama is not exposed publicly."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound (required for Ollama model pull on first boot)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project_name}-dev-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# IAM role for EC2 — S3 read/write only
resource "aws_iam_role" "dev_ec2" {
  name_prefix = "${var.project_name}-dev-ec2-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "${var.project_name}-dev-ec2-role" })
}

resource "aws_iam_role_policy" "dev_s3" {
  name_prefix = "${var.project_name}-dev-s3-"
  role        = aws_iam_role.dev_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadRawBucket"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          var.raw_bucket_arn,
          "${var.raw_bucket_arn}/*"
        ]
      },
      {
        Sid    = "WriteOutputBucket"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [
          var.output_bucket_arn,
          "${var.output_bucket_arn}/*"
        ]
      }
    ]
  })
}

# SSM policy — enables `aws ssm start-session` as an alternative to SSH
resource "aws_iam_role_policy_attachment" "dev_ssm" {
  role       = aws_iam_role.dev_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "dev_ec2" {
  name_prefix = "${var.project_name}-dev-ec2-"
  role        = aws_iam_role.dev_ec2.name

  tags = merge(var.tags, { Name = "${var.project_name}-dev-ec2-profile" })
}

resource "aws_instance" "dev" {
  ami                    = data.aws_ami.al2023_arm64.id
  instance_type          = var.instance_type
  subnet_id              = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.dev.id]
  key_name               = aws_key_pair.dev.key_name
  iam_instance_profile   = aws_iam_instance_profile.dev_ec2.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  # Runs at first boot: installs Ollama, pulls both models for quality comparison.
  # Model pull takes ~10-15 min depending on network. Instance is usable immediately
  # via SSH; check `ollama list` to confirm models are ready before running scripts.
  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    exec > /var/log/user-data.log 2>&1

    echo "=== Installing Ollama ==="
    curl -fsSL https://ollama.com/install.sh | sh
    systemctl enable ollama
    systemctl start ollama

    echo "=== Waiting for Ollama to be ready ==="
    for i in $(seq 1 12); do
      if curl -sf http://localhost:11434/api/tags > /dev/null; then
        echo "Ollama ready after $((i*5)) seconds"
        break
      fi
      sleep 5
    done

    echo "=== Pulling ${var.ollama_model} ==="
    ollama pull ${var.ollama_model}

    echo "=== Model ready ==="
    ollama list
  EOF

  tags = merge(var.tags, { Name = "${var.project_name}-dev-ec2" })
}

# Elastic IP — stable public address that survives stop/start
resource "aws_eip" "dev" {
  instance = aws_instance.dev.id
  domain   = "vpc"

  tags = merge(var.tags, { Name = "${var.project_name}-dev-eip" })

  depends_on = [aws_instance.dev]
}
