# Kind GitOps Platform

A complete Kubernetes platform running in KIND with Cilium, Istio, ArgoCD, and observability stack. Production-ready with security, networking, and GitOps.

Current Status: Production-ready (30 applications deployed and managed via GitOps)

## Quick Start

### Requirements
- Docker (20.10+)
- Kind (0.20+)
- kubectl (1.24+)
- Helm (3.12+)
- kubeseal (optional, for managing secrets)

### Deploy (5 minutes)

```bash
# Clone and setup
git clone https://github.com/vietcgi/kind-gitops-platform.git
cd kind-gitops-platform

# Run deployment (--force recreates cluster if exists)
./deploy.sh --force

# Watch progress
watch kubectl get applications -n argocd

# Default ArgoCD admin password is set to "demo" by bootstrap
# Or use custom password:
./deploy.sh --password "your-secure-password"
```

### Access Services

All services are accessible via Kong ingress with *.demo.local domains:

```bash
# ArgoCD (GitOps)
http://argocd.demo.local

# Prometheus (Metrics)
http://prometheus.demo.local

# Grafana (Dashboards)
http://grafana.demo.local
# Default credentials: admin / demo (or custom password via ./deploy.sh --password)

# Vault (Secrets Management)
http://vault.demo.local

# Jaeger (Distributed Tracing)
http://jaeger.demo.local

# Harbor (Container Registry)
http://harbor.demo.local
```

Add /etc/hosts entries for local access:
```bash
echo "127.0.0.1 argocd.demo.local prometheus.demo.local grafana.demo.local vault.demo.local jaeger.demo.local harbor.demo.local" | sudo tee -a /etc/hosts
```

Get ArgoCD admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## What's Included

### Networking
- Cilium v1.18.4 (eBPF-based CNI with LoadBalancer support, managed by ArgoCD)
- Istio v1.28.0 (service mesh with mTLS)
- Kong v3.x (API gateway)
- External DNS (automatic DNS management)

### Observability
- Prometheus (metrics collection)
- Grafana (dashboards)
- Loki (log aggregation)
- Tempo (distributed tracing)
- Jaeger (advanced tracing)

### Security
- Vault (centralized secrets management)
- External Secrets Operator (syncs from Vault to Kubernetes)
- Sealed Secrets (encrypted secrets in git)
- Kyverno (policy enforcement)
- Gatekeeper (OPA policies)
- Falco (runtime security)
- Cert-Manager (TLS certificates)

### Storage & Backup
- Longhorn (persistent volumes)
- Velero (backup and restore)

### Management
- ArgoCD (GitOps orchestration)
- ApplicationSet (multi-app deployment)

## Documentation

- ARCHITECTURE.md - System design and components
- OPERATIONS.md - How to run, monitor, and troubleshoot
- CONFIGURATION.md - Secrets, network policies, Helm schemas

## Key Features

Clustered Setup: 2 nodes (control-plane + worker)

Version Pinning: All Helm charts pinned to stable versions
- No wildcard versions, prevents surprise breaks

Security Hardened:
- Zero hardcoded credentials
- TLS ready for all services
- Network policies enforced
- RBAC configured

GitOps Management:
- All apps managed via ArgoCD
- Single source of truth (ApplicationSet)
- Auto-sync on git changes
- Self-healing enabled

Network Architecture:
- Cilium native LoadBalancer (172.18.1.0/24)
- Istio mTLS between pods
- Network policies for segmentation
- Centralized policy management

Observability:
- Prometheus scrapes all components
- Grafana dashboards included
- Loki log aggregation
- Tempo distributed traces
- Jaeger tracing UI

## Common Operations

### Deploy New Application

Create Helm chart in helm/my-new-app/, then create ArgoCD application:

```bash
cat > argocd/applications/my-new-app.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-new-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/vietcgi/kind-gitops-platform
    targetRevision: main
    path: helm/my-new-app
  destination:
    server: https://kubernetes.default.svc
    namespace: my-new-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

git add argocd/applications/my-new-app.yaml
git commit -m "feat: add my-new-app"
git push
```

ArgoCD will detect the change and deploy automatically.

### Manage Secrets

For demo environment credentials (ArgoCD, Grafana, Harbor, PostgreSQL):
- Use Vault with External Secrets Operator
- Set password at deployment time: `./deploy.sh --password "secure-password"`
- Credentials are stored in Vault, never in git

For application secrets in git:
- Use Sealed Secrets for encrypted secrets in version control

```bash
# Create secret
kubectl create secret generic db-password \
  --from-literal=password='mypassword' \
  -n myapp \
  --dry-run=client -o yaml | kubeseal -f - > db-password-sealed.yaml

# Commit to git
git add db-password-sealed.yaml
git commit -m "chore: add sealed db-password"
git push

# Sealed Secrets controller auto-decrypts when applied
kubectl apply -f db-password-sealed.yaml
```

See CONFIGURATION.md and DEMO-CREDENTIALS-SETUP.md for details.

### Check Network Policies

```bash
# List policies
kubectl get ciliumnetworkpolicies -A

# View specific policy
kubectl describe cnp <policy-name> -n <namespace>

# Troubleshoot connectivity
kubectl exec -it <pod> -n <namespace> -- \
  wget -O- http://target-service:8080/health
```

### Monitor Cluster

```bash
# Application status
kubectl get applications -n argocd

# Pod status
kubectl get pods -A

# Node status
kubectl get nodes

# Events
kubectl get events -A --sort-by='.lastTimestamp'
```

## Troubleshooting

### Application not syncing

```bash
# Check status
kubectl describe application <app-name> -n argocd

# Check logs
kubectl logs -n argocd deployment/argocd-server

# Manual sync
argocd app sync <app-name>
```

### Pod not starting

```bash
# Check pod status
kubectl describe pod <pod-name> -n <namespace>

# View logs
kubectl logs <pod-name> -n <namespace>

# Common issues:
# - Image not found: kind load docker-image <image>
# - Network policy blocking: kubectl get cnp -n <namespace>
# - Resource limits: kubectl top nodes
```

### Service not accessible

```bash
# Check service
kubectl get svc <service-name> -n <namespace>

# Check endpoints
kubectl get endpoints <service-name> -n <namespace>

# Check network policies
kubectl get cnp -n <namespace>

# Test connectivity
kubectl run debug --image=busybox --rm -it --restart=Never -- \
  wget -O- http://service-name:8080
```

### Istio sidecar not injected

```bash
# Check namespace label
kubectl get namespace <namespace> --show-labels

# Label for injection
kubectl label namespace <namespace> istio-injection=enabled

# Restart pods
kubectl rollout restart deployment <name> -n <namespace>
```

## Architecture Overview

Two-node KIND cluster with:

NODE 1 (Control Plane)
- API Server
- Etcd
- CoreDNS
- Platform services

NODE 2 (Worker)
- Application pods
- Storage pods
- Cache/queue services

NETWORKING LAYER
- Cilium (eBPF data plane)
- Istio (mTLS service mesh)
- Kong (API gateway)

OBSERVABILITY LAYER
- Prometheus (metrics)
- Grafana (dashboards)
- Loki (logs)
- Tempo (traces)

MANAGEMENT LAYER
- ArgoCD (GitOps)
- ApplicationSet (multi-app)
- Sealed Secrets (credential management)

SECURITY LAYER
- Network policies (Cilium)
- RBAC (Kubernetes)
- Pod security (Kyverno)
- Runtime security (Falco)

## Resource Usage

Typical resource consumption (idle):

Component              CPU      Memory
Cilium (per node)      50m      128Mi
Prometheus             100m     512Mi
Grafana                50m      128Mi
Istio                  200m     256Mi
ArgoCD                 300m     512Mi
Other services         100m     256Mi
TOTAL                  ~800m    ~1.7Gi

On a laptop with 4 CPU and 8GB RAM: comfortable headroom
On a laptop with 2 CPU and 4GB RAM: tight but workable

Adjust replica counts in helm/*/values.yaml if needed.

## File Structure

```
.
├── helm/                    # Helm charts for all platform services
│   ├── cilium/             # CNI networking
│   ├── istio/              # Service mesh
│   ├── prometheus/         # Observability
│   ├── vault/              # Secrets management
│   ├── kong/               # API gateway
│   ├── longhorn/           # Storage
│   └── ...                 # Other platform charts
├── argocd/
│   ├── applications/       # Individual app definitions
│   │   ├── kong-ingress.yaml
│   │   └── network-policies.yaml
│   ├── applicationsets/
│   │   └── platform-apps.yaml  # Generates 30 platform apps
├── manifests/
│   ├── network-policies/   # Centralized network policies
│   ├── cilium/             # Cilium config
│   └── kong/               # Kong routes
├── docs/
│   ├── ARCHITECTURE.md
│   ├── OPERATIONS.md
│   ├── CONFIGURATION.md
├── tests/                   # Unit and integration tests
├── src/app.py              # Sample Flask application
├── Dockerfile
├── kind-config.yaml        # KIND cluster config
├── deploy.sh               # Deployment script
└── README.md               # This file
```

## Next Steps

1. Read ARCHITECTURE.md to understand the system design
2. Read OPERATIONS.md for how to run and manage the platform
3. Read CONFIGURATION.md for secrets and customization
4. Deploy to your cluster with ./deploy.sh
5. Access ArgoCD and monitor application deployments

## Support

For issues, see OPERATIONS.md troubleshooting section.

For GitHub issues: https://github.com/vietcgi/kind-gitops-platform/issues

## License

MIT
