#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh — Clean teardown of the full EKS platform
# ==============================================================================
# This script ensures ArgoCD-managed resources are fully deleted BEFORE
# destroying the Terraform infrastructure. Run from the repo root.
#
# Usage:
#   chmod +x cleanup.sh
#   ./cleanup.sh
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*"; }

INFRA_DIR="$(cd "$(dirname "$0")/infra" && pwd)"

# ------------------------------------------------------------------
# Step 1: Delete ArgoCD Application (triggers cascade delete via finalizer)
# ------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  Step 1: Delete ArgoCD Application"
echo "=========================================="

if kubectl get application fastapi-app -n argocd &>/dev/null; then
    log "Deleting ArgoCD Application (cascade delete)..."
    kubectl delete application fastapi-app -n argocd

    # Wait for the Application to be fully removed (finalizer runs)
    warn "Waiting for ArgoCD to finish cleaning up app resources..."
    kubectl wait --for=delete application/fastapi-app -n argocd --timeout=300s 2>/dev/null || true

    # Double-check: wait for app namespace pods to terminate
    if kubectl get ns fastapi &>/dev/null; then
        warn "Waiting for pods in fastapi namespace to terminate..."
        kubectl wait --for=delete pods --all -n fastapi --timeout=120s 2>/dev/null || true

        # Wait for CNPG cluster to be fully removed (PVCs)
        if kubectl get clusters.postgresql.cnpg.io -n fastapi &>/dev/null 2>&1; then
            warn "Waiting for CNPG cluster to terminate..."
            kubectl wait --for=delete clusters.postgresql.cnpg.io --all -n fastapi --timeout=180s 2>/dev/null || true
        fi
    fi

    log "ArgoCD Application and all managed resources deleted."
else
    warn "ArgoCD Application 'fastapi-app' not found — skipping."
fi

# ------------------------------------------------------------------
# Step 2: Terraform destroy (in reverse dependency order)
# ------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  Step 2: Terraform destroy"
echo "=========================================="

cd "$INFRA_DIR"

# Remove the ArgoCD apps Helm release (already deleted the app above,
# but this removes the Terraform state entry)
log "Removing ArgoCD apps Helm release..."
terraform destroy -target=helm_release.argocd_apps -auto-approve 2>/dev/null || true

# Remove ArgoCD server
log "Removing ArgoCD..."
terraform destroy -target=helm_release.argocd -auto-approve

# Remove operators and data stores
log "Removing CNPG operator..."
terraform destroy -target=helm_release.cnpg_operator -auto-approve

log "Removing Redis..."
terraform destroy -target=helm_release.redis -auto-approve

# Remove service mesh
log "Removing Istio..."
terraform destroy -target=helm_release.istiod -auto-approve
terraform destroy -target=helm_release.istio_base -auto-approve

# Remove observability
log "Removing observability stack..."
terraform destroy -target=helm_release.tempo -auto-approve
terraform destroy -target=helm_release.loki -auto-approve
terraform destroy -target=helm_release.prometheus_stack -auto-approve

# Remove security & scaling addons
log "Removing cluster addons..."
terraform destroy -target=helm_release.kyverno -auto-approve
terraform destroy -target=helm_release.external_secrets -auto-approve
terraform destroy -target=helm_release.cluster_autoscaler -auto-approve
terraform destroy -target=helm_release.aws_lb_controller -auto-approve
terraform destroy -target=helm_release.metrics_server -auto-approve

# Destroy everything else (VPC, EKS, IAM, S3, ECR, etc.)
log "Destroying remaining infrastructure (EKS, VPC, IAM, S3, ECR)..."
terraform destroy -auto-approve

echo ""
log "=========================================="
log "  Teardown complete!"
log "=========================================="
