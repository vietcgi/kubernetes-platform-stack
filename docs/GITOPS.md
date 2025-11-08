# GitOps with ArgoCD

This guide covers setting up and using ArgoCD for GitOps-style deployments.

## What is GitOps?

GitOps is a way to manage infrastructure and applications using Git as the single source of truth. All changes go through Git pull requests, ensuring auditability and reproducibility.

## Structure

```
argocd/
├── app-of-apps.yaml          # Root application that manages other apps
└── apps/
    ├── application.yaml       # Main app deployment
    ├── infrastructure.yaml    # Database, cache, etc.
    └── observability.yaml     # Prometheus, Grafana, Loki
```

## Installation

ArgoCD is installed automatically in the GitHub Actions pipeline. To install manually:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for it to be ready
kubectl rollout status deployment/argocd-server -n argocd
```

## Accessing ArgoCD

```bash
# Port forward
kubectl port-forward -n argocd svc/argocd-server 8080:443

# Get initial password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Access: https://localhost:8080
# Username: admin
# Password: <from above>
```

## Deploying with App-of-Apps

The app-of-apps pattern creates a root Application that manages other Applications.

1. **app-of-apps.yaml** - Root app pointing to `argocd/apps/`
2. **argocd/apps/application.yaml** - Deploys the main application
3. **argocd/apps/infrastructure.yaml** - Deploys databases, caches
4. **argocd/apps/observability.yaml** - Deploys monitoring stack

Deploy the root app:

```bash
kubectl apply -f argocd/app-of-apps.yaml
```

ArgoCD will automatically create and manage all child applications.

## Syncing Applications

ArgoCD is configured with `automated.prune: true` and `automated.selfHeal: true`, which means:
- Changes in Git automatically deploy to the cluster
- Drift (manual changes) automatically corrects back to Git

Manually sync:

```bash
argocd app sync my-app
argocd app sync app-of-apps
```

## Adding a New Application

1. Create a new file in `argocd/apps/my-new-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-new-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/vietcgi/kubernetes-platform-stack
    targetRevision: main
    path: helm/my-new-app
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

2. Commit and push to main
3. ArgoCD will create and deploy it automatically

## Environment-Specific Deployments

Use Kustomize overlays for different environments:

```bash
# Deploy to dev
argocd app create my-app-dev \
  --repo https://github.com/vietcgi/kubernetes-platform-stack \
  --path kustomize/overlays/dev \
  --dest-server https://kubernetes.default.svc

# Deploy to staging
argocd app create my-app-staging \
  --repo https://github.com/vietcgi/kubernetes-platform-stack \
  --path kustomize/overlays/staging \
  --dest-server https://kubernetes.default.svc

# Deploy to prod
argocd app create my-app-prod \
  --repo https://github.com/vietcgi/kubernetes-platform-stack \
  --path kustomize/overlays/prod \
  --dest-server https://kubernetes.default.svc
```

## Monitoring Sync Status

```bash
# Check all apps
argocd app list

# Check specific app
argocd app get my-app

# Watch in real-time
argocd app wait app-of-apps --timeout 300
```

## Rollback

If something breaks, rollback to previous version:

```bash
argocd app rollback my-app 0
```

## Notifications

ArgoCD can send notifications on sync events to Slack, GitHub, etc.

## Best Practices

1. **Use meaningful commit messages** - Helps track what changed and why
2. **Test in dev first** - Use dev overlay before promoting to prod
3. **Review PRs** - Don't push directly to main
4. **Monitor sync status** - Watch ArgoCD dashboard for sync errors
5. **Keep Git clean** - Don't commit temporary changes
