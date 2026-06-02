output "nat_gateway_ids" {
  description = "NAT Gateway IDs"
  value       = aws_nat_gateway.main[*].id
}

output "eip_addresses" {
  description = "Elastic IP addresses for NAT Gateways"
  value       = aws_eip.nat[*].public_ip
}

output "eip_ids" {
  description = "Elastic IP allocation IDs"
  value       = aws_eip.nat[*].id
}
