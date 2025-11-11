#!/bin/bash
set +e  # Handle errors explicitly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-platform}"
MONITORING_DURATION=${MONITORING_DURATION:-1200}
CHECK_INTERVAL=10
STARTUP_TIMEOUT=600s
FORCE_DELETE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_DELETE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force           Force delete existing cluster before deploying"
            echo "  -h, --help        Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  CLUSTER_NAME             Cluster name (default: platform)"
            echo "  MONITORING_DURATION      Monitoring time in seconds (default: 1200)"
            echo ""
            echo "Examples:"
            echo "  $0                       # Deploy to existing or create new cluster"
            echo "  $0 --force               # Force delete and redeploy cluster"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "======================================"
echo "Kubernetes Platform Bootstrap"
echo "Hybrid GitOps with ArgoCD"
echo "======================================"
echo ""
echo "CLUSTER: $CLUSTER_NAME"
if [ "$FORCE_DELETE" = true ]; then
    echo "MODE: Force delete and redeploy"
else
    echo "MODE: Idempotent (skip if cluster exists)"
fi
echo ""

# Check prerequisites
log_info "Checking prerequisites..."
for cmd in docker kind kubectl; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "$cmd is not installed"
        exit 1
    fi
done
log_info "All prerequisites installed"
echo ""

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    if [ "$FORCE_DELETE" = true ]; then
        log_warn "Cluster '$CLUSTER_NAME' exists. Deleting due to --force flag..."
        kind delete cluster --name "$CLUSTER_NAME"
        sleep 2
        log_info "Creating KIND cluster '$CLUSTER_NAME'..."
        kind create cluster --config "$SCRIPT_DIR/kind-config.yaml" --name "$CLUSTER_NAME"
        sleep 5
    else
        log_info "Cluster '$CLUSTER_NAME' already exists. Skipping cluster creation."
        log_info "Use --force flag to recreate the cluster."
    fi
else
    log_info "Creating KIND cluster '$CLUSTER_NAME'..."
    kind create cluster --config "$SCRIPT_DIR/kind-config.yaml" --name "$CLUSTER_NAME"
    sleep 5
fi

echo ""

echo "=============================================="
echo "PHASE 1: Network Prerequisites (CoreDNS)"
echo "=============================================="
echo ""

log_info "Waiting for API server..."
kubectl wait --for=condition=available --timeout=$STARTUP_TIMEOUT deployment/coredns -n kube-system 2>/dev/null || true

log_info "Patching CoreDNS..."
kubectl patch deployment coredns -n kube-system -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "coredns",
          "resources": {
            "limits": {"cpu": "100m", "memory": "64Mi"},
            "requests": {"cpu": "50m", "memory": "32Mi"}
          }
        }]
      }
    }
  }
}' 2>/dev/null || true

log_info "Waiting for CoreDNS pods..."
kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=$STARTUP_TIMEOUT

# Install Cilium CNI (critical - must be before ArgoCD)
CILIUM_VERSION="1.18.3"
log_info "Preloading Cilium image to speed up installation..."
CILIUM_IMAGE="quay.io/cilium/cilium:${CILIUM_VERSION}"
docker pull "${CILIUM_IMAGE}" 2>&1 | grep -E "Pulling|Downloaded|Already" | tail -3 || true
kind load docker-image "${CILIUM_IMAGE}" --name "$CLUSTER_NAME" 2>&1 | tail -2 || true

log_info "Adding Cilium Helm repository..."
helm repo add cilium https://helm.cilium.io --force-update

log_info "Installing Cilium CNI..."
CONTROL_PLANE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
if ! helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set image.pullPolicy=IfNotPresent \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$CONTROL_PLANE_IP" \
  --set k8sServicePort=6443 \
  --set ebpf.enabled=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true; then
    log_error "Failed to install Cilium"
    exit 1
fi

log_info "Waiting for Cilium pods..."
kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s

echo ""
echo "=============================================="
echo "PHASE 2: Install ArgoCD"
echo "=============================================="
echo ""

log_info "Creating argocd namespace..."
kubectl create namespace argocd 2>/dev/null || true

log_info "Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

log_info "Waiting for ArgoCD server..."
kubectl wait deployment argocd-server -n argocd --for=condition=Available --timeout=$STARTUP_TIMEOUT

log_info "Waiting for ArgoCD controller..."
kubectl wait deployment argocd-application-controller -n argocd --for=condition=Available --timeout=$STARTUP_TIMEOUT 2>/dev/null || true

log_info "Waiting for ArgoCD repo server..."
kubectl wait deployment argocd-repo-server -n argocd --for=condition=Available --timeout=$STARTUP_TIMEOUT 2>/dev/null || true

echo ""
echo "=============================================="
echo "PHASE 3: Bootstrap GitOps"
echo "=============================================="
echo ""

log_info "Applying root-app..."
kubectl apply -f argocd/bootstrap/root-app.yaml
sleep 5

echo ""
echo "=============================================="
echo "PHASE 4: Active Health Monitoring"
echo "=============================================="
echo ""

log_info "Monitoring cluster health for ${MONITORING_DURATION}s..."
echo ""

source ./scripts/health-check.sh

MONITORING_START=$(date +%s)
MONITORING_END=$((MONITORING_START + MONITORING_DURATION))

while [ $(date +%s) -lt $MONITORING_END ]; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - MONITORING_START))
  REMAINING=$((MONITORING_END - CURRENT_TIME))
  ELAPSED_MIN=$((ELAPSED / 60))
  REMAINING_MIN=$((REMAINING / 60))
  REMAINING_SEC=$((REMAINING % 60))

  echo -ne "\r[$ELAPSED_MIN m] Monitoring... ${REMAINING_MIN}m ${REMAINING_SEC}s remaining"

  check_node_health > /dev/null 2>&1
  check_argocd_app_sync "root-app" > /dev/null 2>&1
  check_argocd_app_sync "coredns-config" > /dev/null 2>&1
  check_argocd_app_sync "cilium" > /dev/null 2>&1
  check_argocd_app_health "root-app" > /dev/null 2>&1
  check_pod_health "kube-system" "k8s-app=kube-dns" > /dev/null 2>&1
  check_pod_health "kube-system" "k8s-app=cilium" > /dev/null 2>&1

  sleep $CHECK_INTERVAL
done

echo -e "\n"
log_ok "Cluster bootstrap complete!"

get_app_status "root-app"
get_app_status "coredns-config"
get_app_status "cilium"
get_pod_count "argocd"
get_pod_count "kube-system"

NODES_READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
NODES_TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
log_ok "Nodes ready: ${NODES_READY}/${NODES_TOTAL}"
