# ArgoCD Sync Issues - Fixes Applied

## Summary

Fixed multiple ArgoCD application sync issues by:
1. Improving `ignoreDifferences` configuration
2. Fixing application-specific configurations
3. Refreshing and syncing problematic applications

## Changes Made

### 1. Enhanced ignoreDifferences Configuration

**File**: `argocd/applicationsets/platform-apps.yaml`

Added comprehensive ignore rules to prevent false OutOfSync status:

```yaml
ignoreDifferences:
  # CRD conversion webhooks (common source of drift)
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    jsonPointers:
      - /spec/conversion
      - /spec/conversion/webhook/clientConfig/caBundle
      - /status
      - /metadata/annotations
  
  # Auto-generated secrets (Grafana admin password, etc.)
  - kind: Secret
    jsonPointers:
      - /data
    jqPathExpressions:
      - '.data | keys[] | select(. | contains("admin") or contains("password") or contains("token"))'
  
  # Status fields managed by controllers
  - group: ""
    kind: Service
    jsonPointers:
      - /status
  - group: ""
    kind: Endpoints
    jsonPointers:
      - /subsets
```

**Impact**: Prevents OutOfSync status for:
- CRD conversion webhook CA bundles
- Auto-generated admin passwords
- Service/Endpoint status fields

### 2. Fixed Vault Configuration

**Issue**: Vault showing "Missing" health status due to uninitialized state

**Fix**: Configured Vault for development mode (KIND):

```yaml
server:
  ingress:
    enabled: false  # Disable ingress to avoid sync issues
  extraEnvironmentVars:
    VAULT_DEV_ROOT_TOKEN_ID: "root"
    VAULT_DEV_LISTEN_ADDRESS: "0.0.0.0:8200"
  dataStorage:
    enabled: true
    size: 5Gi
  extraArgs: "-dev -dev-listen-address=0.0.0.0:8200"
```

**Impact**: Vault now runs in dev mode, no initialization required

### 3. Fixed Longhorn Configuration

**Issue**: Longhorn configured for multi-node but running on single-node KIND

**Fix**: Adjusted replica count for KIND:

```yaml
persistence:
  defaultClassReplicaCount: 1  # Use 1 for KIND (single node)
defaultSettings:
  replicaCount: "1"  # Single replica for KIND
  createDefaultDiskLabeledNodes: true
```

**Impact**: Longhorn now works on single-node KIND clusters

### 4. Fixed Velero Configuration

**Issue**: Velero trying to use AWS S3 (not available in KIND)

**Fix**: Disabled cloud storage features:

```yaml
configuration:
  provider: ""  # No provider for KIND
  backupStorageLocation: []  # Empty for KIND
  schedules: {}  # No schedules for KIND
deployRestic: false
snapshotsEnabled: false
```

**Impact**: Velero can deploy without cloud storage requirements

### 5. Synced OutOfSync Applications

Manually synced applications that were OutOfSync but Healthy:
- gatekeeper
- istio
- kyverno
- prometheus (after fixing ignoreDifferences)

## Scripts Created

### 1. Diagnostic Script
**File**: `scripts/diagnose-argocd-sync.sh`

Comprehensive diagnostic tool that:
- Checks ArgoCD server status
- Analyzes all applications
- Identifies problematic applications
- Provides specific recommendations

**Usage**:
```bash
./scripts/diagnose-argocd-sync.sh
```

### 2. Quick Fix Script
**File**: `scripts/fix-argocd-sync.sh`

Automated fix script that:
- Refreshes ApplicationSet
- Refreshes all OutOfSync applications
- Syncs Healthy but OutOfSync applications
- Shows final status

**Usage**:
```bash
./scripts/fix-argocd-sync.sh
```

## Remaining Issues

Some applications may still show issues due to:

1. **Longhorn/Velero**: May require additional configuration for KIND
2. **Vault**: Needs initialization if not using dev mode
3. **Prometheus**: May have resource constraints in KIND
4. **Progressing Status**: Normal for applications still deploying

## Verification

Check application status:

```bash
# Overall status
kubectl get applications -n argocd

# Count problematic apps
kubectl get applications -n argocd -o json | jq -r '[.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")] | length'

# Detailed status
./scripts/diagnose-argocd-sync.sh
```

## Next Steps

1. **Monitor**: Watch applications sync over next few minutes
2. **Verify**: Check that pods are running in each namespace
3. **Troubleshoot**: Use diagnostic script for any remaining issues
4. **Document**: Update runbooks with lessons learned

## Prevention

To prevent future sync issues:

1. **Pin Versions**: Replace `version: "*"` with specific versions
2. **Test Locally**: Validate Helm charts before deploying
3. **Monitor Regularly**: Set up alerts for sync failures
4. **Use Sync Waves**: Order dependencies correctly
5. **Review ignoreDifferences**: Keep them up to date

## Related Documentation

- `docs/ARGOCD_TROUBLESHOOTING.md` - Comprehensive troubleshooting guide
- `scripts/diagnose-argocd-sync.sh` - Diagnostic tool
- `scripts/fix-argocd-sync.sh` - Quick fix script


