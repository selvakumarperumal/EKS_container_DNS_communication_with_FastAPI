###############################################################################
# SECRETS MANAGER MODULE — OUTPUTS
# =============================================================================
# These outputs expose resource attributes for use by other modules.
# All outputs are conditional — they return null when the corresponding
# secret is not created.
###############################################################################

# --- KMS Key Outputs ---

output "kms_key_arn" {
  description = "ARN of the KMS key used for secrets encryption"
  value       = var.create_app_secrets ? aws_kms_key.secrets[0].arn : null
}

output "kms_key_id" {
  description = "ID of the KMS key used for secrets encryption"
  value       = var.create_app_secrets ? aws_kms_key.secrets[0].key_id : null
}

# --- Unified App Secrets Outputs ---

output "app_secrets_arn" {
  description = "ARN of the Unified App Secrets"
  value       = var.create_app_secrets ? aws_secretsmanager_secret.app_secrets[0].arn : null
}

output "app_secrets_name" {
  description = "Name of the Unified App Secrets"
  value       = var.create_app_secrets ? aws_secretsmanager_secret.app_secrets[0].name : null
}

# --- IAM Policy Outputs ---

output "read_secrets_policy_arn" {
  description = "ARN of the IAM policy that grants read access to the secrets"
  value       = var.create_app_secrets ? aws_iam_policy.read_secrets[0].arn : null
}
