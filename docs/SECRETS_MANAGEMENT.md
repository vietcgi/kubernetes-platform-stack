# Secrets Management Guide

## Overview

This platform uses **Sealed Secrets** (bitnami-labs/sealed-secrets) for securely storing and managing credentials in Git. Sealed Secrets encrypts sensitive data so it can be safely committed to version control without exposing plaintext passwords.

**CRITICAL RULE**: Never commit plaintext credentials, API keys, or passwords to Git. Always use Sealed Secrets or external secret management.

---

## Sealed Secrets Architecture

### How It Works
1. **Public Key**: Distributed in the cluster, used to encrypt secrets before Git commit
2. **Private Key**: Stored securely in the cluster (sealing-key), used to decrypt secrets at runtime
3. **SealedSecret**: A custom Kubernetes resource that contains encrypted data
4. **Secret**: The sealed-secrets controller automatically decrypts SealedSecrets into regular Kubernetes Secrets

### Key Files
- Controller: `argocd/applications/sealed-secrets.yaml`
- Configuration: `helm/sealed-secrets/values.yaml`
- Public Key: Stored in the sealed-secrets pod, can be exported for offline sealing

---

## Using Sealed Secrets

### 1. Create a Secret (Plain Kubernetes Secret)

First, create a temporary Kubernetes Secret with your sensitive data:

```bash
# Example: Creating a secret for ArgoCD admin password
kubectl create secret generic argocd-admin-secret \
  --from-literal=password='your-strong-password-here' \
  -n argocd \
  --dry-run=client \
  -o yaml > argocd-admin-secret.yaml
```

### 2. Seal the Secret

Install the `kubeseal` CLI tool first:

```bash
# macOS
brew install kubeseal

# Linux
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.25.0/kubeseal-0.25.0-linux-amd64.tar.gz
tar xfz kubeseal-0.25.0-linux-amd64.tar.gz
sudo mv kubeseal /usr/local/bin/
```

Then seal the secret:

```bash
# Seal the secret (output as encrypted YAML)
kubeseal -f argocd-admin-secret.yaml -w sealed-argocd-admin-secret.yaml

# Or pipe directly
kubectl create secret generic argocd-admin-secret \
  --from-literal=password='your-strong-password-here' \
  -n argocd \
  --dry-run=client \
  -o yaml | kubeseal -f - > sealed-argocd-admin-secret.yaml
```

### 3. Commit to Git

```bash
# Delete the unencrypted secret file
rm argocd-admin-secret.yaml

# Commit the sealed secret to Git
git add sealed-argocd-admin-secret.yaml
git commit -m "chore: add sealed ArgoCD admin secret"
git push
```

### 4. Apply the SealedSecret to the Cluster

```bash
# The sealed-secrets controller will automatically decrypt and create the Secret
kubectl apply -f sealed-argocd-admin-secret.yaml

# Verify the Secret was created
kubectl get secret argocd-admin-secret -n argocd
kubectl get sealedsecret -n argocd
```

---

## Using Sealed Secrets with Helm Values

### Method 1: Reference External Secret

Update your Helm values to reference the Secret created by SealedSecret:

**values.yaml**:
```yaml
# ArgoCD admin password - referenced from external sealed secret
argocd:
  configs:
    secret:
      existingSecret: argocd-admin-secret  # Name of the Secret created by SealedSecret
      existingSecretPassword: password      # Key in the Secret
```

### Method 2: Use secretGenerator in kustomization

Create a `kustomization.yaml` that applies both the SealedSecret and uses it:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- sealed-argocd-admin-secret.yaml

vars:
- name: ARGOCD_PASSWORD
  objref:
    kind: Secret
    name: argocd-admin-secret
    apiVersion: v1
  fieldref:
    fieldpath: data.password

replicas:
- name: argocd
  count: 1
```

---

## Creating Sealed Secrets for Different Applications

### ArgoCD Admin Password

```bash
kubectl create secret generic argocd-initial-admin \
  --from-literal=password='admin@123456' \
  -n argocd \
  --dry-run=client \
  -o yaml | kubeseal -f - > manifests/sealed-secrets/argocd-admin.yaml
```

### Grafana Admin Password

```bash
kubectl create secret generic grafana-admin-credentials \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='grafana@123456' \
  -n monitoring \
  --dry-run=client \
  -o yaml | kubeseal -f - > manifests/sealed-secrets/grafana-admin.yaml
```

### Database Credentials

```bash
kubectl create secret generic postgres-credentials \
  --from-literal=username=postgres \
  --from-literal=password='db-secure-password' \
  --from-literal=url='postgresql://postgres:db-secure-password@postgres:5432/mydb' \
  -n app \
  --dry-run=client \
  -o yaml | kubeseal -f - > manifests/sealed-secrets/postgres-credentials.yaml
```

### Registry Credentials (For Private Docker Registry)

```bash
kubectl create secret docker-registry regcred \
  --docker-server=docker.io \
  --docker-username=myusername \
  --docker-password=mytoken \
  --docker-email=user@example.com \
  -n app \
  --dry-run=client \
  -o yaml | kubeseal -f - > manifests/sealed-secrets/docker-registry.yaml
```

### API Keys and Tokens

```bash
kubectl create secret generic api-keys \
  --from-literal=github-token='ghp_xxxxxxxxxxxxx' \
  --from-literal=slack-webhook='https://hooks.slack.com/services/xxx' \
  --from-literal=datadog-api-key='dd_xxxxxxxxxxxxx' \
  -n app \
  --dry-run=client \
  -o yaml | kubeseal -f - > manifests/sealed-secrets/api-keys.yaml
```

---

## Exporting the Public Key (For Offline Sealing)

If you want to seal secrets offline (without cluster access):

```bash
# Get the public key from the cluster
kubectl get secret -n sealed-secrets sealing-key -o jsonpath='{.data.tls\.crt}' | base64 -d > sealing-key.crt

# Use it with kubeseal
kubeseal --cert sealing-key.crt -f argocd-admin-secret.yaml -w sealed-argocd-admin-secret.yaml
```

---

## Best Practices

### ✅ DO:
- **Always seal sensitive data** before committing to Git
- **Use scope-specific sealing** (target namespace and name)
- **Rotate sealing keys** periodically (at least annually)
- **Back up the sealing key** securely (off-site, encrypted)
- **Use long, complex passwords** (minimum 32 characters)
- **Document password policies** for your organization
- **Audit sealed secret usage** with Git history
- **Use different secrets** for different environments (dev/staging/prod)

### ❌ DON'T:
- **Commit unencrypted secrets** to Git
- **Share sealing keys** publicly or via email
- **Use default passwords** in production
- **Store sealing keys** in the same Git repo
- **Use plaintext comments** that reveal password hints
- **Reuse credentials** across different services
- **Commit temporary secret files** (remove with `.gitignore`)

---

## Sealing Key Management

### Backup the Sealing Key

```bash
# Export the sealing key
kubectl get secret -n sealed-secrets sealing-key -o yaml > sealing-key-backup.yaml

# Store in secure location (encrypted, offline backup)
# This is needed for disaster recovery
```

### Key Rotation

```bash
# Get current key ID
kubectl logs -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets | grep "sealing key"

# When rotating (advanced topic):
# 1. Generate new sealing key
# 2. Reseal all secrets with new key
# 3. Store old key separately for disaster recovery
```

### Disaster Recovery

If sealing keys are lost:
1. Cluster becomes unable to decrypt sealed secrets
2. Applications using sealed secrets will fail to start
3. Regenerate secrets from:
   - External secret management (Vault, AWS Secrets Manager)
   - Secure backup of sealing key
   - Last known working backup

---

## Integration with External Secret Management

### Vault Integration

For enterprise environments, integrate with HashiCorp Vault:

```yaml
# Using External Secrets Operator
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: app
spec:
  provider:
    vault:
      server: "http://vault.vault:8200"
      path: "secret"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "app-role"
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-secrets
  namespace: app
spec:
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: app-secrets
    creationPolicy: Owner
  data:
  - secretKey: password
    remoteRef:
      key: app/password
```

### AWS Secrets Manager

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets
  namespace: app
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
```

---

## Troubleshooting

### Secret Not Decrypting

```bash
# Check sealed-secrets logs
kubectl logs -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets

# Verify SealedSecret resource
kubectl describe sealedsecret <name> -n <namespace>

# Check if Secret was created
kubectl get secret <name> -n <namespace>
```

### Scope Mismatch Error

```bash
# Error: "secret is scoped to a different namespace"
# Solution: Reseal with correct namespace
kubeseal -f secret.yaml -n <target-namespace> -w sealed-secret.yaml

# Or add scope annotation
kubectl annotate sealedsecret <name> sealedsecrets.bitnami.com/scope=namespace -n <namespace>
```

### Lost Sealing Key

```bash
# Check if backup exists
ls -la sealing-key-backup.yaml

# Restore from backup (WARNING: Destructive)
kubectl apply -f sealing-key-backup.yaml

# Restart sealed-secrets pod
kubectl rollout restart deployment/sealed-secrets-controller -n sealed-secrets
```

---

## Migration Path: From Plaintext to Sealed Secrets

### Step 1: Identify Current Plaintext Secrets

```bash
# Search for common patterns
grep -r "password:" helm/ manifests/ --include="*.yaml"
grep -r "token:" helm/ manifests/ --include="*.yaml"
grep -r "apiKey:" helm/ manifests/ --include="*.yaml"
```

### Step 2: Create Sealed Secrets for Each

```bash
# For each plaintext secret found, create sealed version
for secret in $(grep -r "password:" helm/ --include="*.yaml" | cut -d: -f1 | sort -u); do
  # Extract and seal each one
done
```

### Step 3: Update Helm Values

Update values.yaml files to reference sealed secrets instead of plaintext values.

### Step 4: Deploy with ArgoCD

ArgoCD will apply both SealedSecrets and applications that reference them.

---

## Examples

See the following files for working examples:
- `manifests/sealed-secrets/` - Sealed secret examples
- `argocd/applications/sealed-secrets.yaml` - Application definition
- `helm/sealed-secrets/` - Sealed-Secrets Helm chart configuration

---

## Additional Resources

- [Sealed Secrets GitHub](https://github.com/bitnami-labs/sealed-secrets)
- [Sealed Secrets Documentation](https://sealed-secrets.netlify.app/)
- [Kubernetes Secrets Documentation](https://kubernetes.io/docs/concepts/configuration/secret/)
- [Best Practices for Managing Secrets](https://kubernetes.io/docs/concepts/configuration/secret/#best-practices)

---

**Last Updated**: 2025-11-09
**Maintained By**: Platform Engineering Team
