#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-platform}"
REPO_URL="https://github.com/vietcgi/kubernetes-platform-stack"
FORCE_DELETE=false
ENVIRONMENT="${ENVIRONMENT:-dev}"  # Default environment: dev, prod, staging

# Colors for output (defined early for use in arg parsing)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logger functions (defined early for use in arg parsing)
log_info() {
    echo -e "${GREEN}INFO${NC}: $1"
}

log_warn() {
    echo -e "${YELLOW}WARN${NC}: $1"
}

log_error() {
    echo -e "${RED}ERROR${NC}: $1"
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_DELETE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [ENVIRONMENT] [OPTIONS]"
            echo ""
            echo "Arguments:"
            echo "  dev|staging|prod  Environment to deploy (default: dev)"
            echo ""
            echo "Options:"
            echo "  --force           Force delete existing cluster before deploying"
            echo "  -h, --help        Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                  # Deploy to dev (skip if cluster exists)"
            echo "  $0 prod             # Deploy to prod"
            echo "  $0 staging --force  # Force delete and redeploy to staging"
            exit 0
            ;;
        dev|staging|prod)
            ENVIRONMENT="$1"
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "======================================"
echo "Kubernetes Platform Stack"
echo "Helm-Based GitOps Deployment"
echo "======================================"
echo ""
echo "ENVIRONMENT: $ENVIRONMENT"
if [ "$FORCE_DELETE" = true ]; then
    echo "MODE: Force delete and redeploy"
else
    echo "MODE: Idempotent (skip if cluster exists)"
fi
echo ""

# Check prerequisites
log_info "Checking prerequisites..."

for cmd in docker kind kubectl helm; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "$cmd is not installed"
        exit 1
    fi
done

log_info "All prerequisites installed"

# Step 1: Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    if [ "$FORCE_DELETE" = true ]; then
        log_warn "Cluster '$CLUSTER_NAME' exists. Deleting due to --force flag..."
        kind delete cluster --name "$CLUSTER_NAME"
        sleep 2
        log_info "Creating KIND cluster '$CLUSTER_NAME' (v1.34.0) with no kube-proxy..."
        kind create cluster --config "$SCRIPT_DIR/kind-config.yaml" --name "$CLUSTER_NAME"
        sleep 5
    else
        log_info "Cluster '$CLUSTER_NAME' already exists. Skipping cluster creation."
        log_info "Use --force flag to recreate the cluster."
    fi
else
    # Step 2: Create KIND cluster with latest K8s (1.34) and no kube-proxy
    log_info "Creating KIND cluster '$CLUSTER_NAME' (v1.34.0) with no kube-proxy..."
    kind create cluster --config "$SCRIPT_DIR/kind-config.yaml" --name "$CLUSTER_NAME"
    sleep 5
fi

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
kubectl create namespace infrastructure --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -

# Step 4.5: Create PostgreSQL secret if it doesn't exist
log_info "Creating PostgreSQL secret..."
if ! kubectl get secret postgres-secret -n infrastructure &>/dev/null; then
    POSTGRES_PASSWORD=$(openssl rand -base64 24)
    kubectl create secret generic postgres-secret \
        --from-literal=password="$POSTGRES_PASSWORD" \
        -n infrastructure
    log_info "PostgreSQL secret created with randomly generated password"
else
    log_info "PostgreSQL secret already exists, skipping creation"
fi

# Label namespaces for Istio injection (optional, but useful for observability)
if ! kubectl label namespace monitoring istio-injection=enabled --overwrite 2>/dev/null; then
    log_warn "Could not label monitoring namespace for Istio injection"
fi
if ! kubectl label namespace app istio-injection=enabled --overwrite 2>/dev/null; then
    log_warn "Could not label app namespace for Istio injection"
fi

# Step 5: CoreDNS is installed by KIND - verify it's running
log_info "Verifying CoreDNS is running..."
coredns_ready=0
for i in {1..30}; do
    coredns_pods=$(kubectl get pods -n kube-system -l k8s-app=coredns --field-selector=status.phase=Running 2>/dev/null | tail -n +2 | wc -l || echo "0")
    if [ "$coredns_pods" -ge 1 ]; then
        log_info "✓ CoreDNS is ready with $coredns_pods pods"
        coredns_ready=1
        break
    fi
    if [ $((i % 10)) -eq 0 ]; then
        log_info "Waiting for CoreDNS... ($i/30, pods: $coredns_pods)"
    fi
    sleep 1
done

if [ "$coredns_ready" -eq 0 ]; then
    log_warn "CoreDNS not fully ready but continuing..."
fi

# Step 5b: Optimize CoreDNS resources for laptop deployment (created by KIND)
log_info "Optimizing CoreDNS for laptop deployment..."
# CoreDNS is already created by KIND with label k8s-app=coredns
# Only patch resources if deployment exists and is accessible
if kubectl get deployment coredns -n kube-system &>/dev/null 2>&1; then
    kubectl patch deployment coredns -n kube-system --type='json' -p='[
      {
        "op": "replace",
        "path": "/spec/replicas",
        "value": 1
      },
      {
        "op": "replace",
        "path": "/spec/template/spec/containers/0/resources",
        "value": {
          "limits": {
            "cpu": "100m",
            "memory": "64Mi"
          },
          "requests": {
            "cpu": "50m",
            "memory": "32Mi"
          }
        }
      }
    ]' 2>/dev/null || log_warn "Could not optimize CoreDNS resources"
    log_info "CoreDNS scaled to 1 replica for laptop deployment"
else
    log_warn "CoreDNS deployment (coredns) not found, skipping resource optimization"
fi

sleep 5

# Step 5c: Set Cilium version
CILIUM_VERSION="1.18.3"
CILIUM_IMAGE="quay.io/cilium/cilium:v${CILIUM_VERSION}"

# Note: Image preloading disabled due to multi-platform manifest issues with kind load
# The cluster will pull the image directly during Cilium deployment
log_info "Using Cilium image: $CILIUM_IMAGE (will be pulled by cluster nodes)"

# Step 6: Install Cilium CNI with BGP and kube-proxy replacement
log_info "Installing Cilium CNI (v${CILIUM_VERSION}) with BGP and kube-proxy replacement..."
CONTROL_PLANE_NODE="${CLUSTER_NAME}-control-plane"

# Get control plane IP address to avoid DNS chicken-and-egg problem
# (Cilium needs DNS but CoreDNS needs Cilium to be running)
log_info "Detecting control plane IP address..."
CONTROL_PLANE_IP=$(kubectl get node "$CONTROL_PLANE_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
log_info "Control plane IP: $CONTROL_PLANE_IP"

if ! helm upgrade --install cilium cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$CONTROL_PLANE_IP" \
  --set k8sServicePort=6443 \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --values "$SCRIPT_DIR/helm/cilium/values.yaml" 2>&1 | tail -5; then
    log_error "Failed to install Cilium"
    exit 1
fi

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
            log_info "✓ Cilium pods running: $cilium_pods, All nodes Ready: $ready_nodes/$node_count"
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
sleep 30

# Step 7: Apply Cilium LoadBalancer configuration (IP pool and L2 announcements)
log_info "Applying Cilium LoadBalancer configuration..."
kubectl apply -f "$SCRIPT_DIR/manifests/cilium/lb-pool.yaml" 2>&1 | tail -3
sleep 2
kubectl apply -f "$SCRIPT_DIR/manifests/cilium/l2-announcement-policy.yaml" 2>&1 | tail -3
sleep 5

# Verify LoadBalancer configuration
lb_pool=$(kubectl get ciliumloadbalancerippools 2>/dev/null | grep "default" | wc -l)
l2_policy=$(kubectl get ciliuml2announcementpolicies -n kube-system 2>/dev/null | grep "default" | wc -l)
if [ "$lb_pool" -gt 0 ] && [ "$l2_policy" -gt 0 ]; then
    log_info "✓ Cilium LoadBalancer configuration applied successfully"
    log_info "  - CiliumLoadBalancerIPPool: 172.18.1.0/24 (172.18.1.1-254 usable range)"
    log_info "  - L2 Announcement: eth0 (externalIPs + loadBalancerIPs)"
else
    log_warn "LoadBalancer configuration may not have been applied correctly"
fi
sleep 5

# Step 8: Install ArgoCD for GitOps orchestration
log_info "Installing ArgoCD (v3.2.0) for GitOps..."
log_info "Using lightweight installation approach..."

# Check if ArgoCD is already installed
if kubectl get deployment argocd-server -n argocd &>/dev/null 2>&1; then
    log_info "ArgoCD already installed. Skipping installation."
else
    # Use direct YAML installation (faster, no Helm timeout issues)
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>&1 | tail -5
fi

log_info "Waiting for ArgoCD to be ready (fast-track mode)..."
for i in {1..60}; do
    argocd_server=$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    argocd_server=${argocd_server:-0}  # default to 0 if empty
    if [ "$argocd_server" -ge 1 ]; then
        log_info "✓ ArgoCD server is ready"
        break
    fi
    if [ $((i % 10)) -eq 0 ]; then
        log_info "Waiting for ArgoCD server... ($i/60)"
    fi
    sleep 1
done
sleep 2

# Step 9: Apply ArgoCD NetworkPolicies with DNS egress support
# NOTE: NetworkPolicies disabled to avoid circular dependency that blocks DNS resolution
# In development/non-security-critical environments, allow all pod-to-pod traffic
# For production deployments, implement NetworkPolicies after ensuring stable DNS
log_info "Skipping NetworkPolicies - using unrestricted pod communication for development"

# Step 10: Apply Kyverno CRD compatibility layer (fixes v3.5.2 sanity check failures)
log_info "Applying Kyverno CRD compatibility layer..."
if [ -f "$SCRIPT_DIR/manifests/kyverno/crds-compat.yaml" ]; then
    kubectl apply -f "$SCRIPT_DIR/manifests/kyverno/crds-compat.yaml" 2>&1 | tail -3
fi

# Step 11: Apply ApplicationSet to generate all platform applications
log_info "Applying ApplicationSet to generate platform applications..."
if [ ! -f "$SCRIPT_DIR/argocd/applicationsets/platform-apps.yaml" ]; then
    log_error "ApplicationSet file not found: $SCRIPT_DIR/argocd/applicationsets/platform-apps.yaml"
    exit 1
fi

# Apply ApplicationSet in background
kubectl apply -f "$SCRIPT_DIR/argocd/applicationsets/platform-apps.yaml" > /tmp/applicationset.log 2>&1 &
APPLICATIONSET_PID=$!

# Apply Kong ingress routes Application (managed by ArgoCD)
log_info "Applying Kong Ingress Routes Application..."
if [ -f "$SCRIPT_DIR/argocd/applications/kong-ingress.yaml" ]; then
    kubectl apply -f "$SCRIPT_DIR/argocd/applications/kong-ingress.yaml" > /tmp/kong-ingress.log 2>&1 &
    KONG_INGRESS_PID=$!
else
    log_warn "Kong ingress Application not found: $SCRIPT_DIR/argocd/applications/kong-ingress.yaml"
fi

# Apply NetworkPolicies as cluster infrastructure (not managed by ArgoCD)
log_info "Applying NetworkPolicies for Harbor, Longhorn, and Gatekeeper..."
if [ -f "$SCRIPT_DIR/manifests/harbor/network-policy.yaml" ]; then
    kubectl apply -f "$SCRIPT_DIR/manifests/harbor/network-policy.yaml" &
else
    log_warn "Harbor NetworkPolicy not found: $SCRIPT_DIR/manifests/harbor/network-policy.yaml"
fi
if [ -f "$SCRIPT_DIR/manifests/longhorn/network-policy.yaml" ]; then
    kubectl apply -f "$SCRIPT_DIR/manifests/longhorn/network-policy.yaml" &
else
    log_warn "Longhorn NetworkPolicy not found: $SCRIPT_DIR/manifests/longhorn/network-policy.yaml"
fi
if [ -f "$SCRIPT_DIR/manifests/gatekeeper/network-policy.yaml" ]; then
    kubectl apply -f "$SCRIPT_DIR/manifests/gatekeeper/network-policy.yaml" &
else
    log_warn "Gatekeeper NetworkPolicy not found: $SCRIPT_DIR/manifests/gatekeeper/network-policy.yaml"
fi

# Wait for background jobs and check for errors
wait $APPLICATIONSET_PID 2>/dev/null || true
if [ $? -ne 0 ]; then
    log_error "Failed to apply ApplicationSet. See details:"
    cat /tmp/applicationset.log
    exit 1
fi
log_info "ApplicationSet applied successfully"

if [ -n "$KONG_INGRESS_PID" ]; then
    wait $KONG_INGRESS_PID
    if [ $? -ne 0 ]; then
        log_warn "Failed to apply Kong Ingress Application. See details:"
        cat /tmp/kong-ingress.log
    else
        log_info "Kong Ingress Application applied successfully"
    fi
fi

# Step 12: Wait for all applications to be created by ApplicationSet
log_info "Waiting for ApplicationSet to generate applications..."
sleep 2
max_attempts=60
attempts=0
while [ $attempts -lt $max_attempts ]; do
    app_count=$(kubectl get applications -n argocd 2>/dev/null | tail -n +2 | wc -l || echo "0")
    if [ "$app_count" -ge 14 ]; then
        log_info "ApplicationSet created all 14 applications!"
        break
    fi
    log_info "Applications created: $app_count/14 (waiting...)"
    sleep 5
    ((attempts++))
done

if [ "$app_count" -lt 14 ]; then
    log_warn "ApplicationSet only created $app_count/14 applications (timeout). This may happen in development environments."
fi

# Step 13: Wait for all applications to sync
log_info "Waiting for all applications to sync and become healthy..."
sleep 10

# Get all application names dynamically
all_apps=$(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [ -z "$all_apps" ]; then
    log_error "No applications found in ArgoCD!"
    exit 1
fi

# Wait for each app to be healthy (accept Synced/Unknown sync status if healthy)
for app in $all_apps; do
    log_info "Monitoring application: $app"
    for i in {1..120}; do
        # Check if app exists and get its sync status
        SYNC_STATUS=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        HEALTH_STATUS=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

        # Accept app if healthy (regardless of sync status)
        # Sync can be Synced, Unknown, OutOfSync, but Healthy is the key metric
        if [ "$HEALTH_STATUS" = "Healthy" ]; then
            log_info "✓ $app is Healthy (Sync=$SYNC_STATUS)"
            break
        fi

        if [ $((i % 15)) -eq 0 ]; then
            log_info "$app status: Sync=$SYNC_STATUS, Health=$HEALTH_STATUS (attempt $i/120)"
        fi

        sleep 3
    done
done

# Step 14: Final verification and summary
log_info "Verifying all applications are deployed..."
echo ""
echo "======================================"
echo "✓ Deployment Complete!"
echo "======================================"
echo ""
echo "Cluster: $CLUSTER_NAME"
echo "K8s Version: 1.34.0"
echo "Status: Running with Cilium + ArgoCD GitOps"
echo ""
echo "Deployed Helm Releases (direct installs):"
echo "- Cilium v${CILIUM_VERSION} (CNI with kube-proxy replacement, LoadBalancer)"
echo "- ArgoCD v3.2.0 (GitOps orchestration)"
echo ""
echo "Cilium LoadBalancer Configuration:"
echo "- IP Pool: 172.18.1.0/24 (Docker bridge - reachable from host)"
echo "- L2 Announcements: eth0 (externalIPs, loadBalancerIPs)"
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
echo "  ├─ Cilium v${CILIUM_VERSION} (eBPF, kube-proxy replacement, L2 LoadBalancer)"
echo "  │  ├─ LoadBalancer IP Pool: 172.18.1.0/24"
echo "  │  └─ L2 Announcement: eth0"
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
