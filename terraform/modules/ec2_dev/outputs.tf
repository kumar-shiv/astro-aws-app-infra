output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.dev.id
}

output "public_ip" {
  description = "Elastic IP address (stable across stop/start)"
  value       = aws_eip.dev.public_ip
}

output "default_vpc_id" {
  description = "Default VPC ID (used by S3 module when no custom VPC exists)"
  value       = data.aws_vpc.default.id
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i ~/.ssh/${var.key_name} ec2-user@${aws_eip.dev.public_ip}"
}

output "tunnel_command" {
  description = "SSH tunnel command — run this before invoking Python scripts locally"
  value       = "ssh -N -L 11434:localhost:11434 -i ~/.ssh/${var.key_name} ec2-user@${aws_eip.dev.public_ip}"
}

output "model_check_command" {
  description = "Command to verify both models are ready (run after SSH in)"
  value       = "ssh -i ~/.ssh/${var.key_name} ec2-user@${aws_eip.dev.public_ip} 'ollama list'"
}

output "user_data_log" {
  description = "Command to tail the bootstrap log (model pull progress)"
  value       = "ssh -i ~/.ssh/${var.key_name} ec2-user@${aws_eip.dev.public_ip} 'tail -f /var/log/user-data.log'"
}
