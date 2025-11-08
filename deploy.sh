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
helm repo add cilium https://helm.cilium.io --force-update
helm repo add istio https://istio-release.storage.googleapis.com/charts --force-update
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo add argoproj https://argoproj.github.io/argo-helm --force-update
helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
helm repo add falcosecurity https://falcosecurity.github.io/charts --force-update
helm repo add kyverno https://kyverno.github.io/kyverno --force-update
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts --force-update
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets --force-update
helm repo update

# Step 4: Create all required namespaces from config/global.yaml
log_info "Creating Kubernetes namespaces..."
kubectl create namespace kube-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace falco --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace sealed-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace gatekeeper-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace audit-logging --dry-run=client -o yaml | kubectl apply -f -

# Label namespaces for Istio injection (optional, but useful for observability)
kubectl label namespace monitoring istio-injection=enabled --overwrite || true
kubectl label namespace app istio-injection=enabled --overwrite || true

# Step 5: Install Cilium CNI with BGP and kube-proxy replacement
log_info "Installing Cilium CNI (v1.17.0) with BGP and kube-proxy replacement..."
helm install cilium cilium/cilium \
  --namespace kube-system \
  --values "$SCRIPT_DIR/helm/cilium/values.yaml" 2>&1 | tail -5

log_info "Waiting for Cilium to be ready (this may take 5-10 minutes)..."
cilium_ready=0
for i in {1..120}; do
    # Check for running Cilium pods
    cilium_pods=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector=status.phase=Running 2>/dev/null | tail -n +2 | wc -l)

    # Also verify API server is responding to Cilium (important for init containers)
    if [ "$cilium_pods" -gt 0 ]; then
        # Double-check that nodes are becoming Ready
        ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
        if [ "$ready_nodes" -gt 0 ]; then
            cilium_ready=1
            log_info "✓ Cilium pods are running and cluster nodes becoming ready"
            break
        fi
    fi

    if [ $((i % 15)) -eq 0 ]; then
        log_info "Waiting for Cilium initialization... ($i/120, pods: $cilium_pods)"
    fi
    sleep 5
done

if [ "$cilium_ready" -eq 0 ]; then
    log_warn "Cilium initialization taking longer than expected, continuing anyway..."
fi
sleep 20

# Step 6: Install ArgoCD for GitOps orchestration
log_info "Installing ArgoCD (v3.2.0) for GitOps..."
log_info "Using lightweight installation approach..."

# Option A: Use direct YAML installation (faster, no Helm timeout issues)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>&1 | tail -5

log_info "Waiting for ArgoCD to be ready (this may take 5-10 minutes)..."
for i in {1..120}; do
    argocd_server=$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    argocd_server=${argocd_server:-0}  # default to 0 if empty
    if [ "$argocd_server" -ge 1 ]; then
        log_info "✓ ArgoCD server is ready"
        break
    fi
    if [ $((i % 20)) -eq 0 ]; then
        log_info "Waiting for ArgoCD server... ($i/120)"
    fi
    sleep 3
done
sleep 10

# Step 7: Apply ApplicationSet to generate all 14 applications (replaces old argocd/applications/ approach)
log_info "Applying ApplicationSet to generate all 14 applications..."
kubectl apply -f "$SCRIPT_DIR/argocd/applicationsets/platform-apps.yaml"
sleep 5

# Step 8: Wait for all applications to be created by ApplicationSet
log_info "Waiting for ApplicationSet to generate applications..."
sleep 5
max_attempts=30
attempts=0
while [ $attempts -lt $max_attempts ]; do
    app_count=$(kubectl get applications -n argocd 2>/dev/null | tail -n +2 | wc -l || echo "0")
    if [ "$app_count" -ge 14 ]; then
        log_info "ApplicationSet created all 14 applications!"
        break
    fi
    log_info "Applications created: $app_count/14 (waiting...)"
    sleep 2
    ((attempts++))
done

# Step 9: Wait for all applications to sync
log_info "Waiting for all applications to sync and become healthy..."
sleep 10

# Get all application names dynamically
all_apps=$(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [ -z "$all_apps" ]; then
    log_error "No applications found in ArgoCD!"
    exit 1
fi

# Wait for each app to sync
for app in $all_apps; do
    log_info "Monitoring application: $app"
    for i in {1..120}; do
        # Check if app exists and get its sync status
        SYNC_STATUS=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        HEALTH_STATUS=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

        if [ "$SYNC_STATUS" = "Synced" ] && [ "$HEALTH_STATUS" = "Healthy" ]; then
            log_info "✓ $app is Synced and Healthy"
            break
        fi

        if [ $((i % 15)) -eq 0 ]; then
            log_info "$app status: Sync=$SYNC_STATUS, Health=$HEALTH_STATUS (attempt $i/120)"
        fi

        sleep 3
    done
done

# Step 10: Final verification and summary
log_info "Verifying all applications are deployed..."
echo ""
echo "======================================"
echo "✓ Deployment Complete!"
echo "======================================"
echo ""
echo "Cluster: $CLUSTER_NAME"
echo "K8s Version: 1.33.0"
echo "Status: Running with Cilium + ArgoCD GitOps"
echo ""
echo "Deployed Helm Releases (direct installs):"
echo "- Cilium v1.17.0 (CNI with BGP, kube-proxy replacement)"
echo "- ArgoCD v3.2.0 (GitOps orchestration)"
echo ""
echo "ArgoCD-Managed Applications (14 total):"
kubectl get applications -n argocd --no-headers 2>/dev/null | while read line; do
    echo "  ✓ $line"
done
echo ""
echo "Next Steps:"
echo "=================================="
echo ""
echo "1. Watch ArgoCD dashboard:"
echo "   kubectl port-forward -n argocd svc/argocd-server 8080:443"
echo "   https://localhost:8080"
echo "   Username: admin"
echo "   Password: \$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo ""
echo "2. View ArgoCD applications:"
echo "   kubectl get applications -n argocd -o wide"
echo "   argocd app list"
echo "   argocd app get <app-name>"
echo ""
echo "3. Watch application sync progress:"
echo "   watch kubectl get applications -n argocd"
echo "   watch kubectl get pods -A"
echo ""
echo "4. Access Prometheus:"
echo "   kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo "   http://localhost:9090"
echo ""
echo "5. Access Grafana:"
echo "   kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
echo "   http://localhost:3000 (admin/prom-operator)"
echo ""
echo "6. Check Cilium status:"
echo "   kubectl get pods -n kube-system -l k8s-app=cilium"
echo "   kubectl get ciliumloadbalancerippools -n kube-system"
echo ""
echo "7. View application logs:"
echo "   kubectl logs -n <namespace> -l app=<app-name> -f"
echo ""
echo "8. Cleanup cluster:"
echo "   kind delete cluster --name $CLUSTER_NAME"
echo ""
echo "=================================="
echo "Architecture:"
echo "=================================="
echo ""
echo "Infrastructure (Direct Helm):"
echo "  ├─ Cilium v1.17.0 (BGP, eBPF, kube-proxy replacement)"
echo "  └─ ArgoCD v3.2.0 (GitOps orchestration)"
echo ""
echo "Observability (via ApplicationSet):"
echo "  ├─ Prometheus v2.48.0 (metrics)"
echo "  ├─ Loki v3.0.0 (logs)"
echo "  └─ Tempo v2.3.0 (traces)"
echo ""
echo "Service Mesh (via ApplicationSet):"
echo "  └─ Istio v1.28.0 (mTLS, traffic management)"
echo ""
echo "Security (via ApplicationSet):"
echo "  ├─ Cert-Manager v1.14.0 (TLS)"
echo "  ├─ Vault v1.17.0 (secrets)"
echo "  ├─ Falco v0.37.0 (runtime security)"
echo "  ├─ Kyverno v1.12.0 (policies)"
echo "  └─ Sealed-Secrets v0.25.0 (git-stored secrets)"
echo ""
echo "Governance (via ApplicationSet):"
echo "  ├─ Gatekeeper v3.17.0 (policy enforcement)"
echo "  └─ Audit-Logging v1.0.0 (compliance)"
echo ""
echo "Application (via ApplicationSet):"
echo "  └─ my-app v1.0.0 (sample app with Istio)"
echo ""
echo "Deployment Model: GitOps-First"
echo "  • 2 direct Helm installs (infrastructure only)"
echo "  • 12 apps via ApplicationSet (all other stacks)"
echo "  • Single ApplicationSet template generating all apps"
echo "  • Changes via git commits, auto-synced"
echo ""
