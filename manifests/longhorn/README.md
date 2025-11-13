# Longhorn Known Issues

## Webhook Bootstrap Deadlock (v1.5.0+)

**Issue**: Longhorn manager pods may enter CrashLoopBackOff during initial deployment or upgrades due to webhook bootstrap deadlock.

**Root Cause**: Starting in v1.5.0, webhooks were merged into longhorn-manager. During startup, the manager tries to call its own admission webhook before the webhook server is ready, causing a chicken-and-egg problem. Longhorn hardcodes `failurePolicy: Fail` in the manager code and actively reverts any manual patches to `Ignore`.

Additionally, Cilium network policies are incompatible with Longhorn's webhook architecture. When network policies are applied to the longhorn-system namespace, they create a deny-by-default environment that blocks the manager from calling its own webhook service, resulting in "operation not permitted" errors.

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

**Solution**: An **egress-only** network policy has been implemented to work around Cilium's hairpinning bug. The policy:
- Uses empty `endpointSelector: {}` to match all pods in namespace
- Allows all egress to longhorn-system namespace (including self)
- Allows DNS resolution and Kubernetes API access
- **NO ingress rules** - this is critical to avoid the hairpinning bug

**Why This Works**: Cilium bug #27709 causes hairpinned traffic (pod-to-service-to-same-pod) to be denied by ingress policies because return packets don't match the ingress rules. By using an egress-only policy, we:
- Still control what Longhorn can connect to (egress security)
- Avoid creating deny-by-default ingress rules
- Allow hairpinned webhook traffic to work correctly

**Status**: The manual webhook deletion workaround is still required on first deployment. Egress-only policy successfully works around Cilium hairpinning limitations.
