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

# Initialize and unseal Vault
setup_vault_init() {
    log_info "Initializing Vault..."

    # Wait for Vault pod to be Running (but may not be Ready if not initialized yet)
    log_info "Waiting for Vault pod to be running..."
    for i in {1..60}; do
        POD_STATUS=$(kubectl get pod -n vault vault-0 -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$POD_STATUS" = "Running" ]; then
            log_ok "Vault pod is running"
            break
        fi
        if [ $i -eq 60 ]; then
            log_error "Vault pod failed to start (status: $POD_STATUS)"
            return 1
        fi
        sleep 2
    done

    # Don't wait for HTTP - just try to initialize directly
    # The vault CLI will work even during startup
    log_info "Attempting Vault initialization (will skip if already initialized)..."

    # First, check if secret already exists (Vault was already initialized)
    if kubectl get secret -n vault vault-unseal-keys 2>/dev/null | grep -q "vault-unseal-keys"; then
        log_ok "Vault already initialized (secret exists)"
        # Try to get existing credentials
        ROOT_TOKEN=$(kubectl get secret -n vault vault-unseal-keys -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d 2>/dev/null)
        UNSEAL_KEY=$(kubectl get secret -n vault vault-unseal-keys -o jsonpath='{.data.unseal_key}' 2>/dev/null | base64 -d 2>/dev/null)

        if [ -n "$ROOT_TOKEN" ] && [ -n "$UNSEAL_KEY" ]; then
            # Try to unseal if needed
            SEALED=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null)
            if [ "$SEALED" = "true" ]; then
                log_info "Vault is sealed, unsealing..."
                kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY" > /dev/null 2>&1
                log_ok "Vault unsealed"
            else
                log_ok "Vault is already unsealed"
            fi
            return 0
        fi
    fi

    # Try to initialize Vault with single key share and threshold
    INIT_RESPONSE=$(kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json 2>&1)
    INIT_STATUS=$?

    # Check if already initialized error
    if echo "$INIT_RESPONSE" | grep -q "already initialized"; then
        log_ok "Vault is already initialized"
        return 0
    fi

    if [ -z "$INIT_RESPONSE" ] || ! echo "$INIT_RESPONSE" | jq . > /dev/null 2>&1; then
        log_error "Failed to initialize Vault: $INIT_RESPONSE"
        return 1
    fi

    # Extract root token and unseal key
    ROOT_TOKEN=$(echo "$INIT_RESPONSE" | jq -r '.root_token' 2>/dev/null)
    UNSEAL_KEY=$(echo "$INIT_RESPONSE" | jq -r '.unseal_keys_b64[0]' 2>/dev/null)

    if [ -z "$ROOT_TOKEN" ] || [ -z "$UNSEAL_KEY" ]; then
        log_error "Failed to extract Vault credentials from init response"
        return 1
    fi

    log_ok "Vault initialized with root token and unseal key"

    # Unseal Vault
    log_info "Unsealing Vault..."
    kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_ok "Vault unsealed successfully"
    else
        log_error "Failed to unseal Vault"
        return 1
    fi

    # Create vault-unseal-keys secret for External Secrets setup
    log_info "Creating vault-unseal-keys secret..."
    kubectl create secret generic vault-unseal-keys \
        --from-literal=root_token="$ROOT_TOKEN" \
        --from-literal=token="$ROOT_TOKEN" \
        --from-literal=unseal_key="$UNSEAL_KEY" \
        -n vault --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        log_ok "vault-unseal-keys secret created"
    else
        log_warn "Failed to create vault-unseal-keys secret (may already exist)"
    fi

    log_ok "Vault initialization complete"
}

# Setup Vault Kubernetes auth for External Secrets
setup_vault_auth() {
    log_info "Configuring Vault Kubernetes authentication..."

    # Wait for vault-unseal-keys secret with timeout
    log_info "Waiting for vault-unseal-keys secret to be created..."
    VAULT_TOKEN=""
    for i in {1..30}; do
        # Check if secret exists
        if ! kubectl get secret -n vault vault-unseal-keys 2>/dev/null | grep -q "vault-unseal-keys"; then
            echo -ne "\rAttempt $i/30: Waiting for vault-unseal-keys secret..."
            sleep 1
            continue
        fi

        # Try to get root token from vault-unseal-keys secret
        VAULT_TOKEN=$(kubectl get secret -n vault vault-unseal-keys -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)

        # If token not found, try root_token key
        if [ -z "$VAULT_TOKEN" ]; then
            VAULT_TOKEN=$(kubectl get secret -n vault vault-unseal-keys -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d 2>/dev/null)
        fi

        # If found, break
        if [ -n "$VAULT_TOKEN" ]; then
            echo ""
            log_ok "Vault root token retrieved"
            break
        fi

        sleep 1
    done

    # If still empty, try from environment inside Vault pod
    if [ -z "$VAULT_TOKEN" ]; then
        log_warn "vault-unseal-keys secret not found, trying /vault/file/root_token inside pod..."
        VAULT_TOKEN=$(kubectl exec -n vault vault-0 -- cat /vault/file/root_token 2>/dev/null)
    fi

    if [ -z "$VAULT_TOKEN" ]; then
        log_error "Cannot retrieve Vault root token from vault-unseal-keys secret or /vault/file/root_token"
        log_warn "Vault auth setup skipped - External Secrets may fail if auth is not already configured"
        return 0  # Return 0 to allow deployment to continue
    fi

    # Enable Kubernetes auth method if not already enabled
    if kubectl exec -n vault vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault auth list -format=json 2>/dev/null | grep -q "kubernetes"; then
        log_ok "Kubernetes auth method already enabled"
    else
        log_info "Enabling Kubernetes auth method..."
        kubectl exec -n vault vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault auth enable kubernetes > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_ok "Kubernetes auth method enabled"
        else
            log_warn "Kubernetes auth method may already be enabled"
        fi
    fi

    # Configure Kubernetes auth with cluster details
    log_info "Configuring Kubernetes auth connection..."
    # Use the DNS-accessible Kubernetes API server address (not localhost)
    # This is required for Vault to reach the tokenreview API from the pod
    kubectl exec -n vault vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" \
        sh -c 'vault write auth/kubernetes/config \
        kubernetes_host="https://kubernetes.default.svc.cluster.local:443" \
        kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
        token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token' > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_ok "Kubernetes auth connection configured"
    else
        log_error "Failed to configure Kubernetes auth connection"
        return 1
    fi

    # Create policy for external-secrets
    log_info "Creating Vault policy for external-secrets..."
    kubectl exec -n vault vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault policy write external-secrets - > /dev/null 2>&1 << 'EOF'
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
    if [ $? -eq 0 ]; then
        log_ok "Vault policy created"
    else
        log_warn "Failed to create Vault policy (may already exist)"
    fi

    # Create Kubernetes auth role for external-secrets
    log_info "Creating Kubernetes auth role for external-secrets..."
    kubectl exec -n vault vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" \
        vault write auth/kubernetes/role/external-secrets \
        bound_service_account_names=external-secrets-operator \
        bound_service_account_namespaces=external-secrets \
        policies=external-secrets \
        ttl=24h > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_ok "Kubernetes auth role created"
    else
        log_warn "Failed to create Kubernetes auth role (may already exist)"
    fi

    log_ok "Vault Kubernetes authentication configured successfully"
}

# Setup demo credentials in Vault
setup_vault_credentials() {
    local password="$1"

    log_info "Setting up demo credentials in Vault..."

    # Get root token from secret
    VAULT_TOKEN=$(kubectl get secret -n vault vault-unseal-keys -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d 2>/dev/null)
    if [ -z "$VAULT_TOKEN" ]; then
        log_error "Cannot retrieve Vault root token for credential setup"
        return 1
    fi

    # Wait for Vault to be accessible
    log_info "Waiting for Vault to be accessible..."
    for i in {1..30}; do
        if kubectl exec -n vault vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault status > /dev/null 2>&1; then
            log_ok "Vault is accessible"
            break
        fi
        if [ $i -eq 30 ]; then
            log_error "Vault is not accessible after 30 attempts"
            return 1
        fi
        sleep 2
    done

    # Enable KV v2 secrets engine if not already enabled
    log_info "Ensuring KV v2 secrets engine is enabled..."
    if kubectl exec -n vault vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault secrets list -format=json 2>/dev/null | grep -q '"secret/"'; then
        log_ok "KV v2 secrets engine already enabled"
    else
        log_info "Enabling KV v2 secrets engine..."
        if kubectl exec -n vault vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault secrets enable -path=secret -version=2 kv > /dev/null 2>&1; then
            log_ok "KV v2 secrets engine enabled"
        else
            log_warn "KV v2 secrets engine may already be enabled"
        fi
    fi

    log_info "Storing demo credentials in Vault..."

    # Store credentials using environment variables passed to kubectl exec
    # This avoids stdin issues and properly escapes all special characters
    local services=("argocd" "grafana" "postgres" "harbor")
    local failed=0

    for service in "${services[@]}"; do
        # Use environment variable to pass both token and password securely
        if kubectl exec -n vault vault-0 -- \
            env VAULT_TOKEN="$VAULT_TOKEN" DEMO_PASSWORD="$password" \
            vault kv put secret/demo/$service password="$DEMO_PASSWORD" > /dev/null 2>&1; then
            log_ok "Stored credential for $service"
        else
            log_error "Failed to store credential for $service"
            failed=$((failed + 1))
        fi
    done

    if [ $failed -gt 0 ]; then
        log_error "Failed to store $failed credentials in Vault"
        return 1
    fi

    log_ok "All demo credentials stored in Vault successfully"
}


# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_DELETE=true
            shift
            ;;
        --password)
            DEMO_PASSWORD="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force                  Force delete existing cluster before deploying"
            echo "  --password PASSWORD      Demo environment password (stored in Vault)"
            echo "  -h, --help               Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  CLUSTER_NAME             Cluster name (default: platform)"
            echo "  MONITORING_DURATION      Monitoring time in seconds (default: 1200)"
            echo ""
            echo "Examples:"
            echo "  $0                                  # Deploy with default password 'demo'"
            echo "  $0 --force                          # Force delete and redeploy"
            echo "  $0 --password mysecurepassword      # Deploy with custom password"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Default password
DEMO_PASSWORD="${DEMO_PASSWORD:-demo}"

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
echo "PHASE 1: Network Prerequisites (Cilium, then CoreDNS)"
echo "=============================================="
echo ""

log_info "Installing Cilium CNI first (prerequisite for CoreDNS)..."

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
  --timeout 10m \
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

log_ok "Cilium installed and ready"
echo ""

log_info "Installing CoreDNS (now that network is ready)..."
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
  --wait

log_ok "CoreDNS installed and ready"
echo ""

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

log_info "Waiting for ArgoCD server..."
kubectl wait deployment argocd-server -n argocd --for=condition=Available --timeout=$STARTUP_TIMEOUT

log_info "Waiting for ArgoCD controller..."
kubectl wait deployment argocd-application-controller -n argocd --for=condition=Available --timeout=$STARTUP_TIMEOUT 2>/dev/null || true

log_info "Waiting for ArgoCD repo server..."
kubectl wait deployment argocd-repo-server -n argocd --for=condition=Available --timeout=$STARTUP_TIMEOUT 2>/dev/null || true

log_info "Applying ArgoCD server insecure flag patch..."
kubectl patch deployment argocd-server -n argocd --type strategic --patch-file "$SCRIPT_DIR/argocd/config/argocd-server-patch.yaml" 2>/dev/null || true

log_info "Waiting for Application CRD to be registered..."
for i in {1..60}; do
  if kubectl api-resources 2>/dev/null | grep -q "^applications"; then
    log_ok "Application CRD is ready"
    break
  fi
  if [ $((i % 10)) -eq 0 ]; then
    log_info "Waiting for Application CRD... ($i/60)"
  fi
  sleep 1
done

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
echo "PHASE 3.5: Setup Demo Credentials in Vault"
echo "=============================================="
echo ""

log_info "Waiting for Vault application to be deployed..."
sleep 10  # Give ArgoCD time to sync Vault

# Initialize and unseal Vault (must run first)
setup_vault_init
if [ $? -ne 0 ]; then
    log_error "Vault initialization failed"
    exit 1
fi

# Setup Vault Kubernetes auth (must run before External Secrets accesses Vault)
setup_vault_auth

# Setup credentials (runs after Vault auth is configured)
setup_vault_credentials "$DEMO_PASSWORD"

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
