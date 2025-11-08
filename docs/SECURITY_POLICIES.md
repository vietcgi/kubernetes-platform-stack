# Security Policies Documentation

## Overview

This document describes all security controls and policies implemented in the Kubernetes Platform Stack. The platform uses defense-in-depth approach with multiple layers of security.

## Security Layers

### 1. Network Security

#### Cilium Network Policies
All network policies are defined in `k8s/networking/cilium-policies.yaml`.

**Default-Deny Policy**
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: app
spec:
  endpointSelector: {}
  # All traffic denied unless explicitly allowed
```
- No pod can communicate with any other pod by default
- All ingress and egress requires explicit allow rule
- Prevents lateral movement

**Application Ingress Rules**
- Only Istio Ingress Gateway can reach the application
- Only pods in the same namespace can reach the application
- All other traffic is rejected

**Application Egress Rules**
- PostgreSQL: Port 5432 (database access)
- Redis: Port 6379 (cache access)
- DNS: Port 53 (service discovery)
- Kubernetes API: Port 443 (controller operations)
- All other egress is denied

**Cross-Namespace Isolation**
- Pods in "app" namespace cannot reach pods in other namespaces
- Labels enforce namespace boundaries
- Monitoring scrape is explicitly allowed (with proper labels)

**Monitoring Access**
- Prometheus pods (with label `app: prometheus`) can scrape metrics
- Only on port 9090 (metrics endpoint)
- RBAC verifies Prometheus service account

#### Istio mTLS
Configured in `k8s/istio/peer-authentication.yaml`.

**STRICT mTLS Mode**
```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: app
spec:
  mtls:
    mode: STRICT
```
- All pod-to-pod communication must be encrypted with mTLS
- TLS 1.3 by default
- Mutual certificate validation
- Automatic cert rotation
- Invisible to applications (handled by Envoy sidecar)

**Supported Protocols**
- HTTP/1.1, HTTP/2, gRPC
- Automatic protocol detection
- Non-mTLS connections rejected

### 2. Authentication & Authorization

#### Kubernetes RBAC
Every service account has minimal required permissions.

**Application Service Account**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app
  namespace: app
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: my-app
  namespace: app
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get"]
```
- Read-only access to ConfigMaps (configuration)
- Secret access for database credentials
- No pod creation, deletion, or modification

**Service Mesh Service Accounts**
Each component (Falco, Kyverno, Vault, etc.) has dedicated service account with specific permissions.

#### Istio RequestAuthentication
```yaml
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: jwt-auth
  namespace: app
spec:
  jwtRules:
  - issuer: "https://example.com"
    jwksUri: "https://example.com/.well-known/jwks.json"
```
- Validates JWT tokens from external identities
- Supports OAuth2/OIDC flows
- Extracts claims for authorization decisions

#### Authorization Policies
```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: default-deny
  namespace: app
spec:
  rules: []
```
- Default-deny: No request allowed without explicit policy
- Works with RequestAuthentication for JWT validation

**Explicit Allow Rules**
```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-my-app
  namespace: app
spec:
  selector:
    matchLabels:
      app: my-app
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/app/sa/my-app"]
    to:
    - operation:
        methods: ["GET", "POST"]
        paths: ["/api/*", "/health"]
```
- Only my-app service account (mTLS identity)
- Only GET and POST methods
- Only specific paths allowed
- All other requests denied

### 3. Runtime Security

#### Falco Threat Detection
Configured in `k8s/security/falco.yaml`.

**eBPF Mode**
- Kernel-level syscall monitoring
- Zero-overhead when idle
- Real-time threat detection

**Monitored Threats**
1. **Unauthorized Process Execution**
   - Blocks processes not in allowed list
   - Detects suspicious commands

2. **Sensitive File Access**
   - Monitors /etc/shadow, /etc/passwd
   - Alerts on unauthorized access
   - Critical severity

3. **Container Escape Attempts**
   - Detects /proc access patterns
   - Monitors /sys/kernel access
   - Critical severity

4. **Privilege Escalation**
   - Detects sudo, su commands in containers
   - Blocks privilege escalation
   - Critical severity

**Alert Destinations**
- Standard output (logs)
- External webhooks (optional)
- syslog (optional)

#### Kyverno Policy Enforcement
Configured in `k8s/security/kyverno.yaml`.

**Pod Security Enforcement**

1. **Non-Root Requirement**
```yaml
kind: ClusterPolicy
metadata:
  name: require-non-root
spec:
  validationFailureAction: enforce
  rules:
  - name: check-runAsNonRoot
    validate:
      pattern:
        spec:
          securityContext:
            runAsNonRoot: true
```
- All containers must run as non-root user
- UID > 1000 recommended
- Reduces blast radius of container escape

2. **Image Registry Validation**
```yaml
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  validationFailureAction: enforce
  rules:
  - validate:
      pattern:
        spec:
          containers:
          - image: "gcr.io/* | ghcr.io/* | docker.io/* | quay.io/*"
```
- Only approved registries allowed
- gcr.io, ghcr.io, docker.io, quay.io approved
- Prevents supply chain attacks
- Private registries can be added as needed

3. **Resource Limits**
```yaml
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  validationFailureAction: audit
  rules:
  - validate:
      pattern:
        spec:
          containers:
          - resources:
              limits:
                memory: "?*"
                cpu: "?*"
              requests:
                memory: "?*"
                cpu: "?*"
```
- All containers must declare CPU/memory
- Prevents resource starvation attacks
- Audit mode (warnings only)

4. **Read-Only Root Filesystem**
```yaml
kind: ClusterPolicy
metadata:
  name: require-readonly-root-filesystem
spec:
  validationFailureAction: audit
  rules:
  - validate:
      pattern:
        spec:
          containers:
          - securityContext:
              readOnlyRootFilesystem: true
```
- Prevents writes to root filesystem
- Containers can still write to /tmp, /var/tmp
- Reduces persistence of attacks

5. **Privilege Escalation Prevention**
```yaml
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
spec:
  validationFailureAction: enforce
  rules:
  - validate:
      pattern:
        spec:
          containers:
          - securityContext:
              privileged: false
              allowPrivilegeEscalation: false
```
- No privileged containers
- No capability escalation
- Enforced (pods rejected)

6. **Label Requirements**
```yaml
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: audit
  rules:
  - validate:
      pattern:
        metadata:
          labels:
            app: "?*"
            version: "?*"
```
- All pods must have app and version labels
- Enables routing, scaling, and monitoring
- Audit mode (non-blocking)

### 4. Secrets Management

#### Sealed Secrets
Configured in `k8s/security/sealed-secrets.yaml`.

**How It Works**
```yaml
# Original secret in git (UNSAFE!)
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: app
stringData:
  username: admin
  password: secret123

# Transform to sealed secret
kubectl seal --format yaml < secret.yaml > sealed-secret.yaml

# Result: encrypted in git (SAFE!)
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: db-credentials
  namespace: app
spec:
  encryptedData:
    username: AgBvG3M...
    password: AgBfK9D...
```

**Key Management**
- Per-namespace encryption keys
- Keys stored in kube-system namespace
- Automatic key rotation (monthly recommended)
- Can be seeded from Vault

**Unsealing Process**
1. SealedSecret created in cluster
2. Sealing controller detects it
3. Unseals with namespace key
4. Creates regular Secret
5. Application reads Secret
6. Secret never stored in git

#### Vault Integration
Configured in `k8s/security/vault.yaml`.

**Authentication**
- Kubernetes auth method
- Service account token authentication
- No hardcoded credentials

**Secret Storage**
- Encrypted at rest
- Audit logging of access
- TTL on dynamic secrets
- Revocation support

**Database Credentials**
- Static secrets stored in Vault
- Pulled by application on startup
- Rotated via Vault policies
- Sealed-secrets backup for credentials

### 5. Certificate Management

#### Cert-Manager
Configured in `k8s/security/cert-manager.yaml`.

**Issuers**

1. **Self-Signed (Internal)**
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
```
- For internal services
- No external verification
- Self-signed certificate
- Good for testing

2. **Let's Encrypt Staging**
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: istio
```
- For testing Let's Encrypt integration
- Unlimited rate limits
- Invalid certificates (not trusted by browsers)

3. **Let's Encrypt Production**
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: istio
```
- For production use
- Rate-limited (50 certificates per domain per week)
- Valid trusted certificates

**Certificate Provisioning**
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: app-tls
  namespace: app
spec:
  secretName: app-tls
  duration: 2160h  # 90 days
  renewBefore: 720h  # 30 days before expiry
  commonName: app.example.com
  dnsNames:
  - app.example.com
  - "*.app.example.com"
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
```
- Automatic renewal 30 days before expiry
- Valid for 90 days
- Supports wildcard domains
- Stores certificate in sealed Secret

### 6. Policy Enforcement

#### OPA/Gatekeeper
Configured in `k8s/governance/gatekeeper.yaml`.

**Admission Webhooks**
- Runs as ValidatingWebhook
- Intercepts CREATE, UPDATE, PATCH requests
- Applies policies before object creation
- Enforces on violations, audits on violations

**Policies Implemented**

1. **Image Registry Whitelist**
```yaml
kind: K8sAllowedRepos
metadata:
  name: allowed-registries
spec:
  parameters:
    repos:
    - "gcr.io"
    - "ghcr.io"
    - "quay.io"
    - "docker.io"
```
- Only allows specified registries
- Applies to all namespaces except system
- Prevents supply chain attacks

2. **Required Labels**
```yaml
kind: K8sRequiredLabels
metadata:
  name: required-labels
spec:
  parameters:
    labels: ["app", "version"]
```
- All workloads must have app and version labels
- Enables traffic management in service mesh
- Supports pod scheduling and affinity

3. **Block NodePort Services**
```yaml
kind: K8sBlockNodePort
metadata:
  name: block-nodeport
spec:
```
- Services cannot use NodePort type
- Prevents unauthorized direct node access
- Forces use of Istio Ingress Gateway

4. **Prevent Privileged Containers**
```yaml
kind: K8sPSPPrivilegedContainer
metadata:
  name: psp-no-privileged
spec:
```
- Blocks privileged containers
- Blocks containers with special capabilities
- Reduces attack surface

5. **Require Health Probes**
```yaml
kind: K8sRequiredProbes
metadata:
  name: required-probes
spec:
  parameters:
    probes: ["livenessProbe", "readinessProbe"]
```
- All containers must have health checks
- Kubernetes can detect unhealthy pods
- Enables proper traffic routing

6. **Container Resource Limits**
```yaml
kind: K8sContainerLimits
metadata:
  name: container-limits
spec:
  parameters:
    cpu: 1000m
    memory: 512Mi
```
- Containers cannot exceed resource limits
- Prevents resource exhaustion attacks
- Enables fair resource allocation

### 7. Audit Logging

Configured in `k8s/governance/audit-logging.yaml`.

**Audit Policy Levels**

1. **Metadata Level**
   - GET, LIST operations on pods and services
   - Minimal info: user, action, resource
   - Lightweight logging

2. **RequestResponse Level**
   - CREATE, UPDATE, PATCH, DELETE operations
   - Full request and response bodies
   - For ConfigMaps, Secrets, RBAC resources
   - High value for compliance

3. **None Level**
   - Watch operations (too verbose)
   - Authenticated system components
   - Excluded from audit trail

**Captured Information**
```
{
  "level": "RequestResponse",
  "timestamp": "2025-11-07T21:58:00Z",
  "user": {
    "username": "system:admin",
    "uid": "123456",
    "groups": ["system:masters"]
  },
  "objectRef": {
    "apiVersion": "v1",
    "kind": "Secret",
    "namespace": "app",
    "name": "db-credentials"
  },
  "verb": "create",
  "requestObject": {...},
  "responseObject": {...}
}
```

**Log Destinations**
- Fluent Bit (log collector)
- File-based storage (audit logs)
- Optional: syslog, external SIEM

**Retention**
- Default: 30 days (or until disk full)
- Immutable: Cannot be deleted or modified
- Compression: Reduces storage 10x

## Compliance & Standards

### Pod Security Standards
- **Restricted**: Minimum-risk settings
  - Non-root user
  - Read-only root filesystem
  - No privileged escalation
  - No special capabilities
  - Limited volume types

### CIS Kubernetes Benchmark
Controls implemented:
- ✓ RBAC authorization
- ✓ Network policies
- ✓ Pod security policies
- ✓ Secret encryption
- ✓ Audit logging
- ✓ Security scanning

### NIST Cybersecurity Framework
Categories:
- **Identify**: Asset inventory, security policies documented
- **Protect**: Encryption, access controls, firewalls (network policies)
- **Detect**: Runtime monitoring (Falco), audit logging, alerting
- **Respond**: Automated policy enforcement, incident alerting
- **Recover**: Immutable audit logs, backup/restore capabilities

## Security Best Practices

### For Developers
1. Never commit secrets to git (use Sealed Secrets)
2. Always set resource requests/limits
3. Add liveness/readiness probes
4. Use specific image tags (not latest)
5. Add security context to containers
6. Implement health checks
7. Add required labels (app, version)

### For Operators
1. Review network policies regularly
2. Monitor Falco alerts closely
3. Rotate secrets quarterly
4. Review RBAC permissions
5. Update Kyverno policies as needed
6. Monitor certificate expiration
7. Review audit logs for anomalies

### For the Platform
1. Keep Kubernetes version current
2. Keep component versions patched
3. Run security scanning on images
4. Maintain audit log retention
5. Test disaster recovery quarterly
6. Review and update policies annually
7. Conduct security audits

## Incident Response

### Detecting Security Events

**Signs of Compromise**
- High error rate from Falco
- Pod restart loops
- Unusual network traffic (blocked connections)
- Unauthorized API calls (audit logs)
- Certificate/key exposure alerts

### Response Actions

1. **Immediate**
   - Isolate affected pod/node
   - Capture logs and audit trail
   - Notify security team

2. **Investigation**
   - Review Falco alerts
   - Check audit logs
   - Analyze network policies
   - Review pod logs

3. **Recovery**
   - Terminate compromised pods
   - Delete and recreate from clean image
   - Rotate all secrets
   - Update RBAC if credentials exposed

4. **Prevention**
   - Update Kyverno/OPA policies
   - Tighten network policies
   - Increase monitoring
   - Patch vulnerabilities

## Testing Security Policies

### Verify Network Policies
```bash
# Try to reach app from different namespace (should fail)
kubectl run test-pod --image=curlimages/curl -n default \
  -- curl http://my-app.app:8080

# Should timeout or fail
```

### Verify mTLS
```bash
# Check pod sidecar has certificates
kubectl exec -it my-app-xxx -c istio-proxy -n app -- \
  ls -la /etc/istio/certs/

# Should show tls.crt, tls.key, ca.crt
```

### Verify Kyverno Policies
```bash
# Try to create privileged pod (should fail)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
  namespace: app
spec:
  containers:
  - name: nginx
    image: nginx:latest
    securityContext:
      privileged: true
EOF

# Should show policy violation error
```

### Verify OPA Policies
```bash
# Try to use unapproved image registry (should fail)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: bad-image
  namespace: app
spec:
  containers:
  - name: app
    image: myregistry.com/app:latest
EOF

# Should show policy violation error
```

### Verify Audit Logging
```bash
# Create a secret and check audit log
kubectl create secret generic test-secret \
  --from-literal=key=value -n app

# Check audit log captured it
kubectl logs -n audit deployment/audit-logger | grep "test-secret"
```

## References

- [Istio Security](https://istio.io/latest/docs/concepts/security/)
- [Cilium Network Policies](https://docs.cilium.io/en/stable/policy/)
- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Kyverno Policies](https://kyverno.io/policies/)
- [OPA/Gatekeeper](https://open-policy-agent.github.io/gatekeeper/)
