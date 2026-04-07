# ==============================================================================
# CLUSTER ADDONS — Production-Ready EKS Platform
# ==============================================================================
# This file installs all cluster-level operators and tools via Helm/EKS addons.
# Order matters — dependencies are enforced with depends_on.
#
# Install order:
#   1. EBS CSI Driver       (storage for CNPG volumes)
#   2. Metrics Server       (required by HPA)
#   3. Cluster Autoscaler   (node-level scaling)
#   4. AWS LB Controller    (ALB ingress)
#   5. Istio                (service mesh + mTLS)
#   6. CNPG Operator        (PostgreSQL)
#   7. Redis                (caching layer)
#   8. External Secrets Op  (Secrets Manager → K8s secrets)
#   9. Kyverno              (policy engine)
#  10. Prometheus stack      (metrics + Grafana)
#  11. Loki                  (logs)
#  12. Tempo                 (traces)
#  13. ArgoCD                (GitOps CD)
#  14. ArgoCD Apps           (App-of-Apps bootstrap)
# ==============================================================================

# ==============================================================================
# 1. EBS CSI DRIVER
# ==============================================================================
module "irsa_ebs_csi" {
  source = "./modules/irsa"

  role_name                  = "${var.cluster_name}-ebs-csi"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  oidc_issuer_url            = module.eks.cluster_oidc_issuer_url
  kubernetes_namespace       = "kube-system"
  kubernetes_service_account = "ebs-csi-controller-sa"

  policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]

  tags = var.tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = module.irsa_ebs_csi.iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks]
}

# ==============================================================================
# 2. METRICS SERVER (required for HPA cpu/memory based autoscaling)
# ==============================================================================
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"

  depends_on = [module.eks]
}

# ==============================================================================
# 3. CLUSTER AUTOSCALER (node-level scaling)
# ==============================================================================
module "irsa_cluster_autoscaler" {
  source = "./modules/irsa"

  role_name                  = "${var.cluster_name}-cluster-autoscaler"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  oidc_issuer_url            = module.eks.cluster_oidc_issuer_url
  kubernetes_namespace       = "kube-system"
  kubernetes_service_account = "cluster-autoscaler"

  inline_policies = {
    autoscaler = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "autoscaling:DescribeAutoScalingGroups",
            "autoscaling:DescribeAutoScalingInstances",
            "autoscaling:DescribeLaunchConfigurations",
            "autoscaling:DescribeScalingActivities",
            "autoscaling:DescribeTags",
            "autoscaling:SetDesiredCapacity",
            "autoscaling:TerminateInstanceInAutoScalingGroup",
            "ec2:DescribeImages",
            "ec2:DescribeInstanceTypes",
            "ec2:DescribeLaunchTemplateVersions",
            "ec2:GetInstanceTypesFromInstanceRequirements",
            "eks:DescribeNodegroup"
          ]
          Resource = ["*"]
        }
      ]
    })
  }

  tags = var.tags
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"

  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "awsRegion"
    value = var.aws_region
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_cluster_autoscaler.iam_role_arn
  }

  depends_on = [module.eks]
}

# ==============================================================================
# 4. AWS LOAD BALANCER CONTROLLER (ALB Ingress)
# ==============================================================================
module "irsa_lb_controller" {
  source = "./modules/irsa"

  role_name                  = "${var.cluster_name}-aws-lb-controller"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  oidc_issuer_url            = module.eks.cluster_oidc_issuer_url
  kubernetes_namespace       = "kube-system"
  kubernetes_service_account = "aws-load-balancer-controller"

  policy_arns = [aws_iam_policy.lb_controller.arn]

  tags = var.tags
}

resource "aws_iam_policy" "lb_controller" {
  name_prefix = "${var.cluster_name}-lb-controller-"
  description = "IAM policy for AWS Load Balancer Controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole",
          "ec2:Describe*",
          "ec2:Get*",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:CreateTags",
          "ec2:DeleteTags",
          "elasticloadbalancing:*",
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:GetWebACL",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection"
        ]
        Resource = ["*"]
      }
    ]
  })

  tags = var.tags
}

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_lb_controller.iam_role_arn
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }
  set {
    name  = "region"
    value = var.aws_region
  }

  depends_on = [module.eks]
}

# ==============================================================================
# 5. ISTIO SERVICE MESH (mTLS, traffic shaping, circuit breaking)
# ==============================================================================
resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  namespace        = "istio-system"
  create_namespace = true

  depends_on = [module.eks]
}

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  namespace  = "istio-system"

  set {
    name  = "meshConfig.accessLogFile"
    value = "/dev/stdout"
  }
  set {
    name  = "meshConfig.enableTracing"
    value = "true"
  }
  set {
    name  = "meshConfig.defaultConfig.tracing.zipkin.address"
    value = "tempo.observability.svc:9411"
  }

  depends_on = [helm_release.istio_base]
}

# ==============================================================================
# 6. CLOUDNATIVE-PG OPERATOR
# ==============================================================================
resource "helm_release" "cnpg_operator" {
  name             = "cnpg"
  repository       = "https://cloudnative-pg.github.io/charts"
  chart            = "cloudnative-pg"
  namespace        = "cnpg-system"
  create_namespace = true

  depends_on = [module.eks, aws_eks_addon.ebs_csi]
}

# ==============================================================================
# 7. REDIS (in-cluster caching layer via Bitnami Helm chart)
# ==============================================================================
resource "helm_release" "redis" {
  name             = "redis"
  repository       = "https://charts.bitnami.com/bitnami"
  chart            = "redis"
  namespace        = var.app_namespace
  create_namespace = true

  set {
    name  = "architecture"
    value = "replication"
  }
  set {
    name  = "auth.enabled"
    value = "true"
  }
  set {
    name  = "auth.existingSecret"
    value = "redis-password"
  }
  set {
    name  = "auth.existingSecretPasswordKey"
    value = "password"
  }
  set {
    name  = "replica.replicaCount"
    value = "3"
  }
  set {
    name  = "master.persistence.storageClass"
    value = "gp3-az"
  }
  set {
    name  = "replica.persistence.storageClass"
    value = "gp3-az"
  }

  depends_on = [module.eks, aws_eks_addon.ebs_csi]
}

# ==============================================================================
# 8. EXTERNAL SECRETS OPERATOR (Secrets Manager → K8s secrets)
# ==============================================================================
module "irsa_external_secrets" {
  source = "./modules/irsa"

  role_name                  = "${var.cluster_name}-external-secrets"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  oidc_issuer_url            = module.eks.cluster_oidc_issuer_url
  kubernetes_namespace       = "external-secrets"
  kubernetes_service_account = "external-secrets"

  inline_policies = {
    secrets_access = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret",
            "secretsmanager:ListSecrets"
          ]
          Resource = ["*"]
        },
        {
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:DescribeKey"
          ]
          Resource = ["*"]
        }
      ]
    })
  }

  tags = var.tags
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_external_secrets.iam_role_arn
  }

  depends_on = [module.eks]
}

# ==============================================================================
# 9. KYVERNO (policy engine — enforce best practices)
# ==============================================================================
resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  namespace        = "kyverno"
  create_namespace = true

  depends_on = [module.eks]
}

# ==============================================================================
# 10. PROMETHEUS + GRAFANA (metrics + dashboards)
# ==============================================================================
resource "helm_release" "prometheus_stack" {
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "observability"
  create_namespace = true

  set {
    name  = "grafana.enabled"
    value = "true"
  }
  set {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
  set {
    name  = "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  # --- Grafana ALB Ingress ---
  set {
    name  = "grafana.ingress.enabled"
    value = tostring(var.grafana_domain != "")
  }
  set {
    name  = "grafana.ingress.ingressClassName"
    value = "alb"
  }
  set {
    name  = "grafana.ingress.hosts[0]"
    value = var.grafana_domain
  }
  set {
    name  = "grafana.ingress.annotations.kubernetes\\.io/ingress\\.class"
    value = "alb"
  }
  set {
    name  = "grafana.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/scheme"
    value = "internet-facing"
  }
  set {
    name  = "grafana.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/target-type"
    value = "ip"
  }
  set {
    name  = "grafana.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/listen-ports"
    value = "[{\"HTTPS\":443}]"
  }
  set {
    name  = "grafana.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/ssl-redirect"
    value = "443"
  }
  set {
    name  = "grafana.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/certificate-arn"
    value = var.acm_certificate_arn
  }
  set {
    name  = "grafana.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/healthcheck-path"
    value = "/api/health"
  }

  depends_on = [module.eks, helm_release.aws_lb_controller]
}

# ==============================================================================
# 11. LOKI (centralized logging)
# ==============================================================================
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  namespace  = "observability"

  set {
    name  = "promtail.enabled"
    value = "true"
  }
  set {
    name  = "loki.persistence.enabled"
    value = "true"
  }
  set {
    name  = "loki.persistence.storageClassName"
    value = "gp3-az"
  }

  depends_on = [helm_release.prometheus_stack]
}

# ==============================================================================
# 12. TEMPO (distributed tracing)
# ==============================================================================
resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  namespace  = "observability"

  depends_on = [helm_release.prometheus_stack]
}

# ==============================================================================
# 13. ARGOCD (GitOps continuous deployment)
# ==============================================================================
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true

  # Expose ArgoCD server via ALB (HTTPS)
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }
  set {
    name  = "server.ingress.enabled"
    value = tostring(var.argocd_domain != "")
  }
  set {
    name  = "server.ingress.ingressClassName"
    value = "alb"
  }
  set {
    name  = "server.ingress.hosts[0]"
    value = var.argocd_domain
  }
  set {
    name  = "server.ingress.annotations.kubernetes\\.io/ingress\\.class"
    value = "alb"
  }
  set {
    name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/scheme"
    value = "internet-facing"
  }
  set {
    name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/target-type"
    value = "ip"
  }
  set {
    name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/listen-ports"
    value = "[{\"HTTPS\":443}]"
  }
  set {
    name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/ssl-redirect"
    value = "443"
  }
  set {
    name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/certificate-arn"
    value = var.acm_certificate_arn
  }
  set {
    name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/backend-protocol"
    value = "HTTPS"
  }
  set {
    name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/healthcheck-path"
    value = "/healthz"
  }
  # ArgoCD runs on HTTPS by default — tell it to also accept insecure
  # connections from the ALB so the health check works.
  set {
    name  = "server.extraArgs[0]"
    value = "--insecure"
  }

  depends_on = [module.eks, helm_release.aws_lb_controller]
}

# ==============================================================================
# 14. ARGOCD APPLICATION (App of Apps — bootstraps k8s/fastapi-app/)
# ==============================================================================
resource "helm_release" "argocd_apps" {
  name      = "argocd-apps"
  chart     = "${path.module}/../k8s/argocd-apps"
  namespace = "argocd"

  set {
    name  = "repoURL"
    value = var.argocd_repo_url
  }
  set {
    name  = "targetRevision"
    value = var.argocd_target_revision
  }
  set {
    name  = "appNamespace"
    value = var.app_namespace
  }

  depends_on = [
    helm_release.argocd,
    helm_release.cnpg_operator,
    helm_release.istiod,
    helm_release.external_secrets,
    helm_release.redis,
  ]
}
