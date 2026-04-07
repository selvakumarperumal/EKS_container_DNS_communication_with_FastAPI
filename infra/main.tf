terraform {
  required_version = ">= 1.14.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ------------------------------------------------------------------------------
# KUBERNETES & HELM PROVIDERS (authenticated via EKS)
# ------------------------------------------------------------------------------
data "aws_eks_cluster_auth" "main" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.main.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

# ------------------------------------------------------------------------------
# VPC MODULE
# ------------------------------------------------------------------------------
module "vpc" {
  source = "./modules/vpc"

  name_prefix                 = "${var.cluster_name}-net"
  vpc_cidr                    = var.vpc_cidr
  azs                         = var.azs
  public_subnet_cidrs         = var.public_subnet_cidrs
  private_subnet_cidrs        = var.private_subnet_cidrs
  enable_nat_gateway          = var.enable_nat_gateway
  single_nat_gateway          = var.single_nat_gateway
  enable_flow_logs            = var.enable_flow_logs
  flow_logs_retention_in_days = var.flow_logs_retention_in_days

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = var.tags
}

# ------------------------------------------------------------------------------
# IAM MODULE
# ------------------------------------------------------------------------------
module "iam" {
  source = "./modules/iam"

  cluster_name = var.cluster_name
  tags         = var.tags
}

# ------------------------------------------------------------------------------
# SECRET MANAGER MODULE
# ------------------------------------------------------------------------------
module "secret_manager" {
  source = "./modules/secret-manager"

  name_prefix        = var.cluster_name
  create_app_secrets = var.create_app_secrets
  api_key            = var.api_key
  db_username        = var.db_username
  db_password        = var.db_password

  tags = var.tags
}

# ------------------------------------------------------------------------------
# EKS MODULE
# ------------------------------------------------------------------------------
module "eks" {
  source = "./modules/eks"

  cluster_name            = var.cluster_name
  kubernetes_version      = var.kubernetes_version
  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = module.vpc.private_subnet_ids
  service_ipv4_cidr_block = var.service_ipv4_cidr_block

  cluster_role_arn    = module.iam.cluster_role_arn
  node_group_role_arn = module.iam.node_role_arn

  endpoint_public_access  = true
  endpoint_private_access = true
  public_access_cidrs     = ["0.0.0.0/0"]

  enable_irsa                = true
  enable_cluster_logging     = false
  enable_detailed_monitoring = false

  # CoreDNS, VPC CNI, Kube Proxy versions: defaults are "" (AWS auto-selects).
  # In production, pin specific versions via the module variables.

  node_groups = {
    "on-demand" = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 3
      desired_size   = 2
      subnet_ids     = module.vpc.private_subnet_ids
      capacity_type  = "ON_DEMAND"
      labels = {
        workload = "fastapi"
      }
    }

    # Dedicated nodes for CloudNativePG — spread across all 3 AZs.
    # Tainted so only postgres pods schedule here.
    "postgres" = {
      instance_types = ["r6g.large"]
      min_size       = 3
      max_size       = 6
      desired_size   = 3
      subnet_ids     = module.vpc.private_subnet_ids
      capacity_type  = "ON_DEMAND"
      labels = {
        role = "postgres"
      }
      taints = [
        {
          key    = "dedicated"
          value  = "postgres"
          effect = "NO_SCHEDULE"
        }
      ]
    }
  }

  tags = var.tags
}

# ------------------------------------------------------------------------------
# S3 MODULE
# ------------------------------------------------------------------------------
module "s3" {
  source = "./modules/s3"

  bucket_prefix     = var.cluster_name
  enable_versioning = true
  tags              = var.tags
}

# ------------------------------------------------------------------------------
# IRSA FOR S3
# ------------------------------------------------------------------------------
module "irsa_s3" {
  source = "./modules/irsa"

  role_name                  = "${var.cluster_name}-fastapi-s3"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  oidc_issuer_url            = module.eks.cluster_oidc_issuer_url
  kubernetes_namespace       = var.app_namespace
  kubernetes_service_account = var.app_service_account

  # Attach the Secrets Manager read policy (created by secret-manager module)
  policy_arns = compact([module.secret_manager.read_secrets_policy_arn])

  inline_policies = {
    s3_access = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action = [
            "s3:PutObject",
            "s3:GetObject",
            "s3:DeleteObject",
            "s3:ListBucket"
          ]
          Effect = "Allow"
          Resource = [
            module.s3.bucket_arn,
            "${module.s3.bucket_arn}/*"
          ]
        }
      ]
    })
  }

  tags = var.tags
}
