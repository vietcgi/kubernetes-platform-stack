# Configuration

## Secrets Management

### Using Sealed Secrets

Sealed Secrets encrypt sensitive data so it can safely be stored in git. The cluster has a sealing key that automatically decrypts secrets on-demand.

#### Create a Sealed Secret

Create a secret:

  kubectl create secret generic db-password \
    --from-literal=password='mypassword' \
    -n myapp \
    --dry-run=client -o yaml | kubeseal -f - > db-password-sealed.yaml

This creates a sealed secret file that can be safely committed to git.

#### Apply the Secret

Sealed Secrets controller automatically decrypts:

  kubectl apply -f db-password-sealed.yaml

The original secret is now available in the cluster.

#### Using in ArgoCD Applications

Include sealed secret in Helm values:

  # helm/my-app/values.yaml
  secrets:
    database:
      password: "EAAaAJH7w9JK2wL3pL9Q/12345..."

Then reference in templates:

  # helm/my-app/templates/deployment.yaml
  env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-secret
        key: password

Or create sealed secret file in git:

  # Create sealed secret
  kubectl create secret generic db-password \
    --from-literal=password='mypassword' \
    -n myapp \
    --dry-run=client -o yaml | kubeseal -f - > db-password-sealed.yaml

  # Commit to git
  git add db-password-sealed.yaml
  git commit -m "chore: add sealed db password"
  git push

  # Apply to cluster
  kubectl apply -f db-password-sealed.yaml

### Common Secrets

ArgoCD Admin Password:
- Managed by Sealed Secrets
- Retrieve with: kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d

Grafana Admin Password:
- Default: prom-operator (change via values.yaml)
- Set via: grafana.adminPassword in values.yaml

Database Credentials:
- Store in Sealed Secrets
- Reference from ConfigMaps or environment variables

API Keys and Tokens:
- Store in Sealed Secrets
- Rotate regularly (create new secret, update deployment)

### Key Management

The sealing key is stored in Kubernetes:

  kubectl get secret -n kube-system sealed-secrets-key -o yaml

Backup the key (critical for disaster recovery):

  kubectl get secret -n kube-system sealed-secrets-key -o yaml > backup-sealing-key.yaml

To restore from backup:

  kubectl apply -f backup-sealing-key.yaml
  kubectl delete pod -n kube-system -l app.kubernetes.io/name=sealed-secrets

## Network Policies

Network policies control communication between pods. The platform uses default-deny with explicit allow rules.

### Default Deny

All namespaces have default deny policy:

  kubectl get cnp -n <namespace> default-deny

This blocks all ingress and egress traffic by default.

### Core Policies

DNS (required for all pods):
- Allows pods to query CoreDNS on port 53
- Applied to all namespaces

Pod-to-Pod Communication (same namespace):
- Allows pods within same namespace to communicate
- Enables inter-service communication

### Service-Specific Policies

Prometheus Scraping:
- Allows Prometheus to scrape metrics from all pods
- Configured for port 8080 (default metrics port)

Istio Mesh:
- Allows sidecar proxies to communicate
- Required for mTLS and traffic management

Longhorn Storage:
- Allows Longhorn replicas to sync data
- Enables high availability

Harbor Registry:
- Allows pulling container images
- Allows internal registry communication

Kong Ingress:
- Allows external traffic to Kong
- Kong routes to internal services

### View Policies

List all network policies:

  kubectl get ciliumnetworkpolicies -A

View specific policy:

  kubectl describe cnp <policy-name> -n <namespace>

### Test Connectivity

From within a pod:

  kubectl run debug --image=busybox --rm -it --restart=Never -- \
    wget -O- http://target-service:port

Check if service is accessible:

  kubectl run debug --image=busybox --rm -it --restart=Never -- \
    nslookup target-service

### Add Custom Policy

Create policy file:

  cat > my-app-policy.yaml << 'YAML'
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: my-app
    namespace: default
  spec:
    endpointSelector:
      matchLabels:
        app: my-app
    policyTypes:
    - Ingress
    - Egress
    ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            name: istio-system
      toPorts:
      - ports:
        - port: "8080"
          protocol: TCP
    egress:
    - to:
      - namespaceSelector: {}
      toPorts:
      - ports:
        - port: "53"
          protocol: UDP
  YAML

Apply policy:

  kubectl apply -f my-app-policy.yaml

## Helm Configuration

All platform components use Helm charts with schema validation. Schemas ensure configuration is valid before deployment.

### Schema Files

Each chart has values.schema.json in its root directory:

  helm/
  ├── my-app/
  │   ├── values.schema.json    (schema)
  │   ├── values.yaml           (values)
  │   └── Chart.yaml
  ├── platform-library/
  │   ├── values.schema.json
  │   └── values.yaml

### Validate Helm Values

Validate before deploying:

  helm template my-app ./helm/my-app -f values.yaml

The schema is automatically validated during templating.

Or manually validate with JSON Schema validator:

  pip install jsonschema

  cat > validate.py << 'PYTHON'
  import json
  import yaml
  from jsonschema import validate, ValidationError

  with open('helm/my-app/values.schema.json') as f:
      schema = json.load(f)

  with open('helm/my-app/values.yaml') as f:
      values = yaml.safe_load(f)

  try:
      validate(instance=values, schema=schema)
      print("Validation passed!")
  except ValidationError as e:
      print(f"Validation failed: {e.message}")
      exit(1)
  PYTHON

  python validate.py

### IDE Integration

VS Code with YAML extension automatically validates against schema.

Configure in .vscode/settings.json:

  {
    "yaml.schemas": {
      "helm/my-app/values.schema.json": [
        "helm/my-app/values.yaml"
      ],
      "helm/platform-library/values.schema.json": [
        "helm/platform-library/values.yaml"
      ]
    }
  }

JetBrains IDEs (IntelliJ, etc.):
- Go to Settings > Editor > Code Style > YAML
- Add schema mapping for each chart
- File path pattern: helm/[chart]/values.yaml
- Schema file: helm/[chart]/values.schema.json

### Override Helm Values

Override in ArgoCD Application:

  # argocd/applications/my-app.yaml
  spec:
    source:
      helm:
        values: |
          replicaCount: 5
          image:
            tag: "v2.0"

Or override via values file:

  helm upgrade my-app ./helm/my-app -f override-values.yaml

Or pass individual values:

  helm upgrade my-app ./helm/my-app \
    --set replicaCount=5 \
    --set image.tag=v2.0

### Default Resource Tiers

platform-library provides resource templates:

Small workload:
  resources:
    requests:
      cpu: "50m"
      memory: "64Mi"
    limits:
      cpu: "100m"
      memory: "256Mi"

Medium workload:
  resources:
    requests:
      cpu: "100m"
      memory: "128Mi"
    limits:
      cpu: "500m"
      memory: "512Mi"

Large workload:
  resources:
    requests:
      cpu: "500m"
      memory: "512Mi"
    limits:
      cpu: "1"
      memory: "1Gi"

Use in helm values:

  # helm/my-app/values.yaml
  resources: 
    requests:
      cpu: "100m"      # medium tier
      memory: "128Mi"
    limits:
      cpu: "500m"
      memory: "512Mi"

## ApplicationSet Configuration

ApplicationSet generates 14 platform applications from a single template. It is the source of truth for all platform applications.

### View Generated Applications

List generated applications:

  kubectl get applications -n argocd

Should show all 14 apps: prometheus, loki, tempo, istio, cert-manager, vault, falco, kyverno, gatekeeper, sealed-secrets, external-dns, kong, longhorn, velero, jaeger, harbor.

### Edit ApplicationSet

Edit template in argocd/applicationsets/platform-apps.yaml

To add new application:

  generators:
  - list:
      elements:
      - name: my-new-app
        version: "1.0.0"
        chart: "my-new-app"
        repoURL: "https://charts.example.com"

To update version:

  - name: prometheus
    version: "71.0.0"  (change from "70.10.0")

Commit and push:

  git add argocd/applicationsets/platform-apps.yaml
  git commit -m "feat: update prometheus version"
  git push

ArgoCD will regenerate applications automatically.

### Namespace Management

Platform applications deploy to specific namespaces:

- monitoring: Prometheus, Grafana, Loki, Tempo, Jaeger
- istio-system: Istio control plane
- cert-manager: Certificate manager
- security: Falco, Kyverno, Gatekeeper
- storage: Longhorn, Velero
- api-gateway: Kong, External DNS
- argocd: ArgoCD and Sealed Secrets

Custom applications can use any namespace.

### Auto-Sync Configuration

All applications use auto-sync:

  syncPolicy:
    automated:
      prune: true      (delete removed resources)
      selfHeal: true   (sync if drift detected)

This ensures cluster state matches git state automatically.

## Version Management

All component versions are pinned in argocd/applicationsets/platform-apps.yaml:

metrics-server: 3.12.1
loki: 2.10.2
tempo: 1.8.0
istio: 1.21.0
cert-manager: v1.14.0
vault: 0.28.0
falco: 4.2.1
kyverno: 3.2.1
sealed-secrets: 2.13.2
gatekeeper: 3.17.0
external-dns: 1.14.3
kong: 2.39.0
longhorn: 1.6.0
velero: 7.0.0
jaeger: 3.3.0
harbor: 1.14.0

No wildcard versions are used. This ensures predictable, reproducible deployments.

To update a version:

1. Edit argocd/applicationsets/platform-apps.yaml
2. Change version for component
3. Commit and push
4. ArgoCD automatically applies update

Example:

  - name: prometheus
    version: "71.0.0"  (was "70.10.0")

## TLS Configuration

Cert-Manager automatically provisions TLS certificates.

### Add TLS to Ingress

Update Kong ingress:

  # manifests/kong/ingress-routes.yaml
  metadata:
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt-prod"
  spec:
    tls:
    - hosts:
      - my-app.example.com
      secretName: my-app-tls
    rules:
    - host: my-app.example.com
      http:
        paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: my-app
              port:
                number: 8080

Certificate is automatically created and renewed.

### Manual Certificate

Create certificate manually:

  kubectl create certificate my-app-cert \
    --secret=my-app-tls \
    --issuer=letsencrypt-prod \
    --common-name=my-app.example.com \
    -n default

Check certificate status:

  kubectl describe certificate my-app-cert -n default

## File Structure

Key directories:

  argocd/
  ├── applications/         (custom apps, not in ApplicationSet)
  │   ├── my-app.yaml
  │   ├── kong-ingress.yaml
  │   └── network-policies.yaml
  ├── applicationsets/
  │   └── platform-apps.yaml (source of truth for platform apps)
  
  helm/
  ├── my-app/
  │   ├── Chart.yaml
  │   ├── values.yaml
  │   ├── values.schema.json
  │   └── templates/
  ├── platform-library/     (shared defaults)
  │   ├── Chart.yaml
  │   ├── values.yaml
  │   ├── values.schema.json
  │   └── templates/
  └── [other-charts]/
  
  manifests/
  ├── network-policies/     (centralized policies)
  │   ├── core-policies.yaml
  │   └── service-policies.yaml
  └── kong/                 (ingress routes)
      └── ingress-routes.yaml

## Best Practices

Secrets:
- Always use Sealed Secrets, never commit plaintext secrets
- Rotate secrets regularly
- Backup sealing key for disaster recovery

Network Policies:
- Start with default deny
- Add explicit allow rules for needed communication
- Test connectivity after policy changes

Helm Configuration:
- Use schema validation for all charts
- Pin all versions (no wildcards)
- Document all configuration options
- Use consistent naming conventions

ApplicationSet:
- One application definition per platform component
- Edit ApplicationSet, not individual Application resources
- Use consistent version pinning across all apps

TLS:
- Enable TLS for all external services
- Use automated certificate renewal
- Monitor certificate expiration

Updates:
- Update one component at a time
- Test in staging before production
- Keep git history of all changes
- Use semantic versioning for applications
