#!/bin/bash
set -e

CLUSTER_NAME="${CLUSTER_NAME:-platform}"
MONITORING_DURATION=${MONITORING_DURATION:-1200}
CHECK_INTERVAL=10
STARTUP_TIMEOUT=600

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $1"; }

log_info "Creating KIND cluster..."
kind create cluster --config kind-config.yaml --name "$CLUSTER_NAME"

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

log_info "Applying root-app..."
kubectl apply -f argocd/bootstrap/root-app.yaml
sleep 5

log_info "Monitoring health (${MONITORING_DURATION}s)..."

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
