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
echo "PHASE 1: Network Prerequisites (CoreDNS & Cilium)"
echo "=============================================="
echo ""

log_info "Patching CoreDNS with resource limits..."
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

log_info "Installing Cilium CNI..."

# Preload Cilium images for faster bootstrap and offline support
CILIUM_VERSION="1.18.3"
CILIUM_IMAGE="quay.io/cilium/cilium:${CILIUM_VERSION}"
CILIUM_OPERATOR_IMAGE="quay.io/cilium/operator-generic:${CILIUM_VERSION}"

log_info "Preloading Cilium images to speed up installation..."
docker pull "${CILIUM_IMAGE}" 2>&1 | grep -E "Pulling|Downloaded|Already" | tail -3 || true
docker pull "${CILIUM_OPERATOR_IMAGE}" 2>&1 | grep -E "Pulling|Downloaded|Already" | tail -3 || true
kind load docker-image "${CILIUM_IMAGE}" --name "$CLUSTER_NAME" 2>&1 | tail -2 || true
kind load docker-image "${CILIUM_OPERATOR_IMAGE}" --name "$CLUSTER_NAME" 2>&1 | tail -2 || true

helm repo add cilium https://helm.cilium.io
helm repo update cilium

# Get control plane IP address to avoid DNS chicken-and-egg problem
CONTROL_PLANE_NODE="${CLUSTER_NAME}-control-plane"
log_info "Detecting control plane IP address..."
CONTROL_PLANE_IP=$(kubectl get node "$CONTROL_PLANE_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
log_info "Control plane IP: $CONTROL_PLANE_IP"

helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --values "$SCRIPT_DIR/helm/cilium/values.yaml" \
  --version ${CILIUM_VERSION} \
  --set k8sServiceHost="$CONTROL_PLANE_IP" \
  --wait

log_info "Waiting for Cilium to be ready (this may take 5-10 minutes)..."
cilium_ready=0
for i in {1..180}; do
    # Check for running Cilium pods
    cilium_pods=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector=status.phase=Running 2>/dev/null | tail -n +2 | wc -l | xargs)

    # Verify all nodes are Ready (critical for kube-proxy replacement validation)
    if [ "$cilium_pods" -gt 0 ]; then
        ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " | xargs)
        node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | xargs)

        # Check if nodes are fully ready and kube-proxy mode is correctly set to none
        if [ -n "$node_count" ] && [ "$node_count" -gt 0 ] && [ "$ready_nodes" -eq "$node_count" ]; then
            cilium_ready=1
            log_ok "✓ Cilium pods running: $cilium_pods, All nodes Ready: $ready_nodes/$node_count"
            break
        fi
    fi

    if [ $((i % 20)) -eq 0 ]; then
        log_info "Waiting for Cilium initialization... ($i/180, pods: $cilium_pods, nodes: $ready_nodes)"
    fi
    sleep 5
done

if [ "$cilium_ready" -eq 0 ]; then
    log_warn "Cilium initialization taking longer than expected, continuing anyway..."
fi

log_info "Phase 1 complete - Network prerequisites established"

echo ""
echo "=============================================="
echo "PHASE 2: Install ArgoCD with Helm"
echo "=============================================="
echo ""

log_info "Creating argocd namespace..."
kubectl create namespace argocd 2>/dev/null || true

log_info "Adding ArgoCD Helm repository..."
helm repo add argoproj https://argoproj.github.io/argo-helm
helm repo update argoproj

log_info "Installing ArgoCD using Helm with custom values..."
helm upgrade --install argocd argoproj/argo-cd \
  --namespace argocd \
  --values "$SCRIPT_DIR/helm/argocd/values.yaml" \
  --version 7.2.0 \
  --wait

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
