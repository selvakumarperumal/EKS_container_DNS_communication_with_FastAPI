terraform {
  required_version = ">= 1.14.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# =============================================================================
# IAM ROLES FOR SERVICE ACCOUNTS (IRSA) MODULE
# =============================================================================
# This module creates a generic IAM role mapped natively to an EKS Service
# Account via AWS OIDC integration.
# =============================================================================

# Trust policy ensuring the role can ONLY be assumed by the specified 
# Kubernetes service account in the specified EKS cluster.
data "aws_iam_policy_document" "irsa_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.kubernetes_namespace}:${var.kubernetes_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# The IAM Role assumed by the Kubernetes pod
resource "aws_iam_role" "this" {
  name_prefix        = "${var.role_name}-"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust.json
  tags               = merge(var.tags, { Name = var.role_name })
}

# Attach any AWS Managed Policies or pre-created Policy ARNs
resource "aws_iam_role_policy_attachment" "managed" {
  count      = length(var.policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = var.policy_arns[count.index]
}

# Attach any Inline Policies specified as JSON strings
resource "aws_iam_role_policy" "inline" {
  for_each = var.inline_policies

  name   = each.key
  role   = aws_iam_role.this.name
  policy = each.value
}
