# Kubernetes Platform Bootstrap Guide

## One Command Deploy

```bash
bash deploy.sh
```

This runs a 4-phase bootstrap process (~25 minutes):
1. **Phase 1 (3 min)**: Create KIND cluster, patch CoreDNS
2. **Phase 2 (2 min)**: Install ArgoCD
3. **Phase 3 (10s)**: Apply root-app for GitOps
4. **Phase 4 (20 min)**: Monitor cluster health

## Architecture

**Bootstrap Phase (deploy.sh)**:
- Creates KIND cluster with proper resource limits
- Installs ArgoCD official manifests
- Applies root-app (single GitOps entry point)
- Monitors health for 20 minutes to verify success

**Management Phase (ArgoCD)** - After bootstrap:
- ArgoCD manages CoreDNS configuration
- ArgoCD manages Cilium CNI installation
- ArgoCD manages itself (self-management)
- ArgoCD manages all applications

**Key Concept**: We use imperative bootstrap to establish foundations, then declare everything in Git for ArgoCD to manage.

## What Gets Deployed

After bootstrap completes successfully:

**Core Components**:
- CoreDNS (DNS) - patched with resource limits
- Cilium (CNI) - eBPF-based networking with network policies
- ArgoCD (GitOps orchestrator) - manages itself and all apps

**Resource Layout**:
```
argocd/config/kustomization.yaml (root entry point)
├── _namespace.yaml (creates 12+ namespaces)
├── _coredns.yaml (CoreDNS config via Git)
├── _cilium.yaml (Cilium installation via Git)
├── _argocd-config.yaml (ArgoCD self-management)
├── _infra-apps.yaml (Kong, sealed-secrets, etc.)
└── _platform-apps.yaml (dynamic app generation via ApplicationSet)
```

## Using After Bootstrap

**View cluster status**:
```bash
kubectl get applications -n argocd -w
kubectl get pods -A
```

**Access ArgoCD UI**:
```bash
kubectl port-forward -n argocd svc/argocd-server 8080:443
# Open: https://localhost:8080
# User: admin
# Password: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
```

**Deploy new applications**:
1. Add manifest to `argocd/applications/` or `argocd/applicationsets/`
2. Push to Git main branch
3. ArgoCD auto-syncs (usually within 3 minutes)

**Monitor applications**:
```bash
source scripts/health-check.sh
get_app_status "app-name"
get_pod_count "namespace"
```

## Customization

**Change monitoring duration** (default 20 min):
```bash
MONITORING_DURATION=1800 bash deploy.sh  # 30 minutes
```

**Update Cilium version** (edit `argocd/config/_cilium.yaml`):
```yaml
source:
  targetRevision: 1.19.0  # change version
```
Push to Git - ArgoCD updates automatically.

**Adjust resource limits** (edit `argocd/config/_cilium.yaml`):
```yaml
resources:
  limits:
    cpu: 2000m
    memory: 2Gi
```
Push to Git - ArgoCD updates automatically.

## Troubleshooting

**Script hangs during Phase 2 (ArgoCD installation)**:
```bash
# Check if ArgoCD pods are running
kubectl get pods -n argocd
# If stuck > 10 min, increase timeout
STARTUP_TIMEOUT=1200 bash deploy.sh
```

**Applications show OutOfSync after bootstrap**:
This is normal - ArgoCD syncs gradually during bootstrap. Monitor progress:
```bash
kubectl get applications -n argocd -w
```

**Pods not becoming ready**:
```bash
# Check CoreDNS
kubectl logs -n kube-system -l k8s-app=coredns

# Check Cilium
kubectl logs -n kube-system -l k8s-app=cilium

# Check ArgoCD
kubectl logs -n argocd deployment/argocd-application-controller
```

**Restart everything**:
```bash
kind delete cluster --name platform
bash deploy.sh
```

## How It Works

### Phase 1: Network Prerequisites
- Creates KIND cluster
- Waits for API server
- Patches CoreDNS with resource limits (prevents memory issues)
- Waits for CoreDNS pods to be ready
- **Why**: CoreDNS must work before ArgoCD can sync

### Phase 2: Install ArgoCD
- Creates argocd namespace
- Applies official ArgoCD manifests
- Waits for server deployment
- Waits for application controller
- Waits for repo server
- **Why**: ArgoCD needs all components ready before managing apps

### Phase 3: Bootstrap GitOps
- Applies root-app.yaml (single entry point)
- root-app syncs from `argocd/config/` in Git
- Kustomize defines resource ordering
- **Why**: Everything else is declared in Git, ArgoCD takes over

### Phase 4: Active Monitoring (20 minutes)
Every 10 seconds, checks:
- Are all nodes Ready?
- Is root-app synced?
- Are coredns and cilium apps synced?
- Are critical pods running?

Display progress:
```
[5m] Monitoring... 15m 0s remaining
```

After 20 minutes, show final status:
```
root-app             Sync: Synced [✓] Health: Healthy [✓]
coredns-config       Sync: Synced [✓] Health: Healthy [✓]
cilium               Sync: Synced [✓] Health: Healthy [✓]
argocd               Pods: 6/6 [✓]
kube-system          Pods: 8/8 [✓]
Nodes ready: 1/1
```

## Design Rationale

**Why hybrid (imperative bootstrap + declarative GitOps)?**

Previous 100% GitOps approach failed because ArgoCD tried to manage CoreDNS and Cilium before it could work (circular dependency).

This approach solves it:
- **Deploy.sh** (imperative): Creates cluster and installs ArgoCD reliably
- **ArgoCD** (declarative): Manages CoreDNS, Cilium, and all apps
- **Git repository** (single source of truth): All configuration after bootstrap

**Why monitor for 20 minutes?**

Bootstrap has many stages:
- Namespaces created (30s)
- Cilium CNI installs (2-3 min)
- Infrastructure apps deploy (2-3 min)
- Platform apps deploy (5+ min)
- All pods become ready (5+ min)
- Finalizers and reconciliation complete (remaining time)

20 minutes ensures everything completes and stabilizes.

**Why imperative Phase 1-3?**

- CoreDNS and Cilium are networking foundations
- They must be ready BEFORE ArgoCD can work
- Can't be self-managing yet (bootstrap chicken-and-egg)
- After they're ready, ArgoCD takes over configuration management

## Files

**Essential**:
- `deploy.sh` - Bootstrap orchestrator (103 lines)
- `scripts/health-check.sh` - Monitoring functions (56 lines)
- `argocd/bootstrap/root-app.yaml` - GitOps entry point
- `argocd/config/` - All configuration (7 YAML files)

**Not needed after first run**:
- This guide (BOOTSTRAP.md)

## Quick Reference

```bash
# Deploy
bash deploy.sh

# Monitor during (in another terminal)
kubectl get applications -n argocd -w

# Check after
kubectl get pods -A
kubectl get applications -n argocd

# Add new app
# 1. Create manifest in argocd/applications/
# 2. Push to Git
# 3. ArgoCD syncs automatically

# Get ArgoCD password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
```

---

**That's it**. One command, 25 minutes, production-ready cluster with GitOps management.
