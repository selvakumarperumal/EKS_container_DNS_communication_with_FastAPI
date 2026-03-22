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
  value       = var.create_api_secret ? aws_kms_key.secrets[0].arn : null
}

output "kms_key_id" {
  description = "ID of the KMS key used for secrets encryption"
  value       = var.create_api_secret ? aws_kms_key.secrets[0].key_id : null
}

# --- API Key Secret Outputs ---

output "api_key_secret_arn" {
  description = "ARN of the API key secret"
  value       = var.create_api_secret ? aws_secretsmanager_secret.api_keys[0].arn : null
}

output "api_key_secret_name" {
  description = "Name of the API key secret"
  value       = var.create_api_secret ? aws_secretsmanager_secret.api_keys[0].name : null
}

# --- IAM Policy Outputs ---

output "read_secrets_policy_arn" {
  description = "ARN of the IAM policy that grants read access to the secrets"
  value       = var.create_api_secret ? aws_iam_policy.read_secrets[0].arn : null
}
