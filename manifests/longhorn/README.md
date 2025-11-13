# Longhorn Known Issues

## Webhook Bootstrap Deadlock (v1.5.0+)

**Issue**: Longhorn manager pods may enter CrashLoopBackOff during initial deployment or upgrades due to webhook bootstrap deadlock.

**Root Cause**: Starting in v1.5.0, webhooks were merged into longhorn-manager. During startup, the manager tries to call its own admission webhook before the webhook server is ready, causing a chicken-and-egg problem. Longhorn hardcodes `failurePolicy: Fail` in the manager code and actively reverts any manual patches to `Ignore`.

**Symptoms**:
```
Error starting manager: upgrade API version failed: cannot create CRDAPIVersionSetting:
Internal error occurred: failed calling webhook "mutator.longhorn.io": Post
"https://longhorn-admission-webhook.longhorn-system.svc:9502/v1/webhook/mutation?timeout=5s":
context deadline exceeded
```

**Workaround**: Manual intervention required on first deployment:
```bash
# Delete webhook configurations to allow manager to start
kubectl delete validatingwebhookconfiguration longhorn-webhook-validator
kubectl delete mutatingwebhookconfiguration longhorn-webhook-mutator
kubectl delete pod -n longhorn-system -l app=longhorn-manager

# Wait for pod to restart and stabilize (30-45 seconds)
kubectl get pods -n longhorn-system -l app=longhorn-manager -w
```

**References**:
- [Longhorn KB: Manager Stuck in CrashLoopBackOff](https://longhorn.io/kb/troubleshooting-manager-stuck-in-crash-loop-state-due-to-inaccessible-webhook/)
- [GitHub Issue #6259](https://github.com/longhorn/longhorn/issues/6259)
- [GitHub Issue #7842](https://github.com/longhorn/longhorn/issues/7842)

**Status**: This is a known Longhorn v1.5.0+ limitation with no configuration-based solution. The only permanent fix would be upstream changes in Longhorn or downgrading to < v1.5.0 (not recommended).
