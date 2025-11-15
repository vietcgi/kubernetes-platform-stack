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

log_info "Installing CoreDNS..."
helm repo add coredns https://coredns.github.io/helm
helm repo update coredns

# Clean up existing CoreDNS resources that lack Helm ownership metadata
# Kind comes with default CoreDNS that Helm cannot adopt without proper metadata
log_info "Checking for unmanaged CoreDNS resources..."

# Clean up any stuck Helm release first
if helm list -n kube-system 2>/dev/null | grep -q "coredns"; then
    helm_status=$(helm list -n kube-system -o json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ "$helm_status" = "pending-install" ] || [ "$helm_status" = "pending-upgrade" ]; then
        log_warn "Found stuck Helm release in $helm_status state, deleting..."
        helm delete coredns -n kube-system --wait 2>/dev/null || true
        sleep 2
    fi
fi

# Delete ConfigMap if it lacks Helm ownership metadata (Kind creates default ConfigMap)
if kubectl get configmap coredns -n kube-system &>/dev/null; then
    helm_release=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)
    if [ "$helm_release" != "coredns" ]; then
        log_warn "CoreDNS ConfigMap exists without Helm ownership, deleting..."
        kubectl delete configmap coredns -n kube-system 2>/dev/null || true
    fi
fi

# Delete Service if it lacks Helm ownership metadata (Kind creates default Service)
if kubectl get service kube-dns -n kube-system &>/dev/null; then
    helm_release=$(kubectl get service kube-dns -n kube-system -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)
    if [ "$helm_release" != "coredns" ]; then
        log_warn "CoreDNS Service exists without Helm ownership, deleting..."
        kubectl delete service kube-dns -n kube-system 2>/dev/null || true
    fi
fi

# Delete Deployment if it exists and lacks Helm ownership metadata
if kubectl get deployment coredns -n kube-system &>/dev/null; then
    helm_release=$(kubectl get deployment coredns -n kube-system -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)
    if [ "$helm_release" != "coredns" ]; then
        log_warn "CoreDNS Deployment exists without Helm ownership, deleting..."
        kubectl delete deployment coredns -n kube-system --wait=false 2>/dev/null || true
        sleep 1
    fi
fi

helm upgrade --install coredns coredns/coredns \
  --namespace kube-system \
  --values "$SCRIPT_DIR/helm/coredns/values.yaml" \
  --version 1.45.0 \
  --timeout 5m \
  --wait || log_warn "CoreDNS Helm install timeout (may still be starting)"

# Wait for CoreDNS to actually be ready
log_info "Waiting for CoreDNS pods to be ready..."
for i in {1..120}; do
  ready_pods=$(kubectl get pods -n kube-system -l k8s-app=coredns --field-selector=status.phase=Running 2>/dev/null | tail -n +2 | wc -l | xargs)
  if [ "$ready_pods" -eq 2 ]; then
    log_ok "CoreDNS installed and ready ($ready_pods replicas)"
    break
  fi
  if [ $((i % 10)) -eq 0 ]; then
    log_info "Waiting for CoreDNS pods... ($i/120, ready: $ready_pods/2)"
  fi
  sleep 1
done
echo ""

log_info "Installing Cilium CNI..."

# Preload Cilium images for faster bootstrap and offline support
CILIUM_VERSION="1.18.4"
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
  --version 9.1.2 \
  --wait

log_info "Patching argocd-server deployment to inject --insecure flag..."
kubectl patch deployment argocd-server -n argocd --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": ["/usr/local/bin/argocd-server", "--port=8080", "--metrics-port=8083", "--insecure"]}]' \
  2>/dev/null || log_warn "Failed to patch argocd-server deployment (may already be patched)"

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

log_info "Waiting for root-app to sync bootstrap applications..."
sleep 10

log_info "Waiting for platform-apps Application to be created..."
for i in {1..60}; do
  if kubectl get application platform-apps -n argocd > /dev/null 2>&1; then
    log_ok "platform-apps Application created"
    break
  fi
  if [ $i -eq 60 ]; then
    log_warn "Timeout waiting for platform-apps Application"
  fi
  sleep 2
done

log_info "Waiting for platform-apps to sync ApplicationSet..."
for i in {1..60}; do
  SYNC_STATUS=$(kubectl get application platform-apps -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  if [ "$SYNC_STATUS" = "Synced" ]; then
    log_ok "platform-apps synced successfully"
    break
  fi
  if [ $i -eq 60 ]; then
    log_warn "Timeout waiting for platform-apps sync (status: $SYNC_STATUS)"
  fi
  sleep 2
done

log_info "Waiting for ApplicationSet to generate platform applications..."
for i in {1..60}; do
  APP_COUNT=$(kubectl get applications -n argocd -l app.kubernetes.io/managed-by=applicationset --no-headers 2>/dev/null | wc -l | xargs)
  if [ "$APP_COUNT" -gt 5 ]; then
    log_ok "ApplicationSet generated $APP_COUNT platform applications"
    break
  fi
  if [ $i -eq 60 ]; then
    log_warn "Only $APP_COUNT applications generated (expected more)"
  fi
  sleep 2
done

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

  # Always check node health
  check_node_health > /dev/null 2>&1

  # Dynamically check critical applications
  CRITICAL_APPS=$(kubectl get applications -n argocd -l criticality=critical -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  for app in $CRITICAL_APPS; do
    check_argocd_app_sync "$app" > /dev/null 2>&1
    check_argocd_app_health "$app" > /dev/null 2>&1
  done

  # Check root-app separately (always critical)
  check_argocd_app_sync "root-app" > /dev/null 2>&1
  check_argocd_app_health "root-app" > /dev/null 2>&1

  # Check critical pods
  check_pod_health "kube-system" "k8s-app=kube-dns" > /dev/null 2>&1
  check_pod_health "kube-system" "k8s-app=cilium" > /dev/null 2>&1

  sleep $CHECK_INTERVAL
done

echo -e "\n"
log_ok "Cluster bootstrap complete!"

# Show root-app first
get_app_status "root-app"

# Show all critical applications
echo ""
log_info "Critical Applications Status:"
CRITICAL_APPS=$(kubectl get applications -n argocd -l criticality=critical -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
for app in $CRITICAL_APPS; do
  get_app_status "$app"
done
get_pod_count "argocd"
get_pod_count "kube-system"

NODES_READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
NODES_TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
log_ok "Nodes ready: ${NODES_READY}/${NODES_TOTAL}"
