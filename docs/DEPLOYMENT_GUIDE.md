# Kubernetes Platform Stack - Deployment Guide

## Prerequisites

### System Requirements
- Docker Desktop (or Docker Engine on Linux)
- kubectl v1.34.0+
- Helm 3.x
- 6 CPU cores minimum
- 12GB RAM minimum
- 20GB disk space

### Software Installation
```bash
# Install kind (if not already installed)
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Verify installations
kind --version
kubectl version --client
helm version
docker --version
```

## Quick Start (5 minutes)

### 1. Clone the Repository
```bash
git clone https://github.com/vietcgi/kubernetes-platform-stack.git
cd kubernetes-platform-stack
```

### 2. Deploy Everything
```bash
bash deploy.sh
```

This script will:
1. Delete any existing "platform" cluster
2. Create a new KIND cluster (3 nodes, v1.34.0)
3. Build Docker image for the application
4. Load image into the cluster
5. Install and configure ArgoCD
6. Deploy the app-of-apps (master application)
7. Wait for all applications to sync

Expected time: 2-5 minutes

### 3. Verify Deployment
```bash
# Check cluster status
kubectl get nodes

# Check ArgoCD applications
kubectl get applications -n argocd

# Check all pods across cluster
kubectl get pods -A

# View ArgoCD UI
kubectl port-forward -n argocd svc/argocd-server 8080:443
# Open https://localhost:8080
# Get password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Detailed Deployment Steps

### Step 1: Cluster Creation
```bash
kind create cluster --config kind-config.yaml --name platform
```

**What it does:**
- Creates 3 KIND nodes (1 control-plane + 2 workers)
- Kubernetes v1.34.0
- Port mappings: 80, 443, 8080 for ingress traffic
- Cilium CNI (no kube-proxy)

**Verify:**
```bash
kubectl get nodes
# Output should show 3 ready nodes
```

### Step 2: Build and Load Docker Image
```bash
# Build Flask application
docker build -t kubernetes-platform-stack:latest .

# Load into KIND cluster
kind load docker-image kubernetes-platform-stack:latest --name platform
```

**What it does:**
- Builds Python Flask application (src/ + requirements.txt)
- Loads image into all KIND cluster nodes
- Application runs as non-root user (UID 1000)

**Verify:**
```bash
docker images | grep kubernetes-platform-stack
# Should show image: kubernetes-platform-stack:latest
```

### Step 3: Install ArgoCD
```bash
# Create namespace
kubectl create namespace argocd

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
```

**What it does:**
- Creates argocd namespace
- Installs 7 ArgoCD components:
  - application-controller
  - dex-server
  - notifications-controller
  - redis
  - repo-server
  - server (UI)
  - applicationset-controller
- Sets up webhooks and custom resources

**Verify:**
```bash
kubectl get pods -n argocd
# All pods should be Running
```

### Step 4: Deploy App-of-Apps
```bash
kubectl apply -f argocd/app-of-apps.yaml
```

**What it does:**
- Creates master Application resource
- Points to argocd/apps directory
- Automatically syncs all child applications:
  - infrastructure (PostgreSQL, Redis)
  - security (Istio, Falco, Kyverno, Vault, Sealed Secrets, Cert-Manager)
  - networking (Cilium policies)
  - advanced-observability (Prometheus Operator, Loki, Tempo)
  - observability (Grafana, Alertmanager)
  - governance (OPA/Gatekeeper, Audit logging)
  - my-app (application deployment)

**Verify:**
```bash
kubectl get applications -n argocd
# Should show 8 applications: all in Synced status

kubectl get applications -n argocd -w
# Watch status update as deployments progress
```

### Step 5: Monitor Deployment Progress
```bash
# Watch all applications sync
watch kubectl get applications -n argocd

# View logs from ArgoCD controller
kubectl logs -n argocd -f deployment/argocd-application-controller

# Check specific application status
kubectl describe application my-app -n argocd
```

Expected sync timeline:
- 0-2 min: Infrastructure created (PostgreSQL, Redis)
- 2-4 min: Security components installing
- 4-6 min: Networking policies applying
- 6-8 min: Observability stack deploying
- 8-10 min: Application starting

## Accessing Components

### ArgoCD Web UI
```bash
kubectl port-forward -n argocd svc/argocd-server 8080:443 &
# Open https://localhost:8080
# Username: admin
# Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
```

### Grafana (Observability Dashboards)
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
# Open http://localhost:3000
# Username: admin
# Password: prom-operator
```

### Prometheus (Metrics)
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
# Open http://localhost:9090
# Query metrics, view targets and alerts
```

### Application Health Check
```bash
kubectl port-forward -n app svc/my-app 8080:80 &
curl http://localhost:8080/health
# Output: {"status": "healthy"}
```

### Loki (Log Aggregation)
```bash
kubectl port-forward -n loki svc/loki 3100:3100 &
# Query logs via Grafana Explore → Loki
```

### Tempo (Distributed Tracing)
```bash
kubectl port-forward -n tempo svc/tempo 3200:3200 &
# View traces via Grafana Explore → Tempo
```

## Verifying Security

### Check mTLS Enforcement
```bash
# Verify Istio PeerAuthentication
kubectl get peerauthentication -A
# Should show STRICT mode in istio-system and app namespaces

# Check connections are encrypted
kubectl logs -n app deployment/my-app -c my-app | grep "certificate\|tls"
```

### Verify Network Policies
```bash
# List all Cilium NetworkPolicy resources
kubectl get ciliumnetworkpolicy -A

# Test policy enforcement (should fail)
kubectl run test-pod --image=busybox -n app -- sh -c "wget -O- http://my-app:8080" || true
# Should timeout (connection refused)

# Test with correct labels (should succeed)
kubectl run test-pod --image=busybox --labels="app=test" -n app -- sh -c "wget -O- http://my-app:8080"
```

### Verify Kyverno Policies
```bash
# Try to create privileged pod (should be denied)
kubectl run privileged-test --image=nginx --privileged=true -n app 2>&1 | grep -i "error\|denied\|forbidden"
# Should show policy violation

# Try to create pod without labels (should be denied in audit mode)
kubectl run unlabeled-test --image=nginx -n app
kubectl logs -n kyverno deployment/kyverno | grep -i "unlabeled-test"
```

### Verify Audit Logging
```bash
# Check audit logs are being collected
kubectl get pods -n audit

# View audit events
kubectl logs -n audit deployment/audit-logger -f
# Should show Kubernetes API calls
```

## Scaling the Platform

### Increase Replicas
```bash
# Scale application
kubectl patch deployment/my-app -n app -p '{"spec":{"replicas":3}}'

# Verify scaling
kubectl get pods -n app
# Should show 3 my-app pods
```

### Update Application Code
```bash
# Edit Helm values
vim helm/my-app/values.yaml

# Update image tag or configuration
# Commit to git
git add helm/my-app/values.yaml
git commit -m "chore: update app configuration"

# ArgoCD will auto-sync within 3 minutes
kubectl get applications my-app -n argocd -w
```

### Scale Observability
```bash
# Increase Prometheus retention
kubectl patch prometheus -n monitoring \
  --type='json' -p='[{"op":"replace","path":"/spec/retention","value":"30d"}]' \
  prometheus-operator

# Scale Loki replicas
kubectl patch deployment loki -n loki -p '{"spec":{"replicas":3}}'
```

## Troubleshooting

### Pods Not Starting
```bash
# Check pod status
kubectl describe pod <pod-name> -n <namespace>

# Common issues:
# - Image: kubernetes-platform-stack:latest not present → kind load docker-image
# - CrashLoopBackOff → check logs: kubectl logs <pod> -n <namespace>
# - Pending → check resources: kubectl describe node
```

### Application Not Accessible
```bash
# Check service
kubectl get svc -n app
# Should show my-app with IP

# Check endpoints
kubectl get endpoints -n app
# Should show pod IPs

# Test connectivity
kubectl run curl-test --image=curlimages/curl -n app -- curl http://my-app:8080/health
```

### ArgoCD Sync Failures
```bash
# Check application status
kubectl describe application <app-name> -n argocd

# View sync logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller -f

# Force resync
kubectl annotate application <app-name> -n argocd \
  argocd.argoproj.io/compare-result='' --overwrite
```

### Metrics Not Appearing
```bash
# Check Prometheus is scraping
kubectl port-forward -n monitoring svc/prometheus-operator 9090:9090
# Visit http://localhost:9090/targets
# Should show active targets

# Check ServiceMonitor
kubectl get servicemonitor -A
# Should include my-app monitor
```

## Production Deployment Considerations

### External Storage
Replace local storage with:
- **Metrics**: S3, GCS, or AzureBlob for Prometheus
- **Logs**: S3, GCS, or AzureBlob for Loki
- **Traces**: S3, GCS, or AzureBlob for Tempo
- **Databases**: Managed PostgreSQL, Redis (Cloud-native)

### High Availability
1. Multi-region KIND clusters with GitOps
2. External state store (etcd on managed service)
3. Load balancer for ingress traffic
4. Replicated volumes for persistent data
5. Backup automation for critical data

### Monitoring
1. Monitor ArgoCD application sync status
2. Alert on pod restart loops
3. Alert on persistent volume usage
4. Alert on certificate expiration (Cert-Manager)
5. Alert on policy violations (OPA/Gatekeeper)

### Security Hardening
1. NetworkPolicy: Add egress restrictions
2. PSP/PSS: Enable Pod Security Standards
3. RBAC: Implement least privilege
4. Secrets: Use Vault for all sensitive data
5. Scanning: Enable image vulnerability scanning
6. Signing: Enable Cosign image signing verification

### Cost Optimization
1. Resource requests/limits tuning
2. Pod disruption budgets for safe eviction
3. Horizontal pod autoscaling (HPA)
4. Vertical pod autoscaling (VPA)
5. Storage tiering (hot/cold logs)

## Cleanup

To remove the entire platform:
```bash
kind delete cluster --name platform
```

This will:
- Delete all running containers
- Clean up all data
- Remove KIND cluster configuration
- Free all resources

To save cluster before deletion:
```bash
# Export all resources
kubectl get all -A -o yaml > cluster-backup.yaml

# Then delete
kind delete cluster --name platform
```

## Next Steps

1. **Customize**: Modify Helm values in `helm/my-app/values.yaml`
2. **Add Applications**: Create new applications in `argocd/apps/`
3. **Monitor**: Set up Grafana dashboards and alerting rules
4. **Secure**: Review and update security policies
5. **Document**: Add deployment-specific runbooks
6. **Automate**: Integrate with CI/CD pipeline

## Support

For issues and questions:
- Check logs: `kubectl logs -f -n <namespace> <pod-name>`
- Review status: `kubectl describe <resource> -n <namespace>`
- View events: `kubectl get events -n <namespace>`
- Check documentation: See `docs/` directory
- Open issue: https://github.com/vietcgi/kubernetes-platform-stack/issues
