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

variable "create_app_secrets" {
  description = "Whether to create the unified app secrets in Secrets Manager"
  type        = bool
  default     = false
}

variable "api_key" {
  description = "API key for FastAPI application"
  type        = string
  sensitive   = true
  default     = ""
}

variable "db_username" {
  description = "Database username"
  type        = string
  default     = ""
}

variable "db_password" {
  description = "Database password"
  type        = string
  sensitive   = true
  default     = ""
}


