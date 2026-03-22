variable "cluster_name" {
  description = "Name of the cluster (Used as prefix for IAM roles)"
  type        = string
}

variable "tags" {
  description = "tags to apply to all iam resources"
  type        = map(string)
  default     = {}
}
