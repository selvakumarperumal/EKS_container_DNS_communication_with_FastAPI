terraform {
  required_version = ">= 1.14.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

###############################################################################
# SECRETS MANAGER MODULE — MAIN CONFIGURATION
# =============================================================================
# This module creates AWS Secrets Manager resources for securely storing
# sensitive data like API keys.
#
# WHAT IS AWS SECRETS MANAGER?
# ────────────────────────────────────────────────────────────────────────
# Secrets Manager is a managed service that stores, rotates, and retrieves
# secrets (passwords, API keys, tokens). Key benefits over hardcoding:
#   - Secrets are encrypted at rest with KMS
#   - Access is controlled by IAM policies
#   - Automatic rotation is supported
#   - Audit trail via CloudTrail
#   - No secrets in source code or environment variables
#
# HOW PODS ACCESS THESE SECRETS:
# ────────────────────────────────────────────────────────────────────────
# Option 1: External Secrets Operator (K8s controller syncs to K8s Secrets)
# Option 2: CSI Secrets Store Driver (mounts secrets as files in pods)
# Option 3: AWS SDK in application code (directly calls Secrets Manager API)
#
# All options use IRSA (from the EKS module) for secure IAM authentication.
#
# CONDITIONAL CREATION:
# ────────────────────────────────────────────────────────────────────────
# The secret is created ONLY if its corresponding flag is true:
#   create_api_secret → API key
#
# count = var.create_api_secret ? 1 : 0
#   → count = 1: resource IS created
#   → count = 0: resource is NOT created (skipped entirely)
###############################################################################


# =============================================================================
# KMS KEY FOR SECRETS ENCRYPTION
# =============================================================================
# A DEDICATED KMS key for encrypting secrets in Secrets Manager.
# This is SEPARATE from the EKS KMS key because:
#   1. Different services should use different keys (key separation)
#   2. Different access policies may be needed
#   3. Key rotation schedules might differ
#   4. If one key is compromised, the other secrets are still safe
#
# CONDITIONAL: Only created if the API secret is enabled.
# =============================================================================
resource "aws_kms_key" "secrets" {
  count                   = var.create_app_secrets ? 1 : 0
  description             = "KMS key for Secrets Manager encryption"
  deletion_window_in_days = 7    # 7-day grace period before permanent deletion
  enable_key_rotation     = true # Auto-rotate key material annually

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-secrets-kms"
    }
  )
}

# Human-friendly alias for the KMS key
resource "aws_kms_alias" "secrets" {
  count         = var.create_app_secrets ? 1 : 0
  name          = "alias/${var.name_prefix}-secrets"
  target_key_id = aws_kms_key.secrets[0].key_id # [0] because it's a count resource
}


# =============================================================================
# SECRET: UNIFIED APP SECRETS
# =============================================================================
# Stores the unified API keys and DB credentials for the external service integration
# =============================================================================
resource "aws_secretsmanager_secret" "app_secrets" {
  count                   = var.create_app_secrets ? 1 : 0
  name                    = "${var.name_prefix}-app-secrets"
  description             = "Unified Application Secrets for ${var.name_prefix}"
  kms_key_id              = aws_kms_key.secrets[0].arn
  recovery_window_in_days = 7

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-app-secrets"
      Type = "secrets"
    }
  )
}

resource "aws_secretsmanager_secret_version" "app_secrets" {
  count     = var.create_app_secrets ? 1 : 0
  secret_id = aws_secretsmanager_secret.app_secrets[0].id
  secret_string = jsonencode({
    api_key     = var.api_key
    db_username = var.db_username
    db_password = var.db_password
  })
}




# =============================================================================
# IAM POLICY — LEAST-PRIVILEGE SECRET READING
# =============================================================================
# This IAM policy grants READ-ONLY access to the secrets we created.
# It follows the principle of least privilege:
#   ✅ GetSecretValue   — Read the actual secret value
#   ✅ DescribeSecret   — Get secret metadata (name, ARN, etc.)
#   ❌ PutSecretValue   — Cannot modify secrets
#   ❌ DeleteSecret     — Cannot delete secrets
#   ❌ CreateSecret     — Cannot create new secrets
#
# The policy also grants KMS decrypt permissions because the secrets
# are encrypted with our custom KMS key. Without KMS access, even with
# Secrets Manager permissions, the secret value can't be decrypted.
#
# USAGE: Attach this policy to IRSA roles for pods that need secret access.
# Example:
#   1. Create an IAM role with this policy attached
#   2. Annotate a K8s ServiceAccount with the role ARN
#   3. Pods using that ServiceAccount can read the secrets
# =============================================================================
resource "aws_iam_policy" "read_secrets" {
  count       = var.create_app_secrets ? 1 : 0
  name_prefix = "${var.name_prefix}-read-secrets-"
  description = "Allow reading secrets from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue", # Read the secret value
          "secretsmanager:DescribeSecret"  # Get secret metadata
        ]
        # Resource: Only the specific secrets we created (not ALL secrets!)
        Resource = compact([
          var.create_app_secrets ? aws_secretsmanager_secret.app_secrets[0].arn : ""
        ])
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",    # Decrypt the secret value
          "kms:DescribeKey" # Get KMS key metadata
        ]
        Resource = [aws_kms_key.secrets[0].arn] # Only our KMS key
      }
    ]
  })

  tags = var.tags
}
