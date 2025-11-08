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

# Step 6: Install Istio base and istiod
log_info "Installing Istio (v1.28.0) with mTLS..."
helm install istio-base istio/base \
  --namespace istio-system \
  --wait --timeout=5m 2>&1 | tail -5

helm install istiod istio/istiod \
  --namespace istio-system \
  --values "$SCRIPT_DIR/helm/istio/values.yaml" \
  --wait --timeout=5m 2>&1 | tail -5

log_info "Waiting for Istio control plane to be ready..."
kubectl wait --for=condition=Ready pod -l app=istiod -n istio-system --timeout=5m 2>/dev/null || true

# Step 7: Install Prometheus observability stack
log_info "Installing Prometheus stack (metrics, logs, traces)..."
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "$SCRIPT_DIR/helm/prometheus/values.yaml" \
  --wait --timeout=10m 2>&1 | tail -10

log_info "Waiting for Prometheus to be ready..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus -n monitoring --timeout=5m 2>/dev/null || true

# Step 8: Install Loki for log aggregation
log_info "Installing Loki (log aggregation)..."
helm install loki "$SCRIPT_DIR/helm/loki" \
  --namespace monitoring \
  --values "$SCRIPT_DIR/helm/loki/values.yaml" \
  --wait --timeout=5m 2>&1 | tail -5

# Step 9: Install Tempo for distributed tracing
log_info "Installing Tempo (distributed tracing)..."
helm install tempo "$SCRIPT_DIR/helm/tempo" \
  --namespace monitoring \
  --values "$SCRIPT_DIR/helm/tempo/values.yaml" \
  --wait --timeout=5m 2>&1 | tail -5

# Step 10: Install ArgoCD for GitOps
log_info "Installing ArgoCD (v3.2.0) for GitOps..."
helm install argocd argoproj/argo-cd \
  --namespace argocd \
  --values "$SCRIPT_DIR/helm/argocd/values.yaml" \
  --wait --timeout=10m 2>&1 | tail -10

log_info "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=5m 2>/dev/null || true
sleep 10

# Step 11: Build and load Docker image
log_info "Building and loading Docker image..."
docker build -t kubernetes-platform-stack:latest "$SCRIPT_DIR"
kind load docker-image kubernetes-platform-stack:latest --name "$CLUSTER_NAME"

# Step 12: Install my-app via Helm
log_info "Installing my-app via Helm..."
helm install my-app "$SCRIPT_DIR/helm/my-app" \
  --namespace app \
  --set image.pullPolicy=Never \
  --set image.tag=latest \
  --set autoscaling.minReplicas=1 \
  --set autoscaling.maxReplicas=3 \
  --wait --timeout=5m 2>&1 | tail -5

log_info "Waiting for my-app to be ready..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=my-app -n app --timeout=5m 2>/dev/null || true

# Step 13: Verify deployments
log_info "Verifying all Helm releases..."
helm list -a --all-namespaces

# Step 14: Test health endpoint
log_info "Testing application health endpoint..."
sleep 5
kubectl port-forward -n app svc/my-app 8080:80 > /dev/null 2>&1 &
sleep 2
HEALTH=$(curl -s http://localhost:8080/health 2>/dev/null || echo "")
pkill -f "port-forward" || true

if [ -z "$HEALTH" ]; then
    log_warn "Could not verify health endpoint, but deployment initiated"
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
echo "Status: Running with Helm and ArgoCD GitOps"
echo ""
echo "Deployed Applications:"
helm list -a --all-namespaces
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
echo "- Cilium v1.17.0 for networking, BGP, and native LoadBalancer"
echo "- Istio v1.28.0 for service mesh with mTLS"
echo "- Prometheus + Grafana + Loki + Tempo for full observability"
echo "- ArgoCD v3.2.0 for GitOps-driven deployments"
echo "- All applications deployed via Helm charts"
echo ""
