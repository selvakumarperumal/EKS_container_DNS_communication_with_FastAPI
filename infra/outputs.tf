output "vpc_id" {
  description = "ID of the VPC created"
  value       = module.vpc.vpc_id
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_arn" {
  description = "ARN of the EKS cluster"
  value       = module.eks.cluster_arn
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider used for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "app_secrets_arn" {
  description = "ARN of the Unified App Secrets in Secret Manager"
  value       = module.secret_manager.app_secrets_arn
}

# --- S3 Outputs ---

output "s3_bucket_name" {
  description = "Name of the S3 bucket created for the application"
  value       = module.s3.bucket_id
}

# --- IRSA Outputs ---

output "irsa_s3_role_arn" {
  description = "IAM Role ARN for Kubernetes ServiceAccount to access S3"
  value       = module.irsa_s3.iam_role_arn
}

# --- ArgoCD Outputs ---

output "argocd_namespace" {
  description = "Namespace where ArgoCD is installed"
  value       = helm_release.argocd.namespace
}

# --- ECR Outputs ---

output "ecr_repository_url" {
  description = "ECR repository URL for the FastAPI image"
  value       = aws_ecr_repository.fastapi.repository_url
}

# --- LB Controller ---

output "lb_controller_role_arn" {
  description = "IAM Role ARN for AWS Load Balancer Controller"
  value       = module.irsa_lb_controller.iam_role_arn
}

# --- External Secrets ---

output "external_secrets_role_arn" {
  description = "IAM Role ARN for External Secrets Operator"
  value       = module.irsa_external_secrets.iam_role_arn
}

