# Kustomize for Environment Management

Kustomize helps manage multiple environments (dev, staging, prod) with a single base configuration.

## Structure

```
kustomize/
├── base/                         # Base configuration
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── configmap.yaml
│   └── ingress.yaml
└── overlays/                     # Environment-specific changes
    ├── dev/
    ├── staging/
    └── prod/
```

## Base Configuration

The base contains the standard deployment configuration that all environments use.

```bash
# View base manifests
kustomize build kustomize/base
```

## Development Environment

Dev environment has:
- 1 replica (lower resource usage)
- Smaller memory limits (64Mi->256Mi)
- Image tag: `dev`

```bash
# Deploy to dev
kustomize build kustomize/overlays/dev | kubectl apply -f -

# Or with ArgoCD
argocd app create my-app-dev \
  --repo https://github.com/vietcgi/kubernetes-platform-stack \
  --path kustomize/overlays/dev
```

## Staging Environment

Staging has:
- 2 replicas
- Medium resources (128Mi->512Mi)
- Image tag: `staging`

Mirrors production setup but with fewer resources.

```bash
kustomize build kustomize/overlays/staging | kubectl apply -f -
```

## Production Environment

Production has:
- 3 replicas
- Full resources (256Mi->1Gi)
- Image tag: `v1.0.0` (specific version)
- Pod anti-affinity (spreads pods across nodes)
- Service type: ClusterIP (use Ingress)

```bash
kustomize build kustomize/overlays/prod | kubectl apply -f -
```

## Common Kustomization Operations

### Patching Values

Overlays use `patchesJson6902` to change specific fields:

```yaml
patchesJson6902:
- target:
    kind: Deployment
    name: my-app
  patch: |-
    - op: replace
      path: /spec/replicas
      value: 3
```

### Changing Images

```yaml
images:
- name: my-app
  newTag: v1.2.3
```

### Adding Labels

```yaml
commonLabels:
  environment: production
  team: platform
```

### Adding Namespace

```yaml
namespace: app-prod
```

## Viewing Output

Before applying, always preview:

```bash
kustomize build kustomize/overlays/prod

# Or with kubectl
kubectl kustomize kustomize/overlays/prod
```

## Deploying

```bash
# Apply to cluster
kustomize build kustomize/overlays/prod | kubectl apply -f -

# Or with kubectl
kubectl apply -k kustomize/overlays/prod

# With ArgoCD (recommended)
argocd app create my-app-prod \
  --repo https://github.com/vietcgi/kubernetes-platform-stack \
  --path kustomize/overlays/prod
```

## Advanced: Custom Patches

Create a `kustomization.yaml` patch for complex changes:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
- ../../base

patchesStrategicMerge:
- deployment.yaml

replicas:
- name: my-app
  count: 5
```

Then create `deployment.yaml` with partial changes to merge.

## Debugging Kustomize

If output looks wrong:

```bash
# Verbose output
kustomize build -v kustomize/overlays/prod

# Check what resources would be created
kubectl kustomize kustomize/overlays/prod | kubectl get -f - --dry-run=client
```

## Best Practices

1. **Keep base generic** - Base should work for all environments
2. **Use overlays for changes** - Don't modify base per environment
3. **Test locally first** - Run `kustomize build` before applying
4. **Use descriptive patches** - Comment why each change exists
5. **Consistent naming** - Use same resource names in base and overlays
