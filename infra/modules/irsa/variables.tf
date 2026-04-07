variable "role_name" {
  description = "Prefix name of the IAM Role"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC Provider"
  type        = string
}

variable "oidc_issuer_url" {
  description = "URL of the EKS OIDC Issuer"
  type        = string
}

variable "kubernetes_namespace" {
  description = "Kubernetes namespace of the Service Account"
  type        = string
  default     = "default"
}

variable "kubernetes_service_account" {
  description = "Name of the Kubernetes Service Account"
  type        = string
}

variable "policy_arns" {
  description = "List of IAM Policy ARNs to attach to the role"
  type        = list(string)
  default     = []
}

variable "inline_policies" {
  description = "Map of inline policies to attach. Key is policy name, value is policy JSON"
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags to apply to the IAM Role"
  type        = map(string)
  default     = {}
}
