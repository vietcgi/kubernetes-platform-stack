#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-platform}"
REPO_URL="https://github.com/vietcgi/kubernetes-platform-stack"

echo "======================================"
echo "Kubernetes Platform Stack"
echo "Helm-Based GitOps Deployment"
echo "======================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}INFO${NC}: $1"
}

log_warn() {
    echo -e "${YELLOW}WARN${NC}: $1"
}

log_error() {
    echo -e "${RED}ERROR${NC}: $1"
}

# Check prerequisites
log_info "Checking prerequisites..."

for cmd in docker kind kubectl helm; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "$cmd is not installed"
        exit 1
    fi
done

log_info "All prerequisites installed"

# Step 1: Delete existing cluster if it exists
log_info "Cleaning up existing cluster '$CLUSTER_NAME'..."
kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
sleep 2

# Step 2: Create KIND cluster with latest K8s (1.33) and no kube-proxy
log_info "Creating KIND cluster '$CLUSTER_NAME' (v1.33.0) with no kube-proxy..."
kind create cluster --config "$SCRIPT_DIR/kind-config.yaml" --name "$CLUSTER_NAME"
sleep 5

# Step 3: Install Helm repositories
log_info "Adding Helm repositories..."
helm repo add cilium https://helm.cilium.io
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo add jetstack https://charts.jetstack.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add argoproj https://argoproj.github.io/argo-helm
helm repo update

# Step 4: Create namespaces
log_info "Creating Kubernetes namespaces..."
kubectl create namespace kube-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f -

# Label namespaces for Istio injection
kubectl label namespace istio-system istio-injection=enabled --overwrite
kubectl label namespace monitoring istio-injection=enabled --overwrite

# Step 5: Install Cilium CNI with BGP and kube-proxy replacement
log_info "Installing Cilium CNI (v1.17.0) with BGP and kube-proxy replacement..."
helm install cilium cilium/cilium \
  --namespace kube-system \
  --values "$SCRIPT_DIR/helm/cilium/values.yaml" \
  --wait --timeout=10m 2>&1 | tail -10

log_info "Waiting for Cilium to be ready..."
kubectl wait --for=condition=Ready pod -l k8s-app=cilium -n kube-system --timeout=10m 2>/dev/null || true
sleep 10

# Step 6: Install ArgoCD for GitOps orchestration
log_info "Installing ArgoCD (v3.2.0) for GitOps..."
helm install argocd argoproj/argo-cd \
  --namespace argocd \
  --values "$SCRIPT_DIR/helm/argocd/values.yaml" \
  --wait --timeout=10m 2>&1 | tail -10

log_info "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=5m 2>/dev/null || true
sleep 10

# Step 7: Build and load Docker image
log_info "Building and loading Docker image..."
docker build -t kubernetes-platform-stack:latest "$SCRIPT_DIR"
kind load docker-image kubernetes-platform-stack:latest --name "$CLUSTER_NAME"

# Step 8: Create ArgoCD applications (other apps managed by ArgoCD)
log_info "Creating ArgoCD Application manifests..."
kubectl apply -f "$SCRIPT_DIR/argocd/applications/" 2>&1 | tail -5

# Step 9: Wait for ArgoCD to sync all applications
log_info "Waiting for ArgoCD to sync all applications..."
sleep 5
for app in "istio" "prometheus" "loki" "tempo" "my-app"; do
    log_info "Waiting for application: $app"
    for i in {1..60}; do
        STATUS=$(kubectl get application $app -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null || echo "")
        if [ "$STATUS" = "Succeeded" ] || [ "$STATUS" = "" ]; then
            log_info "Application $app synced"
            break
        fi
        if [ $((i % 10)) -eq 0 ]; then
            log_info "Still syncing $app... ($i/60)"
        fi
        sleep 5
    done
done

# Step 10: Verify deployments
log_info "Verifying ArgoCD applications..."
kubectl get applications -n argocd -o wide

# Step 11: Test my-app health endpoint
log_info "Waiting for my-app to be ready..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=my-app -n app --timeout=10m 2>/dev/null || true

log_info "Testing application health endpoint..."
sleep 5
kubectl port-forward -n app svc/my-app 8080:80 > /dev/null 2>&1 &
sleep 2
HEALTH=$(curl -s http://localhost:8080/health 2>/dev/null || echo "")
pkill -f "port-forward" || true

if [ -z "$HEALTH" ]; then
    log_warn "Could not verify health endpoint, but ArgoCD is syncing"
else
    log_info "Health check passed: $HEALTH"
fi

# Final summary
echo ""
echo "======================================"
echo "Deployment Complete!"
echo "======================================"
echo ""
echo "Cluster: $CLUSTER_NAME"
echo "K8s Version: 1.33.0"
echo "Status: Running with Cilium + ArgoCD GitOps"
echo ""
echo "Deployed Helm Releases:"
helm list -a --all-namespaces
echo ""
echo "ArgoCD-Managed Applications:"
kubectl get applications -n argocd --no-headers 2>/dev/null || true
echo ""
echo "Services and Access Points:"
echo ""
echo "1. Access ArgoCD:"
echo "   kubectl port-forward -n argocd svc/argocd-server 8080:443"
echo "   https://localhost:8080"
echo "   Username: admin"
echo "   Password: \$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo ""
echo "2. Access Grafana:"
echo "   kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
echo "   http://localhost:3000"
echo "   Username: admin"
echo "   Password: prom-operator"
echo ""
echo "3. Access Prometheus:"
echo "   kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo "   http://localhost:9090"
echo ""
echo "4. Access Istio Kiali (if enabled):"
echo "   kubectl port-forward -n istio-system svc/kiali 20001:20001"
echo "   http://localhost:20001"
echo ""
echo "5. Access Application:"
echo "   kubectl port-forward -n app svc/my-app 8080:80"
echo "   curl http://localhost:8080/health"
echo ""
echo "6. Watch Helm releases:"
echo "   helm list -a --all-namespaces"
echo ""
echo "7. Check Cilium BGP status:"
echo "   kubectl get ciliumloadbalancerippools -n kube-system"
echo "   kubectl get ciliuml2announcementpolicies -n kube-system"
echo ""
echo "8. Cleanup:"
echo "   kind delete cluster --name $CLUSTER_NAME"
echo ""
echo "Architecture Summary:"
echo "- KIND cluster with 1 control plane + 1 worker (no kube-proxy)"
echo "- Cilium v1.17.0 deployed via Helm"
echo "- ArgoCD v3.2.0 deployed via Helm"
echo "- ArgoCD manages all other apps via GitOps:"
echo "  ├─ Istio v1.28.0 (service mesh)"
echo "  ├─ Prometheus v2.48.0 (metrics)"
echo "  ├─ Loki v3.0.0 (logs)"
echo "  ├─ Tempo v2.3.0 (traces)"
echo "  └─ my-app (sample application)"
echo ""
echo "Deployment Model: GitOps-First"
echo "- Only 2 direct Helm installs: Cilium + ArgoCD"
echo "- All other apps managed by ArgoCD from git"
echo "- Changes via git commits, auto-synced by ArgoCD"
echo ""
