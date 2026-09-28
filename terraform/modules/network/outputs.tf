output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "azs" {
  value = local.azs
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  description = "Private app subnets. Only reported once their egress route exists, so instances launched into them can reach ECR/SSM during boot."
  value       = aws_subnet.app[*].id

  depends_on = [aws_route_table_association.app, aws_route.app_nat, aws_vpc_endpoint.s3]
}

output "db_subnet_ids" {
  value = aws_subnet.db[*].id
}

output "nat_gateway_ids" {
  value = aws_nat_gateway.this[*].id
}

output "nat_public_ips" {
  value = aws_eip.nat[*].public_ip
}
