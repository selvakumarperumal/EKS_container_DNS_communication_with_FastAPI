output "iam_role_arn" {
  description = "ARN of the IRSA IAM Role"
  value       = aws_iam_role.this.arn
}

output "iam_role_name" {
  description = "Name of the IRSA IAM Role"
  value       = aws_iam_role.this.name
}
