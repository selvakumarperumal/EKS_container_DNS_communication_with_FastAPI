variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
}



variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
}

variable "azs" {
  description = "Availability zones"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs"
  type        = list(string)
}

variable "service_ipv4_cidr_block" {
  description = "CIDR block for Kubernetes services"
  type        = string
}

variable "enable_nat_gateway" {
  description = "Enable NAT gateway for private subnets"
  type        = bool
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway to save costs"
  type        = bool
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs"
  type        = bool
}

variable "flow_logs_retention_in_days" {
  description = "Retention period for flow logs in days"
  type        = number
}

# --- App Secrets Config ---

variable "create_app_secrets" {
  description = "Whether to create a unified secret in Secrets Manager for FastAPI"
  type        = bool
}

variable "api_key" {
  description = "API Key value"
  type        = string
  sensitive   = true
  default     = ""
}

variable "db_username" {
  description = "Database username for cloud-native DB"
  type        = string
  default     = ""
}

variable "db_password" {
  description = "Database password for cloud-native DB"
  type        = string
  sensitive   = true
  default     = ""
}

variable "tags" {
  description = "Global tags to apply to all resources"
  type        = map(string)
}

# --- Kubernetes App Config (For IAM IRSA) ---

variable "app_namespace" {
  description = "Kubernetes namespace where the application will run"
  type        = string
}

variable "app_service_account" {
  description = "Kubernetes service account name for the application"
  type        = string
}

# --- ArgoCD Config ---

variable "argocd_repo_url" {
  description = "Git repository URL for ArgoCD to watch"
  type        = string
}

variable "argocd_target_revision" {
  description = "Git branch/tag for ArgoCD to track"
  type        = string
  default     = "HEAD"
}

# --- Ingress / ALB / TLS ---

variable "domain_name" {
  description = "Domain name for the application (e.g. api.example.com)"
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "ARN of the ACM certificate for TLS termination on ALB"
  type        = string
  default     = ""
}

variable "waf_acl_arn" {
  description = "ARN of the WAFv2 WebACL to associate with the ALB"
  type        = string
  default     = ""
}

# --- Observability ---

variable "grafana_admin_password" {
  description = "Admin password for Grafana dashboard"
  type        = string
  sensitive   = true
  default     = "admin"
}
