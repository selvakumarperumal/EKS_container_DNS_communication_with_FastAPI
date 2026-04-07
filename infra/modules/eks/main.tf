terraform {
  required_version = ">= 1.14.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

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
  kms_key_id        = aws_kms_key.eks_kms_key.arn

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
      Name = "${var.cluster_name}-node-sg"
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

resource "aws_security_group_rule" "node_to_cluster" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.node.id
  description              = "Allow Node to communicate with Cluster API"
}

resource "aws_security_group_rule" "cluster_to_node" {
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.node.id
  source_security_group_id = aws_security_group.cluster.id
  description              = "Allow Cluster control plane to communicate with Nodes"
}


resource "aws_security_group_rule" "node_to_node" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  security_group_id = aws_security_group.node.id
  self              = true
  description       = "Allow Node to communicate with itself"
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = var.cluster_role_arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  kubernetes_network_config {
    service_ipv4_cidr = var.service_ipv4_cidr_block
    ip_family         = "ipv4"
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_kms_key.arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = var.enable_cluster_logging ? ["api", "audit", "authenticator", "controllerManager", "scheduler"] : []

  depends_on = [aws_cloudwatch_log_group.eks_cluster_log_group]
  tags       = merge(var.tags, { Name = var.cluster_name })
}

data "tls_certificate" "cluster" {
  count = var.enable_irsa ? 1 : 0
  url   = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks_oidc_provider" {
  count           = var.enable_irsa ? 1 : 0
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster[0].certificates[0].sha1_fingerprint]

  tags = merge(var.tags, { Name = "${var.cluster_name}-oidc-provider" })
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  addon_version               = var.core_dns_version != "" ? var.core_dns_version : null
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]

  tags = merge(var.tags, { Name = "${var.cluster_name}-coredns" })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = var.kube_proxy_version != "" ? var.kube_proxy_version : null
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(var.tags, { Name = "${var.cluster_name}-kube-proxy" })
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = var.vpc_cni_version != "" ? var.vpc_cni_version : null
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  service_account_role_arn = var.vpc_cni_role_arn != "" ? var.vpc_cni_role_arn : var.node_group_role_arn

  tags = merge(var.tags, { Name = "${var.cluster_name}-vpc-cni" })
}

resource "aws_launch_template" "eks_node_launch_template" {
  for_each = var.node_groups

  name_prefix            = "${var.cluster_name}-${each.key}-"
  description            = "Launch template for EKS node group ${each.key}"
  update_default_version = true
  ebs_optimized          = true

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
      encrypted             = true
    }
  }

  # ════════════════════════════════════════════════════════════════════════════
  # INSTANCE METADATA SERVICE (IMDS) CONFIGURATION
  # ════════════════════════════════════════════════════════════════════════════
  #
  # This block configures the Instance Metadata Service (IMDS) — a local
  # endpoint (http://169.254.169.254) that EC2 instances use to access
  # information about themselves (IAM role credentials, instance ID, region,
  # tags, etc.).
  #
  # ── HOW IT WORKS IN EKS ──
  #
  #   Pod (your app)
  #     └──▸ Node (EC2 instance)
  #            └──▸ 169.254.169.254 (IMDS endpoint)
  #                   └──▸ Returns: IAM role, region, instance-id, tags...
  #
  # ── IMDS vs IRSA (IAM Roles for Service Accounts) ──
  #
  #   IRSA does NOT use IMDS for credentials. Instead it works like this:
  #
  #     Pod
  #       ├─ Projected Service Account Token (JWT)
  #       │    mounted at: /var/run/secrets/eks.amazonaws.com/serviceaccount/token
  #       └─ AWS SDK sees AWS_WEB_IDENTITY_TOKEN_FILE env var
  #            └──▸ Calls STS directly (sts.amazonaws.com/AssumeRoleWithWebIdentity)
  #                   └──▸ Returns temporary credentials ✅
  #
  #   However, IMDS is still needed for OTHER things even with IRSA:
  #
  #     ┌──────────────────────┬──────────────┬──────────────┐
  #     │ What                 │ IMDS needed? │ IRSA covers? │
  #     ├──────────────────────┼──────────────┼──────────────┤
  #     │ IAM credentials      │ ❌ No        │ ✅ Yes       │
  #     │ AWS Region discovery │ ✅ Yes       │ ❌ No        │
  #     │ Instance ID          │ ✅ Yes       │ ❌ No        │
  #     │ Availability Zone    │ ✅ Yes       │ ❌ No        │
  #     │ Instance tags        │ ✅ Yes       │ ❌ No        │
  #     └──────────────────────┴──────────────┴──────────────┘
  #
  #   If IMDS is disabled, you must manually inject region etc. via env vars
  #   in every pod spec — extra operational overhead for little benefit when
  #   IRSA is already securing the credentials.
  # ════════════════════════════════════════════════════════════════════════════
  metadata_options {

    # ── http_endpoint ──
    # Turns on the metadata service itself.
    #   • If "disabled", the instance cannot query its own metadata at all.
    #   • Applications, SDKs, and the AWS CLI running on the instance rely on
    #     this endpoint to auto-discover credentials, region, and config.
    #   • Almost always kept "enabled" unless you have a strict security reason
    #     to block it entirely.
    #
    # EKS Pod Example (enabled):
    #   AWS SDK automatically calls IMDS:
    #     GET http://169.254.169.254/latest/meta-data/placement/region
    #     → Returns: "ap-south-1"    ✅ Region auto-discovered
    #
    # EKS Pod Example (disabled):
    #   SDK tries the same call → ❌ FAILS
    #   → NoRegionError unless AWS_REGION env var is manually set
    http_endpoint = "enabled"

    # ── http_tokens ──
    # Enforces IMDSv2 (the newer, secure version) — blocks IMDSv1 completely.
    # This is the MOST SECURITY-CRITICAL line.
    #
    #   ┌─────────────────────┬──────────────────────────────────────────┐
    #   │ IMDSv1 (old)        │ IMDSv2 (enforced here)                  │
    #   ├─────────────────────┼──────────────────────────────────────────┤
    #   │ Simple GET, no auth │ Requires a session token first          │
    #   │ SSRF risk: HIGH     │ Protected — attacker can't get token    │
    #   │ No token needed     │ Must PUT to get token, then use it      │
    #   └─────────────────────┴──────────────────────────────────────────┘
    #
    # When "required", the instance must first call:
    #   PUT http://169.254.169.254/latest/api/token
    # to get a token, then use that token in subsequent metadata requests.
    #
    # This alone prevents a whole class of credential-theft attacks (SSRF)
    # that have affected real-world cloud breaches.
    http_tokens = "required"

    # ── http_put_response_hop_limit ──
    # Controls how many network hops the metadata token response can travel.
    #   • The IMDSv2 token response has a TTL on the IP packet.
    #   • 1 = token stays on the EC2 host itself (fine for plain VMs).
    #   • 2 = token can pass through one additional network layer — needed
    #         when containers run on the instance (Docker, ECS, Kubernetes),
    #         because the packet travels:
    #           container → host → metadata service
    #   • Setting it to 2 here indicates this template is designed for
    #     containerized workloads (EKS).
    #   • Never set this unnecessarily high (e.g. 64) as it increases
    #     SSRF exposure.
    http_put_response_hop_limit = 2

    # ── instance_metadata_tags ──
    # Lets the instance read its own EC2 tags via the metadata endpoint.
    #   • Without this, you'd need IAM permissions + an API call
    #     (ec2:DescribeTags) to fetch tags.
    #   • With this enabled, any process on the instance can simply call:
    #       GET http://169.254.169.254/latest/meta-data/tags/instance/<TagKey>
    #   • Useful for self-identification — e.g., an app reads its own
    #     Environment=prod or Team=payments tag at startup without needing
    #     extra IAM permissions.
    #
    # EKS Pod Example:
    #   response = requests.get(
    #       "http://169.254.169.254/latest/meta-data/tags/instance/Environment",
    #       headers={"X-aws-ec2-metadata-token": token}  # IMDSv2 token
    #   )
    #   env = response.text  # Returns: "production"
    instance_metadata_tags = "enabled"
  }

  vpc_security_group_ids = [aws_security_group.node.id]

  monitoring {
    enabled = var.enable_detailed_monitoring
  }

  private_dns_name_options {
    hostname_type = "resource-name"
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      var.tags,
      {
        Name = "${var.cluster_name}-${each.key}-node"
      }
    )
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(
      var.tags,
      {
        Name = "${var.cluster_name}-${each.key}-volume"
      }
    )
  }
}

resource "aws_eks_node_group" "main" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-${each.key}-node"
  node_role_arn   = var.node_group_role_arn
  subnet_ids      = each.value.subnet_ids
  version         = var.kubernetes_version

  scaling_config {
    desired_size = each.value.desired_size
    max_size     = each.value.max_size
    min_size     = each.value.min_size
  }

  instance_types = each.value.instance_types

  capacity_type = each.value.capacity_type

  labels = lookup(each.value, "labels", {})

  dynamic "taint" {
    for_each = coalesce(each.value.taints, [])

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  launch_template {
    id      = aws_launch_template.eks_node_launch_template[each.key].id
    version = aws_launch_template.eks_node_launch_template[each.key].latest_version
  }

  tags = merge(
    var.tags,
    lookup(each.value, "tags", {})
  )

  depends_on = [
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy
  ]

  # ════════════════════════════════════════════════════════════════════════════
  # LIFECYCLE — IGNORE desired_size AFTER INITIAL CREATION
  # ════════════════════════════════════════════════════════════════════════════
  #
  # Tells Terraform:
  #   "After initial creation, NEVER touch desired_size again — even if the
  #    actual value differs from what's written in the .tf config."
  #
  # ── WHY THIS IS NEEDED — THE PROBLEM ──
  #
  #   Terraform config says:    desired_size = 2
  #
  #   Day 1:  Terraform creates node group → 2 nodes ✅
  #
  #   Day 2:  Cluster Autoscaler (CA) scales up → 5 nodes
  #           (high traffic, CA added 3 nodes automatically)
  #
  #   Day 3:  You run `terraform apply`
  #           Terraform sees:
  #             config = 2  (what you wrote in .tf file)
  #             actual = 5  (what CA scaled to)
  #
  #           WITHOUT ignore_changes:
  #           💥 Terraform resets nodes back to 2
  #              CA's work is DESTROYED — workloads disrupted!
  #
  # ── WITH ignore_changes — THE SOLUTION ──
  #
  #   Day 1:  Terraform creates node group → desired_size = 2   ✅
  #   Day 2:  Cluster Autoscaler scales up → 5 nodes
  #   Day 3:  terraform apply
  #           Terraform sees desired_size changed 2 → 5
  #           BUT ignore_changes says "don't touch it"
  #
  #           ✅ Terraform skips desired_size
  #           ✅ CA's 5 nodes stay untouched
  #           ✅ No disruption to your workloads
  #
  # ── WHAT scaling_config[0] MEANS ──
  #
  #   scaling_config[0].desired_size
  #                  ↑
  #                  index 0 = first (and only) scaling_config block
  #
  # ── WHAT IS IGNORED vs WHAT IS NOT ──
  #
  #   scaling_config {
  #     desired_size = 2    ← ❌ Terraform IGNORES changes to this
  #     min_size     = 1    ← ✅ Terraform STILL manages this
  #     max_size     = 10   ← ✅ Terraform STILL manages this
  #   }
  #
  #   Cluster Autoscaler owns → desired_size  (runtime value)
  #   Terraform owns          → min_size      (your boundary config)
  #                           → max_size      (your boundary config)
  #
  # ── REAL WORLD FLOW ──
  #
  #   ┌─────────────────────────────────────┐
  #   │  terraform apply (Day 1)            │
  #   │  desired_size = 2 created           │
  #   └──────────────┬──────────────────────┘
  #                  │
  #                  ▼
  #   ┌─────────────────────────────────────┐
  #   │  Cluster Autoscaler                 │
  #   │  scales 2 → 5 (high load)          │
  #   │  scales 5 → 3 (load drops)         │
  #   └──────────────┬──────────────────────┘
  #                  │
  #                  ▼
  #   ┌─────────────────────────────────────┐
  #   │  terraform apply (Day 10)           │
  #   │  desired_size → IGNORED        ✅  │
  #   │  min/max     → still managed   ✅  │
  #   └─────────────────────────────────────┘
  #
  # RULE OF THUMB:
  #   → Terraform manages BOUNDARIES   (min / max)
  #   → CA manages CURRENT COUNT       (desired)
  #
  # ── DOES ignore_changes BLOCK terraform destroy? ──
  #
  #   NO — destroy works perfectly fine. ✅
  #   ignore_changes ONLY affects UPDATE/APPLY behaviour.
  #   It does NOT say anything about destroy — destroy is a completely
  #   separate operation.
  #
  #   What each lifecycle argument controls:
  #
  #     lifecycle {
  #       ignore_changes        → controls UPDATE behaviour
  #       prevent_destroy       → controls DESTROY behaviour  ← blocks destroy
  #       create_before_destroy → controls REPLACE behaviour
  #     }
  #
  #   With your current config:
  #
  #     terraform apply   → desired_size changes ignored   ✅
  #     terraform destroy → works perfectly fine           ✅
  #
  #   Only prevent_destroy = true would block destroy:
  #
  #     lifecycle {
  #       prevent_destroy = true
  #     }
  #     # terraform destroy → 💥 ERROR: Instance cannot be destroyed
  #
  #   ignore_changes and destroy have NO relationship — destroy always
  #   works unless you explicitly set prevent_destroy = true.
  # ════════════════════════════════════════════════════════════════════════════
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}
