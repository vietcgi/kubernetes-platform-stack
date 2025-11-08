# Kubernetes Platform Stack - All Apps in Helm

## Complete Helm Charts Overview

All 7 applications from ARCHITECTURE.md now have dedicated Helm charts in the `helm/` folder. This provides complete control, versioning, and GitOps-friendly deployment.

---

## Helm Chart Directory Structure

```
helm/
├── cilium/                          # Layer 1: Networking
│   ├── Chart.yaml                   (v1.17.0)
│   ├── values.yaml                  (129 lines)
│   └── templates/
│       ├── bgp-cluster-config.yaml
│       └── network-policies.yaml
│
├── istio/                           # Layer 2: Service Mesh
│   ├── Chart.yaml                   (v1.28.0)
│   ├── values.yaml                  (145 lines)
│   └── templates/
│       └── namespace.yaml
│
├── prometheus/                      # Layer 4: Metrics & Dashboards
│   ├── Chart.yaml                   (v2.48.0 + Grafana v11.0)
│   └── values.yaml                  (192 lines)
│
├── loki/                            # Layer 4: Log Aggregation ✨ NEW
│   ├── Chart.yaml                   (v3.0.0)
│   ├── values.yaml                  (170 lines)
│   └── templates/
│       └── namespace.yaml
│
├── tempo/                           # Layer 4: Distributed Tracing ✨ NEW
│   ├── Chart.yaml                   (v2.3.0)
│   ├── values.yaml                  (200 lines)
│   └── templates/
│       └── namespace.yaml
│
├── argocd/                          # Layer 5: GitOps Orchestration
│   ├── Chart.yaml                   (v3.2.0)
│   └── values.yaml                  (164 lines)
│
└── my-app/                          # Layer 3: Application
    ├── Chart.yaml                   (v1.0.0)
    ├── values.yaml                  (216 lines)
    └── templates/
        ├── deployment.yaml
        ├── service.yaml
        ├── hpa.yaml
        ├── rbac.yaml
        ├── configmap.yaml
        ├── virtualservice.yaml      (Istio)
        ├── destinationrule.yaml     (Istio)
        ├── peerauthentication.yaml  (Istio mTLS)
        ├── authorizationpolicy.yaml (Istio RBAC)
        ├── networkpolicy.yaml       (Cilium)
        ├── servicemonitor.yaml      (Prometheus)
        └── poddisruptionbudget.yaml (HA)

Total: 7 Charts, 30+ Files
```

---

## 1. Cilium (v1.17.0) - Networking Layer

**Location**: `helm/cilium/`

**Purpose**: eBPF-based networking, kube-proxy replacement, BGP support

**Key Features**:
- eBPF packet processing in kernel
- BGP Control Plane for LoadBalancer IP advertisement
- Automatic kube-proxy replacement
- Network policy enforcement (default-deny)
- Service load balancing (no iptables)

**How to Deploy**:
```bash
helm install cilium ./helm/cilium \
  --namespace kube-system \
  --values ./helm/cilium/values.yaml \
  --wait --timeout=10m
```

**Configuration Highlights** (values.yaml):
- `ipam.mode`: kubernetes
- `bgp.enabled`: true
- `kubeProxyReplacement`: true
- `kubeProxyReplacementHealthzBindAddr`: 0.0.0.0:10256

**Verify Installation**:
```bash
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl get CiliumBGPClusterConfig -n kube-system
```

---

## 2. Istio (v1.28.0) - Service Mesh Layer

**Location**: `helm/istio/`

**Purpose**: Service mesh, mTLS enforcement, traffic management

**Two Components**:
1. **istio-base**: CRDs and cluster setup
2. **istiod**: Control plane for traffic management

**Key Features**:
- Automatic mTLS between services (STRICT mode)
- VirtualService for advanced routing
- DestinationRule for load balancing policies
- AuthorizationPolicy for fine-grained access control
- Sidecar auto-injection

**How to Deploy**:
```bash
# Step 1: Install CRDs
helm install istio-base ./helm/istio \
  --namespace istio-system \
  --wait --timeout=5m

# Step 2: Install control plane
helm install istiod ./helm/istio \
  --namespace istio-system \
  --values ./helm/istio/values.yaml \
  --wait --timeout=5m
```

**Configuration Highlights** (values.yaml):
- `global.imagePullPolicy`: IfNotPresent
- `pilot.replicas`: 1
- `security.workloadSecretRotation.enabled`: true
- `peerAuthentication.mtls.mode`: STRICT
- `requestAuthentication.enabled`: true

**Verify Installation**:
```bash
kubectl get pods -n istio-system -l app=istiod
kubectl get virtualsrvices -n app
kubectl get peerauthentication -n app
```

---

## 3. Prometheus (v2.48.0) - Metrics Collection

**Location**: `helm/prometheus/`

**Purpose**: Metrics collection, storage, and alerting

**Included Components**:
- **Prometheus**: Metrics scraper and time-series database
- **Grafana**: Visualization and dashboards (v11.0.0)
- **AlertManager**: Alert routing and management
- **Node Exporter**: Host metrics collection
- **Kube State Metrics**: Kubernetes object metrics

**Key Features**:
- Automatic service discovery
- 15-day data retention (10Gi storage)
- Pre-built Kubernetes dashboards in Grafana
- Alert rule support
- Prometheus Operator for CRD-based config

**How to Deploy**:
```bash
helm install prometheus ./helm/prometheus \
  --namespace monitoring \
  --values ./helm/prometheus/values.yaml \
  --wait --timeout=10m
```

**Configuration Highlights** (values.yaml):
- `prometheus.prometheusSpec.retention`: 15d
- `prometheus.prometheusSpec.storageSpec.size`: 10Gi
- `grafana.adminPassword`: prom-operator
- `grafana.service.type`: LoadBalancer
- `serviceMonitorSelectorNilUsesHelmValues`: false (scrape all)

**Access**:
```bash
# Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090

# Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000 (admin/prom-operator)
```

**Verify Installation**:
```bash
kubectl get pods -n monitoring | grep prometheus
kubectl get pods -n monitoring | grep grafana
```

---

## 4. Loki (v3.0.0) - Log Aggregation ✨ NEW

**Location**: `helm/loki/`

**Purpose**: Centralized log aggregation and querying

**Included Components**:
- **Loki**: Log aggregator and storage backend
- **Promtail**: DaemonSet log shipper (collects pod logs)

**Key Features**:
- Lightweight log aggregation (label-based, not indexed)
- Automatic pod log collection via Promtail
- 30-day retention (10Gi storage)
- Grafana integration for log queries
- Efficient compression and storage

**How to Deploy**:
```bash
helm install loki ./helm/loki \
  --namespace monitoring \
  --values ./helm/loki/values.yaml \
  --wait --timeout=5m
```

**Configuration Highlights** (values.yaml):
- `loki.persistence.enabled`: true
- `loki.persistence.size`: 10Gi
- `loki.config.limits_config.retention_period`: 720h (30 days)
- `promtail.enabled`: true
- `promtail.config.scrape_configs`: Pod label-based scraping

**Log Sources**:
- All pod stdout/stderr
- Labeled with: namespace, pod, container, app version
- Queryable from Grafana UI

**Query Example in Grafana**:
```logql
{namespace="app", pod=~"my-app.*"} | json
```

**Verify Installation**:
```bash
kubectl get pods -n monitoring | grep loki
kubectl get pods -n monitoring | grep promtail
```

---

## 5. Tempo (v2.3.0) - Distributed Tracing ✨ NEW

**Location**: `helm/tempo/`

**Purpose**: Distributed tracing backend for request correlation

**Key Features**:
- OpenTelemetry OTLP receiver (gRPC 4317, HTTP 4318)
- Jaeger receiver compatibility (14250, 14268)
- Trace metrics generation
- 24-hour trace retention (5Gi storage)
- Grafana trace UI integration
- Automatic Istio sidecar trace export

**How to Deploy**:
```bash
helm install tempo ./helm/tempo \
  --namespace monitoring \
  --values ./helm/tempo/values.yaml \
  --wait --timeout=5m
```

**Configuration Highlights** (values.yaml):
- `tempo.image.tag`: 2.3.0
- `tempo.persistence.enabled`: true
- `tempo.persistence.size`: 5Gi
- `receivers.otlp.enabled`: true (gRPC 4317, HTTP 4318)
- `receivers.jaeger.enabled`: true (14250, 14268)
- `retention.duration`: 24h

**How Traces Flow**:
1. Application makes request
2. Istio sidecar intercepts → exports trace to Tempo (OTLP)
3. Tempo stores trace data
4. Grafana queries Tempo for trace visualization

**Access Traces**:
```bash
# In Grafana, go to Explore tab
# Select Tempo datasource
# Search by trace ID or service
```

**Verify Installation**:
```bash
kubectl get pods -n monitoring | grep tempo
kubectl logs -n monitoring -l app.kubernetes.io/name=tempo
```

---

## 6. ArgoCD (v3.2.0) - GitOps Orchestration

**Location**: `helm/argocd/`

**Purpose**: GitOps-driven continuous deployment and cluster management

**Key Components**:
- **ArgoCD Server**: Web UI and API
- **Application Controller**: Monitors git and reconciles desired state
- **Repository Server**: Clones repos, renders Helm manifests
- **Redis**: Caching layer
- **Dex**: OIDC provider (optional)
- **Notifications Controller**: Webhook events

**Key Features**:
- Git repo sync every 30 seconds
- Auto-sync capability (optional)
- Diff preview before applying
- RBAC and audit trail
- Multi-environment support via ApplicationSet
- Webhook notifications (Slack, email, etc.)

**How to Deploy**:
```bash
helm install argocd ./helm/argocd \
  --namespace argocd \
  --values ./helm/argocd/values.yaml \
  --wait --timeout=10m
```

**Configuration Highlights** (values.yaml):
- `server.service.type`: LoadBalancer
- `server.extraArgs`: --insecure (for testing)
- `controller.replicas`: 1
- `repoServer.autoscaling.enabled`: true
- `repoServer.autoscaling.minReplicas`: 1, maxReplicas: 3
- `gitRepository.url`: https://github.com/vietcgi/kubernetes-platform-stack
- `gitRepository.branch`: main
- `gitRepository.syncInterval`: 30s

**Access ArgoCD**:
```bash
kubectl port-forward -n argocd svc/argocd-server 8080:443
# https://localhost:8080
# Username: admin
# Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

**GitOps Workflow**:
1. Developer pushes changes to git
2. ArgoCD pulls every 30 seconds
3. ArgoCD detects changes → renders Helm charts
4. ArgoCD compares desired vs actual → shows diff
5. Auto-sync applies changes (if enabled)
6. Notifications sent to Slack/email

**Verify Installation**:
```bash
kubectl get pods -n argocd
kubectl get applications -n argocd
```

---

## 7. my-app (v1.0.0) - Sample Application

**Location**: `helm/my-app/`

**Purpose**: Containerized application with full Kubernetes integration

**Included Templates** (14 files):
- **Core**: deployment, service, hpa, rbac, configmap
- **Istio**: virtualservice, destinationrule, peerauthentication, authorizationpolicy
- **Security**: networkpolicy
- **Observability**: servicemonitor, poddisruptionbudget

**Key Features**:
- LoadBalancer service (with BGP annotation for Cilium)
- HPA: 1-5 replicas, 80% CPU/Memory threshold
- Istio integration (mTLS, routing, authorization)
- Network policies (default-deny + explicit allow)
- Prometheus metrics scraping
- Pod disruption budget for HA
- Health checks (liveness, readiness probes)

**How to Deploy**:
```bash
helm install my-app ./helm/my-app \
  --namespace app \
  --values ./helm/my-app/values.yaml \
  --set image.pullPolicy=Never \
  --wait --timeout=5m
```

**Configuration Highlights** (values.yaml):
- `replicaCount`: 1 (initial, scales via HPA)
- `service.type`: LoadBalancer
- `autoscaling.minReplicas`: 1, maxReplicas: 5
- `istio.enabled`: true (all Istio resources)
- `networkPolicy.enabled`: true (Cilium policies)
- `prometheus.enabled`: true (ServiceMonitor)

**Application Endpoints**:
```
GET  /health       → {"status": "healthy"}
GET  /ready        → {"status": "ready"}
GET  /status       → Service status and version
GET  /config       → Configuration info
POST /echo         → Echo request body
GET  /metrics      → Prometheus metrics (Prometheus format)
```

**Verify Installation**:
```bash
kubectl get pods -n app
kubectl get svc -n app
kubectl get hpa -n app
# Check external IP (assigned via Cilium BGP)
```

**Test Application**:
```bash
kubectl port-forward -n app svc/my-app 8080:80
curl http://localhost:8080/health
curl http://localhost:8080/metrics
```

---

## Deployment Order & Dependencies

The `deploy.sh` script deploys all apps in this order to manage dependencies:

```
1. KIND Cluster (v1.33, no kube-proxy)
   ↓ (cluster ready)

2. Cilium (networking foundation)
   ↓ (networking ready, can reach DNS)

3. Istio (depends on networking)
   ├─ istio-base (CRDs)
   └─ istiod (control plane)
   ↓ (service mesh ready, sidecar injection ready)

4. Prometheus (depends on Cilium + Istio)
   ↓ (metrics scraping ready)

5. Loki (depends on Cilium)
   ↓ (log aggregation ready)

6. Tempo (depends on Cilium)
   ↓ (tracing ready)

7. ArgoCD (depends on all above)
   ↓ (GitOps ready)

8. my-app (depends on all above)
   ↓

Final: Health checks & verification
```

**Total Time**: 12-15 minutes

---

## How All Apps Work Together

### Network Flow
```
External Request
    ↓ (Cilium LoadBalancer via BGP)
Service VirtualIP (10.x.x.x)
    ↓ (Cilium eBPF load balancing)
my-app Pod
    ↓ (Istio sidecar intercepts)
Envoy Sidecar (traffic policy enforcement)
    ↓
Application Container
    ↓
Response (encrypted with mTLS if pod-to-pod)
```

### Observability Flow
```
my-app generates:
├─ Metrics → Prometheus scrapes (via ServiceMonitor)
│            → Grafana visualizes
├─ Logs → Promtail ships → Loki stores
│         → Grafana queries
└─ Traces → Istio sidecar exports (OTLP) → Tempo stores
           → Grafana correlates

All accessible in Grafana UI
```

### GitOps Flow
```
Git Commit (any chart in helm/)
    ↓ (pushed to main branch)
ArgoCD polls every 30s
    ↓
Detects changes → renders Helm
    ↓
Compares desired vs actual state
    ↓
Auto-sync applies (if enabled)
    ↓
Pod restarts with new config
    ↓
Notification sent (Slack/email)
```

---

## Customization

### Using Different Configurations

**Development (smaller):**
```bash
helm install my-app ./helm/my-app \
  --values ./helm/my-app/values.yaml \
  --set autoscaling.minReplicas=1 \
  --set autoscaling.maxReplicas=3
```

**Production (larger):**
```bash
helm install my-app ./helm/my-app \
  --values ./helm/my-app/values-prod.yaml \
  --set autoscaling.minReplicas=3 \
  --set autoscaling.maxReplicas=10 \
  --set resources.requests.cpu=500m
```

### Creating Environment-Specific Values

```bash
helm/my-app/
├── values.yaml              # Base (common)
├── values-dev.yaml          # Dev overrides
├── values-staging.yaml      # Staging overrides
└── values-prod.yaml         # Prod overrides
```

Deploy to environment:
```bash
helm install my-app ./helm/my-app \
  -f ./helm/my-app/values.yaml \
  -f ./helm/my-app/values-prod.yaml \
  -n app-prod
```

---

## Updating Apps

### Update to New Version

```bash
# Update Cilium
helm upgrade cilium ./helm/cilium -n kube-system

# Update all observability apps
helm upgrade prometheus ./helm/prometheus -n monitoring
helm upgrade loki ./helm/loki -n monitoring
helm upgrade tempo ./helm/tempo -n monitoring

# Update my-app (rolling restart)
helm upgrade my-app ./helm/my-app -n app
```

### Via GitOps (ArgoCD)

```bash
# 1. Update values.yaml in git
git commit -m "chore: update my-app replicas"

# 2. Push to main
git push

# 3. ArgoCD detects change (30s poll)
# 4. Shows diff in ArgoCD UI
# 5. Click "sync" or auto-sync applies

# No manual helm commands needed!
```

---

## Verification Checklist

```bash
✅ All 7 Helm charts installed
helm list -a --all-namespaces
# Should show: cilium, istio-base, istiod, prometheus, loki, tempo, argocd, my-app

✅ All pods running
kubectl get pods -A | grep -v Running

✅ Cilium networking active
kubectl get pods -n kube-system -l k8s-app=cilium

✅ Istio sidecar injection
kubectl get pods -n app -o jsonpath='{.items[].spec.containers[*].name}' | grep istio

✅ Prometheus metrics collected
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/targets (should be green)

✅ Grafana dashboards working
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000

✅ Loki collecting logs
kubectl logs -n monitoring -l app.kubernetes.io/name=loki | head

✅ Tempo receiving traces
kubectl logs -n monitoring -l app.kubernetes.io/name=tempo | head

✅ ArgoCD synced
kubectl get applications -n argocd
# Should all show "Synced" and "Healthy"

✅ my-app serving traffic
kubectl port-forward -n app svc/my-app 8080:80
curl http://localhost:8080/health
```

---

## Summary

✅ **All 7 apps from ARCHITECTURE.md have Helm charts**
✅ **Stored in `helm/` folder for version control**
✅ **Used by `deploy.sh` for automated deployment**
✅ **Ready for ArgoCD GitOps management**
✅ **Fully customizable via values.yaml**
✅ **Production-ready configurations included**

**Total Helm Charts**: 7
**Total Chart Files**: 30+
**Deployment Time**: 12-15 minutes
**Post-Deployment**: Full observability and GitOps enabled
