# Operations

## Deployment

### Requirements

Docker (20.10+)
Kind (0.20+)
kubectl (1.24+)
Helm (3.12+)
kubeseal (optional, for managing secrets)

### Deploy (5 minutes)

Clone and setup:

  git clone https://github.com/vietcgi/kubernetes-platform-stack.git
  cd kubernetes-platform-stack

Run deployment:

  ./deploy.sh

Watch progress:

  watch kubectl get applications -n argocd

All 17 applications should reach "Synced" and "Healthy" status within 5 minutes.

### Access Services

ArgoCD (GitOps):
  kubectl port-forward -n argocd svc/argocd-server 8080:443
  https://localhost:8080
  
  Get admin password:
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d

Prometheus (Metrics):
  kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
  http://localhost:9090

Grafana (Dashboards):
  kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
  http://localhost:3000
  
  Default credentials: admin / prom-operator

Kong Admin (API Gateway):
  kubectl port-forward -n api-gateway svc/kong-kong-admin 8444:8444
  https://localhost:8444/admin

## Monitoring

### Check Application Status

List all applications:

  kubectl get applications -n argocd

Check specific application:

  kubectl describe application <app-name> -n argocd

Expected status: Synced, Healthy (for all 17 applications)

### Check Pod Status

List all pods:

  kubectl get pods -A

View pod logs:

  kubectl logs <pod-name> -n <namespace>

Follow pod logs:

  kubectl logs -f <pod-name> -n <namespace>

### Check Node Status

List nodes:

  kubectl get nodes

View node details:

  kubectl describe node <node-name>

### View Events

List recent events:

  kubectl get events -A --sort-by='.lastTimestamp'

Watch events in real-time:

  kubectl get events -A --watch

## Common Operations

### Deploy New Application

Create Helm chart in helm/my-app/

Then create ArgoCD application:

  cat > argocd/applications/my-app.yaml <<'YAML'
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: my-app
    namespace: argocd
  spec:
    project: default
    source:
      repoURL: https://github.com/vietcgi/kubernetes-platform-stack
      targetRevision: main
      path: helm/my-app
    destination:
      server: https://kubernetes.default.svc
      namespace: my-app
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
      - CreateNamespace=true
  YAML

Commit and push:

  git add argocd/applications/my-app.yaml
  git commit -m "feat: add my-app"
  git push

ArgoCD will detect the change and deploy automatically.

### Add to ApplicationSet (for platform apps)

Edit argocd/applicationsets/platform-apps.yaml

Add to generators.list.elements:

  - name: my-new-app
    version: "1.0.0"
    chart: "my-new-app"
    repoURL: "https://charts.example.com"

Then commit:

  git add argocd/applicationsets/platform-apps.yaml
  git commit -m "feat: add my-new-app to platform"
  git push

### Manage Secrets

Create secret and encrypt with Sealed Secrets:

  kubectl create secret generic db-password \
    --from-literal=password='mypassword' \
    -n myapp \
    --dry-run=client -o yaml | kubeseal -f - > db-password-sealed.yaml

Commit to git:

  git add db-password-sealed.yaml
  git commit -m "chore: add sealed db-password"
  git push

Sealed Secrets controller automatically decrypts when applied:

  kubectl apply -f db-password-sealed.yaml

See CONFIGURATION.md for detailed secrets management.

### Check Network Policies

List all network policies:

  kubectl get ciliumnetworkpolicies -A

View specific policy:

  kubectl describe cnp <policy-name> -n <namespace>

Test connectivity between pods:

  kubectl run debug --image=busybox --rm -it --restart=Never -- \
    wget -O- http://target-service:8080/health

Check if network policies are blocking:

  kubectl get cnp -n <namespace>

## Troubleshooting

### Application not syncing

Check application status:

  kubectl describe application <app-name> -n argocd

Check ArgoCD logs:

  kubectl logs -n argocd deployment/argocd-server

Manual sync:

  argocd app sync <app-name>

### Pod not starting

Check pod status:

  kubectl describe pod <pod-name> -n <namespace>

View logs:

  kubectl logs <pod-name> -n <namespace>

Common issues:

Image not found - load the Docker image:
  kind load docker-image <image> --name platform

Network policy blocking - check policies:
  kubectl get cnp -n <namespace>

Resource limits - check node resources:
  kubectl top nodes

### Service not accessible

Check service:

  kubectl get svc <service-name> -n <namespace>

Check endpoints:

  kubectl get endpoints <service-name> -n <namespace>

Check network policies:

  kubectl get cnp -n <namespace>

Test connectivity from pod:

  kubectl run debug --image=busybox --rm -it --restart=Never -- \
    wget -O- http://service-name:8080

### Istio sidecar not injected

Check namespace label:

  kubectl get namespace <namespace> --show-labels

Label for injection:

  kubectl label namespace <namespace> istio-injection=enabled

Restart pods:

  kubectl rollout restart deployment <name> -n <namespace>

### Pod in CrashLoopBackOff

Check logs for errors:

  kubectl logs <pod-name> -n <namespace>

Check resource limits:

  kubectl describe pod <pod-name> -n <namespace>

Check probes configuration:

  kubectl get pod <pod-name> -n <namespace> -o yaml | grep -A 10 "Probe"

### High memory usage

Check pod memory usage:

  kubectl top pods -A --sort-by=memory

List pods using most memory:

  kubectl top pods -A --sort-by=memory | head -20

Increase memory limits in values.yaml:

  # In helm/[chart]/values.yaml
  resources:
    limits:
      memory: "1Gi"

### High CPU usage

Check pod CPU usage:

  kubectl top pods -A --sort-by=cpu

Check node CPU:

  kubectl top nodes

Check HPA status:

  kubectl get hpa -A

## Scaling

### Scale deployment manually

Scale a deployment:

  kubectl scale deployment <name> --replicas=3 -n <namespace>

### Configure autoscaling

Edit Helm values:

  # In helm/[chart]/values.yaml
  autoscaling:
    enabled: true
    minReplicas: 1
    maxReplicas: 10
    targetCPUUtilizationPercentage: 80
    targetMemoryUtilizationPercentage: 80

Apply changes:

  helm upgrade [release] helm/[chart] -n [namespace] -f values.yaml

## Backup and Restore

### Backup namespace

Backup entire namespace:

  velero backup create backup-name --include-namespaces <namespace>

List backups:

  velero backup get

Check backup status:

  velero backup describe backup-name

### Restore from backup

Restore namespace:

  velero restore create --from-backup backup-name

List restores:

  velero restore get

Check restore status:

  velero restore describe restore-name

## Updates

### Update Helm chart version

Edit ApplicationSet or Application:

  # In argocd/applicationsets/platform-apps.yaml or
  # argocd/applications/app-name.yaml
  spec:
    source:
      chart: my-app
      targetRevision: "2.0.0"  # Change version here

Commit:

  git add argocd/applicationsets/platform-apps.yaml
  git commit -m "feat: update my-app to 2.0.0"
  git push

ArgoCD will automatically sync the new version.

### Update application configuration

Edit values in helm/[chart]/values.yaml

Or override via ArgoCD:

  # In argocd/applications/app-name.yaml
  spec:
    source:
      helm:
        values: |
          replicaCount: 5
          image:
            tag: "v2.0"

Commit and push:

  git commit -m "feat: update app configuration"
  git push

### Sync ArgoCD manually

Sync all applications:

  kubectl -n argocd get application -o name | xargs -I {} \
    kubectl -n argocd patch {} --type merge -p \
    '{"operation":"sync"}'

Or use ArgoCD UI to sync individual apps.

## Maintenance

### Clean up old resources

Remove completed pods:

  kubectl delete pod --field-selector status.phase=Succeeded -A

Remove failed pods:

  kubectl delete pod --field-selector status.phase=Failed -A

Remove unused PVCs:

  kubectl get pvc -A
  kubectl delete pvc <pvc-name> -n <namespace>

### Check certificate expiration

List certificates:

  kubectl get certificate -A

Check specific certificate:

  kubectl describe certificate <cert-name> -n <namespace>

Cert-Manager automatically renews before expiration.

### Rotate secrets

For secrets managed by Sealed Secrets, re-seal the secret:

  kubectl get secret <secret-name> -n <namespace> -o yaml | \
    kubeseal -f - > sealed-secret.yaml

  kubectl apply -f sealed-secret.yaml

For secrets generated by Vault, coordinate with Vault admin.

## Health Checks

### Verify cluster health

Check all nodes are ready:

  kubectl get nodes
  
  Expected: All nodes showing "Ready" status

Check all pods are running:

  kubectl get pods -A
  
  Expected: All pods in "Running" or "Completed" status

Check all applications are synced:

  kubectl get applications -n argocd
  
  Expected: All 17 applications showing "Synced" and "Healthy"

Check DNS resolution:

  kubectl run debug --image=busybox --rm -it --restart=Never -- \
    nslookup kubernetes.default

Test external connectivity:

  kubectl run debug --image=busybox --rm -it --restart=Never -- \
    wget -O- http://google.com

### Check component health

Check Cilium status:

  kubectl get ds -n kube-system cilium

Check Istio status:

  kubectl get pods -n istio-system
  kubectl get crd | grep istio

Check ArgoCD status:

  kubectl get pods -n argocd

Check Prometheus:

  kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
  curl http://localhost:9090/-/healthy

Check Grafana:

  kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
  curl -s http://localhost:3000/api/health | grep -o '"status":"[^"]*"'

## Performance Tuning

### Enable resource quotas

Create resource quota:

  kubectl create quota compute-quota \
    --hard=requests.cpu=4,requests.memory=8Gi \
    -n default

### Enable limit ranges

Create limit range:

  kubectl create limitrange cpu-memory-limit \
    --max-cpu=2,--max-memory=2Gi \
    -n default

### Monitor resource usage

Check real-time resource usage:

  watch kubectl top pods -A

View historical metrics in Prometheus:

  kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
  
  Query examples:
  - container_memory_usage_bytes (memory)
  - rate(container_cpu_usage_seconds_total[5m]) (CPU)
  - up (component health)

### Profile application

Enable Prometheus scraping:

  # In helm/[chart]/values.yaml
  monitoring:
    enabled: true
    port: 8080
    path: /metrics

View metrics in Grafana:

  kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
  Visit http://localhost:3000 and view dashboards
