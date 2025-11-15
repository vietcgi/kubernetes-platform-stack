# Demo Credentials Setup - Bootstrap Process

## Overview

Demo credentials are set up during the **bootstrap phase** using the deploy script. The password is passed as a command-line argument and stored securely in Vault - **never committed to git**.

**Security Model:**
- Password passed as CLI argument (temporary, not stored)
- Deploy script unseals Vault and stores password in KV store
- Only references to Vault paths in git (e.g., `secret/demo/argocd`)
- No plaintext passwords anywhere in codebase
- No sealing keys exposed
- External Secrets auto-syncs from Vault to Kubernetes

## Quick Start

```bash
# Deploy with default password "demo"
./deploy.sh

# Deploy with custom password
./deploy.sh --password "mysecurepassword"

# Force recreate cluster with custom password
./deploy.sh --force --password "newsecurepassword"
```

## How It Works

### 1. Deploy Script Execution

```
deploy.sh --password=demo
  ↓
Cluster bootstrap (Cilium, CoreDNS, ArgoCD, etc.)
  ↓
ArgoCD syncs Vault deployment
  ↓
PHASE 3.5: setup_vault_credentials function runs
  ↓
Script passes password to Vault KV store
  ↓
External Secrets syncs passwords from Vault
  ↓
Applications ready with passwords
```

### 2. What Happens During Bootstrap

**Inside `setup_vault_credentials()` function:**

```bash
# 1. Wait for Vault pod to be running
# 2. Check if Vault is sealed
# 3. Unseal Vault (using development root token)
# 4. Store passwords in Vault KV store:
#    - vault kv put secret/demo/argocd password='demo'
#    - vault kv put secret/demo/grafana password='demo'
#    - vault kv put secret/demo/postgres password='demo'
#    - vault kv put secret/demo/harbor password='demo'
```

### 3. External Secrets Configuration

Git-checked files reference Vault paths (no passwords):

```yaml
# manifests/external-secrets/demo-credentials.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: argocd-secret
spec:
  data:
  - secretKey: admin.password
    remoteRef:
      key: demo/argocd  # ← Path in Vault, NOT the password
```

### 4. Services Get Credentials

```
External Secrets watches Vault
  ↓
Detects password at secret/demo/argocd
  ↓
Creates Kubernetes Secret: argocd-secret
  ↓
ArgoCD reads from Kubernetes Secret
  ↓
ArgoCD hashes password internally
```

## Architecture Diagram

```
Bootstrap Time:
┌─────────────────────────────────────────┐
│ deploy.sh --password=demo               │
│  (CLI argument, not in git)             │
└────────────┬────────────────────────────┘
             │
             ↓
┌─────────────────────────────────────────┐
│ Vault Pod Starts                        │
│ (via ArgoCD sync)                       │
└────────────┬────────────────────────────┘
             │
             ↓
┌─────────────────────────────────────────┐
│ setup_vault_credentials function        │
│  - Unseal Vault                         │
│  - vault kv put secret/demo/* password  │
│  (password not stored anywhere)         │
└────────────┬────────────────────────────┘
             │
             ↓
┌─────────────────────────────────────────┐
│ Vault KV Store                          │
│ secret/demo/argocd: password            │
│ secret/demo/grafana: password           │
│ secret/demo/postgres: password          │
│ secret/demo/harbor: password            │
└────────────┬────────────────────────────┘
             │
             ↓
┌─────────────────────────────────────────┐
│ External Secrets (watches Vault)        │
│ Syncs every 1 hour                      │
└────────────┬────────────────────────────┘
             │
             ↓
┌─────────────────────────────────────────┐
│ Kubernetes Secrets Created              │
│ argocd-secret                           │
│ grafana-admin                           │
│ postgres-secret                         │
│ harbor-admin                            │
└────────────┬────────────────────────────┘
             │
             ↓
┌─────────────────────────────────────────┐
│ Applications Use Secrets                │
│ ArgoCD, Grafana, PostgreSQL, Harbor    │
│ Each hashes password internally         │
└─────────────────────────────────────────┘
```

## Security Properties

### What's Secure

- **Password in memory only**: Passed as CLI argument, used once, then discarded
- **No plaintext in git**: Never committed to version control
- **No sealing keys in git**: Vault manages its own encryption
- **Credentials centralized**: All in Vault, External Secrets syncs on demand
- **Audit trail**: Vault logs all access to credentials
- **Automatic refresh**: External Secrets syncs every 1 hour (or on demand)

### Development vs Production

**This setup is for DEVELOPMENT/DEMO. For production:**

```bash
# Generate cryptographically secure password
openssl rand -base64 32

# Use environment-specific deployment
./deploy.sh --password "$(openssl rand -base64 32)"

# Or use external secret management:
# - AWS Secrets Manager
# - HashiCorp Cloud Platform
# - Azure Key Vault
```

## Troubleshooting

### Credentials Not Syncing

```bash
# Check External Secrets are created
kubectl get externalsecret -A

# Check status
kubectl describe externalsecret argocd-secret -n argocd

# View External Secrets controller logs
kubectl logs -n external-secrets deployment/external-secrets -f
```

### Vault Not Accessible

```bash
# Check Vault pod is running
kubectl get pod -n vault

# Check Vault status
kubectl exec -n vault vault-0 -- vault status

# Check if Vault is sealed
kubectl exec -n vault vault-0 -- vault status -format=json | grep sealed
```

### Applications Can't Get Credentials

```bash
# Check if Kubernetes Secret was created
kubectl get secret argocd-secret -n argocd -o yaml

# Check ExternalSecret sync status
kubectl get externalsecret -n argocd -o yaml

# Check if sync error
kubectl get externalsecret argocd-secret -n argocd -o jsonpath='{.status.conditions}'
```

## Updating Credentials Later

To change credentials after initial deployment:

```bash
# Option 1: Update in Vault directly
kubectl exec -n vault vault-0 -- sh -c \
  "vault kv put secret/demo/argocd password='newpassword'"

# External Secrets will sync within 1 hour
# Or force immediate sync by deleting the secret:
kubectl delete secret argocd-secret -n argocd
# External Secrets recreates it immediately from Vault

# Option 2: Redeploy with new password
./deploy.sh --force --password "newpassword"
```

## Script Reference

### deploy.sh Options

```bash
./deploy.sh [OPTIONS]

Options:
  --force                  Force delete and recreate cluster
  --password PASSWORD      Set demo environment password
  -h, --help               Show help message

Examples:
  ./deploy.sh                           # Deploy with password "demo"
  ./deploy.sh --password "secure123"    # Deploy with custom password
  ./deploy.sh --force --password "new"  # Recreate with new password
```

### Environment Variables

```bash
CLUSTER_NAME=platform ./deploy.sh        # Custom cluster name
MONITORING_DURATION=300 ./deploy.sh      # Custom monitoring time
```

## Git Status

### Files in Git

- `manifests/external-secrets/vault-backend.yaml` - Vault connection config
- `manifests/external-secrets/demo-credentials.yaml` - ExternalSecret references
- `deploy.sh` - Bootstrap script (but NOT the password)
- `.gitignore` - Prevents accidental credential commits

### Files NOT in Git

- Password arguments (passed at runtime)
- Vault initialization keys
- Sealed Vault data exports
- Any `.env` or credential files

## References

- [External Secrets Operator](https://external-secrets.io/)
- [Vault Documentation](https://www.vaultproject.io/docs)
- [GitOps Best Practices](https://www.gitops.tech/)
