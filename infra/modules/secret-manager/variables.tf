###############################################################################
# SECRETS MANAGER MODULE — INPUT VARIABLES
# =============================================================================
# These variables control the behavior of the Secrets Manager module.
# Variables with 'sensitive = true' are masked in Terraform output/logs.
###############################################################################

variable "name_prefix" {
  description = "Prefix for resource names (typically the cluster name)"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Conditional Flags
# -----------------------------------------------------------------------------
# These flags control whether specific secrets are created.
# Set to 'true' to create the secret, 'false' to skip it entirely.
# -----------------------------------------------------------------------------

variable "create_api_secret" {
  description = "Whether to create the API key secret in Secrets Manager"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Sensitive Values
# -----------------------------------------------------------------------------
# These values are stored in Secrets Manager. They are marked as sensitive
# so Terraform won't display them in plan/apply output.
#
# Default is "" so callers don't need to provide values when the
# corresponding create_*_secret flag is false.
# -----------------------------------------------------------------------------

variable "api_key" {
  description = "API key for FastAPI application"
  type        = string
  sensitive   = true
  default     = ""
}
