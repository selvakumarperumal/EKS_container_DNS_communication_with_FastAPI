variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the cluster will be deployed"
  type        = string
}

variable "service_ipv4_cidr_block" {
  description = "CIDR block for the kubernetes services cluster ips"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the EKS cluster"
  type        = list(string)
}

variable "cluster_role_arn" {
  description = "ARN of the cluster role"
  type        = string
}

variable "node_group_role_arn" {
  description = "ARN of the node group role"
  type        = string
}

variable "endpoint_public_access" {
  description = "Enable public access to the EKS cluster endpoint"
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "Enable private access to the EKS cluster endpoint"
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "List of CIDR blocks to allow public access to the EKS cluster endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_groups" {
  description = "Map of node group configurations"
  type = map(object({
    instance_types = list(string)
    min_size       = number
    max_size       = number
    desired_size   = number
    subnet_ids     = list(string)
    capacity_type  = optional(string)
    disk_size      = optional(number)
    labels         = optional(map(string))

    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })))

    tags                 = optional(map(string))
    additional_user_data = optional(string)

  }))

}

variable "core_dns_version" {
  description = "Version of the core dns (leave empty for AWS default)"
  type        = string
  default     = ""
}

variable "kube_proxy_version" {
  description = "Version of the kube proxy (leave empty for AWS default)"
  type        = string
  default     = ""
}

variable "vpc_cni_version" {
  description = "Version of the vpc cni (leave empty for AWS default)"
  type        = string
  default     = ""
}

variable "vpc_cni_role_arn" {
  description = "IAM role arn for vpc cni addon (empty = use node_group_role_arn)"
  type        = string
  default     = ""
}

variable "enable_irsa" {
  description = "Enable IRSA (IAM Roles for Service Accounts)"
  type        = bool
  default     = true
}

variable "enable_cluster_logging" {
  description = "Enable cluster logging"
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Number of days to retain cluster logs"
  type        = number
  default     = 30
}

variable "enable_detailed_monitoring" {
  description = "Enable detailed (1 minute interval) monitoring for the cluster"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

