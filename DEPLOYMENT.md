# Deployment Guide — Production FastAPI on EKS

## Architecture Overview

```
                        ┌─── WAFv2 ───┐
                        │             ▼
Client ──▶ Route53 ──▶ ALB (TLS/ACM) ──▶ Istio Ingress Gateway
                                              │
                                     ┌────────┴────────┐
                                     ▼                  ▼
                            VirtualService       PeerAuthentication
                            (retries/timeout)        (STRICT mTLS)
                                     │
                                     ▼
                            FastAPI Deployment (HPA: 3-10 replicas)
                            ├── Istio sidecar (mTLS + tracing)
                            ├── Prometheus metrics (/metrics)
                            └── OpenTelemetry traces → Tempo
                                     │
                    ┌────────────────┼────────────────┐
                    ▼                ▼                 ▼
           PgBouncer Pooler    Redis (HA)         S3 (files)
           (3 instances)       (1 master +
                    │           3 replicas)
                    ▼
           CloudNativePG Cluster
           (3 instances × 3 AZs)
           ├── gp3-az StorageClass
           ├── Barman S3 backups
           └── PodMonitor → Prometheus

Observability:  Prometheus + Grafana │ Loki (logs) │ Tempo (traces)
Security:       Kyverno │ Network Policies │ External Secrets Operator
GitOps:         ArgoCD (auto-sync from Git)
```

### Terraform Provisions (14 addons)

| # | Component | Purpose |
|---|-----------|---------|
| 1 | EBS CSI Driver | gp3 StorageClass for CNPG volumes |
| 2 | Metrics Server | Required by HPA |
| 3 | Cluster Autoscaler | Node-level scaling |
| 4 | AWS LB Controller | ALB Ingress with WAF + TLS |
| 5 | Istio (base + istiod) | Service mesh, mTLS, circuit breaking |
| 6 | CNPG Operator | Kubernetes-native PostgreSQL |
| 7 | Redis (Bitnami) | In-cluster caching (replication mode) |
| 8 | External Secrets Operator | AWS Secrets Manager → K8s secrets |
| 9 | Kyverno | Policy engine (enforce best practices) |
| 10 | Prometheus + Grafana | Metrics + dashboards |
| 11 | Loki + Promtail | Centralized logging |
| 12 | Tempo | Distributed tracing |
| 13 | ArgoCD | GitOps continuous deployment |
| 14 | ArgoCD Apps | App-of-apps bootstrap |

### ArgoCD Deploys (Helm chart: `k8s/fastapi-app/`)

Namespace → ServiceAccount → ConfigMap → StorageClass → CNPG Cluster →
PgBouncer Pooler → Deployment → Service → Ingress → HPA →
Network Policies → Istio (PeerAuth + DestinationRule + VirtualService) →
External Secrets → ServiceMonitor

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.14.0
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) v2
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/) >= 3.0
- [Docker](https://docs.docker.com/engine/install/)
- [istioctl](https://istio.io/latest/docs/setup/getting-started/#download) (optional, for debugging)
- AWS account with permissions for: EKS, VPC, IAM, S3, ECR, Secrets Manager, KMS, ACM, WAFv2, ELB

---

## Step 1 — Configure Variables

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
# Required
argocd_repo_url = "https://github.com/<your-org>/<your-repo>.git"

# Ingress / ALB / TLS (set after creating ACM cert + WAF)
domain_name         = "api.example.com"
acm_certificate_arn = "arn:aws:acm:ap-south-1:123456789012:certificate/xxx"
waf_acl_arn         = "arn:aws:wafv2:ap-south-1:123456789012:regional/webacl/xxx"

# Observability
grafana_admin_password = "your-secure-password"

# Secrets Manager (optional)
create_app_secrets = true
api_key            = "your-api-key"
db_username        = "fastapi"
db_password        = "your-db-password"
```

### Pre-requisites for Ingress (optional but recommended)

1. **ACM Certificate** — Request in AWS Console → ACM for your domain
2. **WAFv2 WebACL** — Create in AWS Console → WAF & Shield (regional, same region)
3. **Route53 Hosted Zone** — If using Route53 for DNS

---

## Step 2 — Deploy Infrastructure

```bash
cd infra

terraform init
terraform plan
terraform apply
```

This provisions: VPC (3 AZs) → EKS (2 node groups) → all 14 addons → ECR.

Configure kubectl:

```bash
aws eks update-kubeconfig --region ap-south-1 --name fastapi-cluster
```

Verify:

```bash
kubectl get nodes
kubectl get ns
# You should see: istio-system, argocd, cnpg-system, observability,
#                  kyverno, external-secrets, fastapi
```

---

## Step 3 — Build & Push Docker Image to ECR

```bash
# Get ECR URL
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="ap-south-1"
ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Authenticate Docker to ECR
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin ${ECR_URL}

# Build & push
cd app
docker build -t fastapi-app:v1.0.0 .
docker tag fastapi-app:v1.0.0 ${ECR_URL}/fastapi-app:v1.0.0
docker push ${ECR_URL}/fastapi-app:v1.0.0
```

---

## Step 4 — Update Helm Values

Edit `k8s/fastapi-app/values.yaml`:

```yaml
image:
  repository: "<AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/fastapi-app"
  tag: "v1.0.0"

serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: "<IRSA_ROLE_ARN>"

env:
  AWS_REGION: "ap-south-1"
  AWS_S3_BUCKET: "<S3_BUCKET_NAME>"

# Enable ALB Ingress (requires ACM + LB Controller)
ingress:
  enabled: true
  host: "api.example.com"
  certificateArn: "<ACM_CERTIFICATE_ARN>"
  wafAclArn: "<WAF_ACL_ARN>"

# Enable External Secrets (requires secrets in AWS Secrets Manager)
externalSecrets:
  enabled: true
  secrets:
    - secretKey: API_KEY
      remoteKey: fastapi/app-secrets
      property: api_key

# Enable CNPG S3 backups
postgresql:
  backup:
    enabled: true
    s3Bucket: "your-cnpg-backup-bucket"
```

Get values from Terraform:

```bash
cd infra
terraform output irsa_s3_role_arn
terraform output s3_bucket_name
terraform output ecr_repository_url
terraform output lb_controller_role_arn
terraform output external_secrets_role_arn
```

---

## Step 5 — Create Redis Password Secret

If **not** using External Secrets Operator, create the Redis password manually:

```bash
kubectl create secret generic redis-password \
  --from-literal=password='your-redis-password' \
  -n fastapi
```

If using External Secrets, store it in AWS Secrets Manager at `fastapi/redis-password`.

---

## Step 6 — Push to Git (ArgoCD Auto-Deploys)

```bash
git add .
git commit -m "deploy: production fastapi app"
git push origin main
```

ArgoCD detects the push and auto-syncs the Helm chart.

---

## Step 7 — Verify Deployment

### Core Services

```bash
# ArgoCD application status
kubectl get applications -n argocd

# FastAPI pods (should show 3 replicas across AZs)
kubectl get pods -n fastapi -o wide

# CloudNativePG cluster (3 instances)
kubectl get clusters.postgresql.cnpg.io -n fastapi

# PgBouncer pooler (3 instances)
kubectl get poolers.postgresql.cnpg.io -n fastapi

# Redis
kubectl get pods -l app.kubernetes.io/name=redis -n fastapi
```

### Istio Service Mesh

```bash
# Verify Istio sidecar injection
kubectl get pods -n fastapi -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'
# Should show: fastapi + istio-proxy per pod

# PeerAuthentication (STRICT mTLS)
kubectl get peerauthentication -n fastapi

# VirtualService + DestinationRule
kubectl get virtualservice,destinationrule -n fastapi
```

### Ingress / ALB

```bash
# Check Ingress and ALB provisioning
kubectl get ingress -n fastapi

# Get ALB DNS (before Route53 CNAME)
kubectl get ingress -n fastapi -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'
```

### Autoscaling

```bash
# HPA status
kubectl get hpa -n fastapi

# Cluster Autoscaler logs
kubectl logs -l app.kubernetes.io/name=cluster-autoscaler -n kube-system --tail=20
```

### Network Policies

```bash
kubectl get networkpolicy -n fastapi
# Should show: default-deny-all, allow-fastapi-ingress,
#              allow-fastapi-to-postgres, allow-fastapi-to-redis,
#              allow-fastapi-dns, allow-fastapi-aws, allow-fastapi-to-otel
```

### External Secrets

```bash
kubectl get externalsecret -n fastapi
kubectl get clustersecretstore
```

### Access the Application (Public ALB)

```bash
# Get the ALB public DNS name
ALB_DNS=$(kubectl get ingress -n fastapi \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "App URL: https://${ALB_DNS}"

# Health check (via ALB public endpoint)
curl https://${ALB_DNS}/health

# Prometheus metrics
curl https://${ALB_DNS}/metrics

# Swagger UI — open in browser
echo "https://${ALB_DNS}/docs"
```

If you configured a custom domain with Route53 (see Step 9):

```bash
curl https://api.example.com/health
curl https://api.example.com/metrics
# Swagger UI: https://api.example.com/docs
```

> **Debug only** — If ALB is not yet ready, you can port-forward temporarily:
> ```bash
> kubectl port-forward svc/test-fastapi-app 8000:80 -n fastapi
> curl http://localhost:8000/health
> ```

---

## Step 8 — Access Observability Stack

Observability tools (ArgoCD, Grafana) are internal services. Expose them
via an internal ALB or use `kubectl port-forward` from a bastion/VPN-connected machine.

### ArgoCD UI

```bash
# Get the admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Expose temporarily (from a machine with kubectl access)
kubectl port-forward svc/argocd-server 8443:443 -n argocd
# Then open: https://<your-machine-ip>:8443  (admin / <password>)
```

> **Production recommendation:** Create a separate internal ALB Ingress for
> ArgoCD with restricted security group rules, or access via AWS SSM Session Manager.

### Grafana (metrics + dashboards)

```bash
kubectl port-forward svc/prometheus-grafana 3000:80 -n observability
# Then open: http://<your-machine-ip>:3000  (admin / <grafana_admin_password>)
```

> **Production recommendation:** Expose Grafana via internal ALB with
> SSO/OAuth2 integration, or keep it behind VPN.

Pre-configured data sources:
- **Prometheus** — metrics (auto-discovered via ServiceMonitor)
- **Loki** — add manually: `http://loki:3100`
- **Tempo** — add manually: `http://tempo:3100`

Recommended dashboards to import:
| Dashboard | Grafana ID |
|-----------|-----------|
| Kubernetes Cluster | 6417 |
| CNPG PostgreSQL | 20417 |
| Istio Mesh | 7639 |
| FastAPI (custom) | Create from `/metrics` |

### Loki (logs)

```bash
# Query recent FastAPI logs in Grafana → Explore → Loki
# LogQL: {namespace="fastapi", app_kubernetes_io_name="fastapi-app"}
```

### Tempo (traces)

```bash
# In Grafana → Explore → Tempo
# Search by service name: "fastapi-app"
# Or trace ID from response headers
```

---

## Step 9 — Configure Route53 DNS

The ALB gets a public AWS-generated hostname. Map your custom domain to it:

```bash
# Get the ALB public DNS
ALB_DNS=$(kubectl get ingress -n fastapi \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "ALB endpoint: ${ALB_DNS}"
```

Create a DNS record in Route53 (or your DNS provider):

| Field | Value |
|-------|-------|
| Name | `api.example.com` |
| Type | **A** (Alias) or **CNAME** |
| Value | `<ALB_DNS>` |
| Alias Target | Select the ALB from the dropdown (if Route53 Alias) |

Verify:

```bash
# Should resolve to the ALB
dig api.example.com

# Access your app globally
curl https://api.example.com/health
# {"status":"ok"}

# Swagger UI
open https://api.example.com/docs
```

> Without Route53, the app is still publicly accessible via the ALB DNS:
> `https://<ALB_DNS>/docs`

---

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/health` | Health check |
| GET | `/metrics` | Prometheus metrics |
| POST | `/items` | Create item (cached) |
| GET | `/items` | List items (Redis cached) |
| GET | `/items/{id}` | Get item (Redis cached) |
| PATCH | `/items/{id}` | Update item (cache invalidated) |
| DELETE | `/items/{id}` | Delete item (cache invalidated) |
| POST | `/files` | Upload file to S3 |
| GET | `/files` | List uploaded files |
| GET | `/files/{id}` | Get file + presigned URL |
| DELETE | `/files/{id}` | Delete file from S3 + DB |

---

## Updating the Application

1. Make changes to `app/` code
2. Build & push new image:
   ```bash
   docker build -t fastapi-app:v1.1.0 app/
   docker tag fastapi-app:v1.1.0 ${ECR_URL}/fastapi-app:v1.1.0
   docker push ${ECR_URL}/fastapi-app:v1.1.0
   ```
3. Update `k8s/fastapi-app/values.yaml` → `image.tag: "v1.1.0"`
4. `git push` → ArgoCD auto-deploys
5. HPA handles scaling; Istio handles traffic shifting

---

## Teardown

⚠️ Destroy in reverse dependency order to avoid orphaned resources:

```bash
cd infra

# 1. Remove ArgoCD apps (cleanly deletes all K8s resources)
terraform destroy -target=helm_release.argocd_apps

# 2. Remove GitOps + operators
terraform destroy -target=helm_release.argocd
terraform destroy -target=helm_release.cnpg_operator
terraform destroy -target=helm_release.redis

# 3. Remove service mesh
terraform destroy -target=helm_release.istiod
terraform destroy -target=helm_release.istio_base

# 4. Remove observability
terraform destroy -target=helm_release.tempo
terraform destroy -target=helm_release.loki
terraform destroy -target=helm_release.prometheus_stack

# 5. Remove security & scaling
terraform destroy -target=helm_release.kyverno
terraform destroy -target=helm_release.external_secrets
terraform destroy -target=helm_release.cluster_autoscaler
terraform destroy -target=helm_release.aws_lb_controller
terraform destroy -target=helm_release.metrics_server

# 6. Destroy everything else (VPC, EKS, IAM, S3, ECR)
terraform destroy
```

---

## Project Structure

```
├── app/                           # FastAPI application
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── main.py                    # Routes + OTel + Prometheus + Redis cache
│   ├── models.py                  # SQLModel: Item + FileRecord
│   ├── database.py                # Async SQLAlchemy engine
│   ├── config.py                  # Pydantic Settings (DB, Redis, OTel)
│   ├── cache.py                   # Redis caching layer
│   └── s3.py                      # S3 upload/delete/presigned
│
├── k8s/
│   ├── fastapi-app/               # Helm chart (deployed by ArgoCD)
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── _helpers.tpl
│   │       ├── namespace.yaml
│   │       ├── serviceaccount.yaml
│   │       ├── configmap.yaml
│   │       ├── deployment.yaml     # Istio sidecar + Redis + OTel env
│   │       ├── service.yaml
│   │       ├── ingress.yaml        # ALB + WAF + TLS
│   │       ├── hpa.yaml            # CPU/memory autoscaling
│   │       ├── cnpg-cluster.yaml   # CloudNativePG (3 AZs + S3 backup)
│   │       ├── storageclass.yaml   # gp3-az (WaitForFirstConsumer)
│   │       ├── pooler.yaml         # PgBouncer (3 instances)
│   │       ├── network-policy.yaml # Zero-trust network segmentation
│   │       ├── external-secret.yaml # AWS Secrets Manager → K8s
│   │       ├── istio.yaml          # mTLS + circuit breaker + VirtualService
│   │       └── service-monitor.yaml # Prometheus scraping
│   │
│   └── argocd-apps/               # ArgoCD Application CRs
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           └── fastapi-app.yaml
│
├── infra/                          # Terraform
│   ├── main.tf                     # Providers, VPC, EKS, IAM, S3, IRSA
│   ├── addons.tf                   # 14 cluster addons (see table above)
│   ├── ecr.tf                      # ECR repository + lifecycle
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── eks/                    # EKS cluster + 2 node groups
│       ├── iam/
│       ├── irsa/                   # Generic IRSA module
│       ├── s3/
│       ├── secret-manager/
│       └── vpc/                    # VPC + 3 AZs + NAT
│
├── DEPLOYMENT.md                   # This file
├── README.md
└── oidc_docs.md
