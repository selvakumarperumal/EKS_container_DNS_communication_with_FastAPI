variable "name_prefix" {
  description = "Prefix for the resources (typically the cluster name)"
  type        = string
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC (e.g., '10.0.0.0/16')"
}

variable "azs" {
  type        = list(string)
  description = "Availability Zones for the VPC"
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "List of CIDR blocks for the public subnets"
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "List of CIDR blocks for the private subnets"
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Enable NAT Gateway"
}

variable "single_nat_gateway" {
  type        = bool
  description = "Enable Single NAT Gateway"
}

variable "public_subnet_tags" {
  type        = map(string)
  description = "Additional tags for public subnets"
}

variable "private_subnet_tags" {
  type        = map(string)
  description = "Additional tags for private subnets"
}

variable "enable_flow_logs" {
  type        = bool
  description = "Enable VPC Flow Logs to Cloudwatch"
}

variable "flow_logs_retention_in_days" {
  type        = number
  description = "Retention period for flow logs in days"
}

variable "tags" {
  type        = map(string)
  description = "Tags for the VPC"
}
