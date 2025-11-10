# ArgoCD Sync Issues - Troubleshooting Guide

## Common Issues and Solutions

### Issue: Applications Show "OutOfSync" Status

**Symptoms:**
- `kubectl get applications -n argocd` shows many applications with `OutOfSync` status
- Applications may be `Healthy` but still `OutOfSync`

**Common Causes:**

1. **Manual Resource Modifications**
   - Someone manually edited resources in the cluster
   - ArgoCD detects drift between git and cluster state

2. **Sync Policy Configuration**
   - `prune: false` means ArgoCD won't delete resources
   - Resources created outside git won't be removed

3. **Helm Chart Values Differences**
   - Values in git differ from what's deployed
   - Helm release state doesn't match desired state

4. **CRD Conversion Issues**
   - CustomResourceDefinitions have conversion webhooks
   - ArgoCD ignores certain fields (configured in `ignoreDifferences`)

**Solutions:**

```bash
# 1. Check what's out of sync
kubectl get application <app-name> -n argocd -o yaml | grep -A 20 "status:"

# 2. See detailed differences
kubectl get application <app-name> -n argocd -o jsonpath='{.status.resources}' | jq '.[] | select(.status == "OutOfSync")'

# 3. Force sync (if you want to overwrite manual changes)
kubectl patch application <app-name> -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'

# 4. Refresh application state
kubectl patch application <app-name> -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

---

### Issue: Applications Show "Unknown" Sync Status

**Symptoms:**
- Applications show `Unknown` sync status
- Health status may also be `Unknown`

**Common Causes:**

1. **Application Just Created**
   - ApplicationSet just generated the application
   - ArgoCD hasn't had time to reconcile yet

2. **Repository Connection Issues**
   - Cannot reach Helm repository
   - Network connectivity problems
   - Repository authentication failures

3. **Chart Not Found**
   - Chart name incorrect
   - Chart version doesn't exist
   - Repository URL wrong

**Solutions:**

```bash
# 1. Check application conditions
kubectl get application <app-name> -n argocd -o jsonpath='{.status.conditions}' | jq '.'

# 2. Check repository connectivity
kubectl get application <app-name> -n argocd -o jsonpath='{.status.conditions}' | jq '.[] | select(.type == "ComparisonError")'

# 3. Verify repository URL is accessible
# For example, if using prometheus-community:
curl -I https://prometheus-community.github.io/helm-charts

# 4. Check ApplicationSet controller logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller --tail=50

# 5. Wait for reconciliation (can take 30-60 seconds)
watch kubectl get applications -n argocd
```

---

### Issue: Applications Show "Unhealthy" Status

**Symptoms:**
- Applications show `Unhealthy` health status
- May be `Synced` but still `Unhealthy`

**Common Causes:**

1. **Pods Not Running**
   - Deployment failed to create pods
   - Pods in CrashLoopBackOff
   - Resource constraints (CPU/Memory limits)

2. **Missing Dependencies**
   - CRDs not installed
   - Required secrets/configmaps missing
   - Service dependencies not ready

3. **Health Check Failures**
   - Liveness/readiness probes failing
   - Application not responding on expected ports

**Solutions:**

```bash
# 1. Check pod status in application namespace
kubectl get pods -n <namespace>

# 2. Check events for errors
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20

# 3. Check specific pod logs
kubectl logs -n <namespace> <pod-name>

# 4. Check deployment status
kubectl get deployment -n <namespace>

# 5. Check for resource constraints
kubectl describe pod -n <namespace> <pod-name> | grep -A 5 "Limits\|Requests"

# 6. Check if CRDs are installed (for cert-manager, etc.)
kubectl get crd | grep <crd-name>

# 7. Check application health details
kubectl get application <app-name> -n argocd -o jsonpath='{.status.health}' | jq '.'
```

---

### Issue: Wildcard Versions Causing Issues

**Problem:**
- ApplicationSet uses `version: "*"` for all charts
- This can cause:
  - Unpredictable upgrades
  - Sync failures when chart structure changes
  - Version conflicts

**Solution:**

Pin versions in `argocd/applicationsets/platform-apps.yaml`:

```yaml
# Before:
version: "*"

# After (example for prometheus):
version: "61.7.1"  # Pin to specific version
```

Or use version constraints:
```yaml
version: ">=61.0.0 <62.0.0"  # Allow patch updates only
```

---

### Issue: Repository Authentication Failures

**Symptoms:**
- Applications fail to sync
- Error messages about authentication
- Repository connection errors

**Solutions:**

```bash
# 1. Check if repository needs credentials
kubectl get secret -n argocd | grep repo

# 2. Add repository credentials (if needed)
argocd repo add <repo-url> \
  --username <username> \
  --password <password> \
  --type helm

# Or via kubectl:
kubectl create secret generic <repo-secret> \
  -n argocd \
  --from-literal=type=helm \
  --from-literal=url=<repo-url> \
  --from-literal=username=<username> \
  --from-literal=password=<password>
```

---

### Issue: CRD Installation Failures

**Problem:**
- Applications like cert-manager require CRDs
- CRDs may fail to install
- Application shows as unhealthy

**Solutions:**

```bash
# 1. Check if CRDs are installed
kubectl get crd | grep cert-manager

# 2. Manually install CRDs if needed
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.crds.yaml

# 3. For cert-manager, ensure CRDs are enabled in values
# In ApplicationSet, cert-manager already has:
# crds:
#   enabled: true
```

---

### Issue: Namespace Creation Failures

**Symptoms:**
- Applications fail to sync
- Error: namespace not found
- `CreateNamespace=true` not working

**Solutions:**

```bash
# 1. Check if namespace exists
kubectl get namespace <namespace>

# 2. Create namespace manually if needed
kubectl create namespace <namespace>

# 3. Check ArgoCD RBAC permissions
kubectl get clusterrole argocd-application-controller -o yaml

# 4. Ensure syncOptions includes CreateNamespace
# Should be in ApplicationSet template:
# syncOptions:
#   - CreateNamespace=true
```

---

### Issue: ApplicationSet Not Generating Applications

**Symptoms:**
- ApplicationSet exists but no applications created
- Applications not appearing in `kubectl get applications`

**Solutions:**

```bash
# 1. Check ApplicationSet status
kubectl get applicationset platform-applications -n argocd -o yaml

# 2. Check ApplicationSet controller logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller --tail=100

# 3. Check for template errors
kubectl get applicationset platform-applications -n argocd -o jsonpath='{.status.conditions}' | jq '.'

# 4. Manually trigger reconciliation
kubectl patch applicationset platform-applications -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# 5. Check if ApplicationSet is using correct generator
kubectl get applicationset platform-applications -n argocd -o jsonpath='{.spec.generators}'
```

---

## Diagnostic Commands

### Quick Status Check

```bash
# Overall status
kubectl get applications -n argocd

# Count by status
kubectl get applications -n argocd -o json | jq -r '[.items[] | .status.sync.status] | group_by(.) | map({status: .[0], count: length})'

# List problematic apps
kubectl get applications -n argocd -o json | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | "\(.metadata.name): Sync=\(.status.sync.status), Health=\(.status.health.status)"'
```

### Detailed Application Analysis

```bash
# Get full application details
kubectl get application <app-name> -n argocd -o yaml

# Check sync operation history
kubectl get application <app-name> -n argocd -o jsonpath='{.status.operationState}' | jq '.'

# Check resource status
kubectl get application <app-name> -n argocd -o jsonpath='{.status.resources}' | jq '.[] | select(.status != "Synced")'
```

### ArgoCD Component Health

```bash
# Check ArgoCD server
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server

# Check application controller
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-application-controller

# Check repository server
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server

# Check ApplicationSet controller
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller
```

---

## Using the Diagnostic Script

Run the automated diagnostic script:

```bash
chmod +x scripts/diagnose-argocd-sync.sh
./scripts/diagnose-argocd-sync.sh
```

This will:
- Check ArgoCD server status
- Analyze all applications
- Identify problematic applications
- Provide specific recommendations
- Show quick fix commands

---

## Prevention Best Practices

1. **Pin Versions**: Don't use `"*"` in ApplicationSet
2. **Enable Auto-Sync Carefully**: Only for stable applications
3. **Use Sync Waves**: Order dependencies correctly
4. **Monitor Regularly**: Set up alerts for sync failures
5. **Document Changes**: Track manual modifications
6. **Test Before Deploy**: Validate Helm charts locally
7. **Use Health Checks**: Ensure applications report health correctly

---

## Getting Help

If issues persist:

1. Check ArgoCD UI: `kubectl port-forward -n argocd svc/argocd-server 8080:443`
2. Review application logs in UI
3. Check controller logs (see diagnostic commands above)
4. Review application events: `kubectl get events -n argocd`
5. Check GitHub issues for known problems


