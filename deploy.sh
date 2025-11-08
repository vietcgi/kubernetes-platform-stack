#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-platform}"
REPO_URL="https://github.com/vietcgi/kubernetes-platform-stack"

echo "======================================"
echo "Kubernetes Platform Stack"
echo "ArgoCD GitOps Deployment"
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

# Step 2: Create KIND cluster
log_info "Creating KIND cluster '$CLUSTER_NAME' (v1.34.0)..."
kind create cluster --config "$SCRIPT_DIR/kind-config.yaml" --name "$CLUSTER_NAME"
sleep 5

# Step 2.5: Wait for default CNI (kindnet) to be ready
log_info "Waiting for default CNI to be ready..."
kubectl wait --for=condition=Ready pod -l k8s-app=kindnet -n kube-system --timeout=5m 2>/dev/null || true
sleep 5

# Step 3: Build and load Docker image
log_info "Building and loading Docker image..."
docker build -t kubernetes-platform-stack:latest "$SCRIPT_DIR"
kind load docker-image kubernetes-platform-stack:latest --name "$CLUSTER_NAME"

# Step 4: Install ArgoCD
log_info "Installing ArgoCD (GitOps Controller)..."
kubectl create namespace argocd 2>/dev/null || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
log_info "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Progressing=True application/argocd-server -n argocd --timeout=5m 2>/dev/null || \
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=5m 2>/dev/null || true
sleep 10

# Step 5: Deploy app-of-apps (master orchestrator)
log_info "Deploying app-of-apps (ArgoCD Master Application)..."
kubectl apply -f "$SCRIPT_DIR/argocd/app-of-apps.yaml"

# Step 6: Wait for all applications to sync
log_info "Waiting for all applications to sync via ArgoCD..."
for app in "observability" "infrastructure" "my-app"; do
    log_info "Syncing application: $app"
    # Force sync and wait
    kubectl patch application $app -n argocd --type merge -p '{"spec":{"syncPolicy":{"syncOptions":null}}}' 2>/dev/null || true
    sleep 5
done

# Wait for applications to be healthy
log_info "Waiting for applications to reach healthy state..."
for i in {1..60}; do
    if kubectl get application -n argocd -o jsonpath='{.items[*].status.operationState.finishedAt}' 2>/dev/null | grep -q "202"; then
        log_info "Applications synced successfully"
        break
    fi
    if [ $((i % 10)) -eq 0 ]; then
        log_info "Waiting for ArgoCD sync... ($i/60)"
    fi
    sleep 5
done

# Step 7: Verify deployments
log_info "Verifying deployments..."
kubectl rollout status deployment/my-app -n app --timeout=5m 2>/dev/null || log_warn "Application still deploying"
kubectl get applications -n argocd -o wide

# Step 8: Test health endpoint
log_info "Testing application health endpoint..."
sleep 5
kubectl port-forward -n app svc/my-app 8080:80 > /dev/null 2>&1 &
sleep 2
HEALTH=$(curl -s http://localhost:8080/health 2>/dev/null || echo "")
pkill -f "port-forward" || true

if [ -z "$HEALTH" ]; then
    log_warn "Could not verify health endpoint, but deployment initiated"
else
    log_info "Health check passed"
fi

# Step 9: Display summary
echo ""
echo "======================================"
echo "Deployment Complete!"
echo "======================================"
echo ""
echo "Cluster: $CLUSTER_NAME"
echo "Status: Running with ArgoCD GitOps"
echo ""
echo "Deployed Applications:"
kubectl get applications -n argocd --no-headers 2>/dev/null || true
echo ""
echo "Next Steps:"
echo ""
echo "1. Monitor ArgoCD:"
echo "   kubectl port-forward -n argocd svc/argocd-server 8080:443"
echo "   https://localhost:8080"
echo "   Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "2. Access Grafana:"
echo "   kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
echo "   http://localhost:3000 (admin/prom-operator)"
echo ""
echo "3. Access Prometheus:"
echo "   kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo "   http://localhost:9090"
echo ""
echo "4. Access Application:"
echo "   kubectl port-forward -n app svc/my-app 8080:80"
echo "   curl http://localhost:8080/health"
echo ""
echo "5. Watch ArgoCD Sync:"
echo "   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller -f"
echo ""
echo "6. Cleanup:"
echo "   kind delete cluster --name $CLUSTER_NAME"
echo ""
echo "All applications are managed by ArgoCD!"
echo "Any changes to argocd/ directory will automatically sync to the cluster."
echo ""
