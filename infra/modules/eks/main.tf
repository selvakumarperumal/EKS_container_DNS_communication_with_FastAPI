resource "aws_kms_key" "eks_kms_key" {
  description             = "KMS key for EKS cluster"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  tags                    = merge(var.tags, { Name = "${var.cluster_name}-kms-key" })
}

resource "aws_kms_alias" "eks_kms_key_alias" {
  name          = "alias/eks/${var.cluster_name}"
  target_key_id = aws_kms_key.eks_kms_key.key_id
}

resource "aws_cloudwatch_log_group" "eks_cluster_log_group" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.eks_kms_key.key_id

  tags = merge(var.tags, { Name = "${var.cluster_name}-cluster-log-group" })
}

resource "aws_security_group" "cluster" {
  name_prefix = "${var.cluster_name}-cluster-sg-"
  description = "Security group for EKS cluster"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-cluster-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "node" {
  name_prefix = "${var.cluster_name}-node-sg-"
  description = "Security group for EKS worker nodes"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(
    var.tags,
    {
      Name                                        = "${var.cluster_name}-node-sg"
      # ──────────────────────────────────────────────────────────────────────────
      # kubernetes.io/cluster/<cluster-name> = "owned"
      #
      # This is a well-known tag required by the AWS Load Balancer Controller
      # (and the legacy in-tree Kubernetes cloud provider) to discover which
      # AWS resources (subnets, security groups, etc.) belong to a specific
      # EKS cluster.
      #
      # HOW IT WORKS:
      #   When a Kubernetes Service (type: LoadBalancer) or Ingress is created,
      #   the Load Balancer Controller queries the AWS API for resources tagged
      #   with "kubernetes.io/cluster/<cluster-name>". It uses the matching
      #   security groups to:
      #     1. Attach them to ALB/NLB targets so traffic can reach the pods.
      #     2. Create or update ingress rules on the node security group to
      #        allow health-check and data traffic from the load balancer.
      #
      # TAG VALUE — "owned" vs "shared":
      #   "owned"  → This resource is exclusively dedicated to this cluster.
      #              The controller may freely manage / modify rules on it.
      #   "shared" → This resource is shared across multiple clusters or
      #              workloads. The controller will use it but avoid modifying it.
      #
      # WITHOUT THIS TAG:
      #   The Load Balancer Controller cannot discover this security group,
      #   which causes load balancer provisioning to fail or target
      #   registration / health checks to break.
      # ──────────────────────────────────────────────────────────────────────────
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

