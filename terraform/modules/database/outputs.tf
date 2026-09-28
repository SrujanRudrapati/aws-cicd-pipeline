output "address" {
  description = "Hostname only (no port)."
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "instance_id" {
  description = "DBInstanceIdentifier, for CloudWatch dimensions."
  value       = aws_db_instance.this.identifier
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret holding {username, password}."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "instance_class" {
  value = aws_db_instance.this.instance_class
}

output "multi_az" {
  value = aws_db_instance.this.multi_az
}
