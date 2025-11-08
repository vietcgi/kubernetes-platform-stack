# Kubernetes Platform Stack Architecture

## Overview

This is an enterprise-grade Kubernetes platform built on KIND (Kubernetes in Docker) with production-ready security, networking, observability, and governance components. The platform is fully GitOps-managed through ArgoCD.

##   Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    KIND Kubernetes Cluster                      │
│                      (v1.34.0 Latest)                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────┐ │
│  │   ArgoCD          │  │   Cilium CNI     │  │   Istio      │ │
│  │   (GitOps)        │  │   (Networking)   │  │   (ServiceMesh)
│  └──────────────────┘  └──────────────────┘  └──────────────┘ │
│                                                                 │
│  ┌──────────────────────┐  ┌────────────────────────────────┐  │
│  │    SECURITY LAYER    │  │   NETWORKING LAYER             │  │
│  ├──────────────────────┤  ├────────────────────────────────┤  │
│  │ - Falco              │  │ - Cilium NetworkPolicy (L3-L7) │  │
│  │ - Kyverno            │  │ - Istio VirtualService         │  │
│  │ - Vault              │  │ - Istio Gateway                │  │
│  │ - Sealed Secrets     │  │ - Zero-Trust Policies          │  │
│  │ - Cert-Manager       │  │ - Network Segmentation         │  │
│  │ - mTLS (Strict)      │  │                                │  │
│  └──────────────────────┘  └────────────────────────────────┘  │
│                                                                 │
│  ┌────────────────────────┐  ┌──────────────────────────────┐  │
│  │  OBSERVABILITY LAYER   │  │  GOVERNANCE LAYER            │  │
│  ├────────────────────────┤  ├──────────────────────────────┤  │
│  │ - Prometheus Operator  │  │ - OPA/Gatekeeper             │  │
│  │ - Loki (Log)           │  │ - Kyverno Policies           │  │
│  │ - Tempo (Tracing)      │  │ - Audit Logging              │  │
│  │ - Alertmanager         │  │ - RBAC Enforcement           │  │
│  │ - Grafana              │  │ - Pod Security Standards      │  │
│  │ - Promtail             │  │ - Image Registry Controls     │  │
│  └────────────────────────┘  └──────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │            APPLICATION LAYER (App Namespaces)           │  │
│  │  my-app → PostgreSQL (17) → Redis (7.2) → Observability │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Container Orchestration
- **Kubernetes Version**: v1.34.0 (Latest stable)
- **Distribution**: KIND (Kubernetes in Docker)
- **Node Count**: 3 (1 control-plane + 2 workers)
- **CPU/Memory**: Configurable per deployment

### 2. Container Networking (CNI)
- **Cilium**: v1.18.3 with eBPF
- **Features**:
  - Transparent encryption (optional)
  - No kube-proxy (kubeProxyReplacement=true)
  - L3-L7 networking policies
  - Network segmentation by namespace
  - Load balancing without external tools

### 3. Service Mesh
- **Istio**: v1.18.0+
- **Features**:
  - mTLS strict mode (pod-to-pod encryption)
  - Traffic management (routing, retries, timeouts)
  - Gateway for ingress traffic
  - JWT authentication
  - Authorization policies (default-deny + explicit allow)

### 4. Security Layer

#### Runtime Security
- **Falco**: v0.36.0
  - Pod-level threat detection
  - Syscall monitoring
  - Container escape detection
  - Privilege escalation alerts

#### Policy Enforcement
- **Kyverno**: v1.10.0
  - Pod Security Standards enforcement
  - Image registry validation
  - Resource limits enforcement
  - Read-only root filesystem requirement
  - Privilege escalation prevention

#### Secrets Management
- **Vault**: v1.15.0
  - Encrypted secret storage
  - Kubernetes auth method
  - Dynamic secret generation
  - Audit logging

- **Sealed Secrets**: v0.24.0
  - GitOps-compatible encrypted secrets
  - Per-namespace encryption keys
  - Key rotation support

#### Certificate Management
- **Cert-Manager**: v1.13.0
  - Automatic TLS certificate generation
  - ACME integration (Let's Encrypt)
  - Self-signed certificates for internal services
  - Certificate renewal automation

### 5. Networking Policies
- **Cilium NetworkPolicy** manifests for:
  - Default-deny all traffic
  - Application-specific ingress/egress rules
  - Cross-namespace isolation
  - Database connectivity
  - Cache connectivity
  - Monitoring scrape permissions
  - Kubernetes API access

### 6. Observability Stack

#### Metrics Collection
- **Prometheus Operator**: v0.71.0
  - ServiceMonitor CRDs for dynamic scraping
  - PrometheusRule CRDs for alerting rules
  - High-volume metric collection (millions of metrics/sec)
  - Retention policies
  - Alert deduplication

#### Log Aggregation
- **Loki**: v2.9.0
  - Distributed log aggregation
  - Compression and efficient storage
  - 10GB+ log storage
  - Query interface compatible with Prometheus

- **Promtail**: v2.9.0
  - DaemonSet-based log collection
  - Pod/namespace label enrichment
  - Multi-format parsing

#### Distributed Tracing
- **Tempo**: v2.3.0
  - OTLP, Jaeger, and Zipkin protocol support
  - Distributed trace collection
  - Trace storage (10GB+)
  - Query interface

- **OpenTelemetry Collector**: v0.95.0
  - Multi-protocol trace receiver
  - Span filtering and sampling
  - Tempo exporter

#### Visualization & Alerting
- **Grafana**: Integrated with Prometheus, Loki, Tempo
- **Alertmanager**: Rule-based alerting with grouping/deduplication
- **Pre-configured Alerts**:
  - High error rates (>5% over 5min)
  - Pod memory usage high (>85%)
  - Pod CPU usage high (>80%)
  - Database connection pool exhaustion (>80%)
  - API latency high (P95 > 1s)

### 7. Governance & Compliance

#### Policy-as-Code
- **OPA/Gatekeeper**: v3.14.0
  - Image registry whitelisting
  - Pod label requirements
  - NodePort service blocking
  - Privilege escalation prevention
  - Health probe requirements
  - Resource limit enforcement
  - Namespace isolation

#### Audit Logging
- **Kubernetes Audit Policy**:
  - Metadata level: GET/LIST operations
  - RequestResponse level: CREATE/UPDATE/PATCH/DELETE
  - Separate rules for ConfigMaps, Secrets, RBAC
  - RBAC changes fully logged

- **Log Collection**:
  - Fluent Bit for syslog ingestion
  - File-based audit log storage
  - Filtering for watch operations

#### RBAC
- Service accounts per component
- Cluster roles for privilege separation
- Namespace-scoped role bindings
- Minimal permission principle

## Deployment Architecture

### GitOps Workflow
```
Code Repository (GitHub)
        ↓
    ArgoCD watches
        ↓
    Application Manifests
        ↓
    Kubernetes Cluster
        ↓
    Actual State ← Reconciliation ← Desired State
```

### Application Hierarchy
```
app-of-apps (Master)
├── infrastructure
│   ├── PostgreSQL
│   └── Redis
├── security
│   ├── Istio
│   ├── Falco
│   ├── Kyverno
│   ├── Vault
│   ├── Sealed Secrets
│   └── Cert-Manager
├── networking
│   └── Cilium Network Policies
├── advanced-observability
│   ├── Prometheus Operator
│   ├── Loki
│   ├── Tempo
│   └── OpenTelemetry Collector
├── observability
│   ├── Grafana
│   └── Alertmanager
├── governance
│   ├── OPA/Gatekeeper
│   └── Audit Logging
└── my-app
    ├── Flask API
    ├── Replicas: 2
    └── Sidecar: Istio Envoy
```

## Data Flow

### Application Request Flow
```
Client Request
    ↓
Istio Ingress Gateway (TLS, JWT Auth)
    ↓
Cilium Load Balancer (L3-L7 Decision)
    ↓
Istio VirtualService (Traffic Routing)
    ↓
my-app Pod (Envoy Sidecar → App Container)
    ↓
PostgreSQL (via mTLS) or Redis (via mTLS)
    ↓
Response back with Tracing/Metrics
```

### Observability Data Collection
```
Prometheus Scraper
├── Pod Metrics (kubelet)
├── ServiceMonitor targets
└── Custom app metrics (/metrics endpoint)
        ↓
    Prometheus Operator
        ↓
    Storage (local) + Retention
        ↓
    Grafana Dashboard + Alertmanager

Promtail (DaemonSet)
├── Reads /var/log on nodes
├── Reads Docker logs
└── Enriches with pod labels
        ↓
    Loki (Log Aggregation)
        ↓
    Storage (10GB+)
        ↓
    Query via Loki/Grafana

OpenTelemetry Collector
├── Receives traces (OTLP/gRPC, OTLP/HTTP)
├── Processes spans
└── Exports to Tempo
        ↓
    Tempo (Trace Storage)
        ↓
    Query interface
```

### Security Enforcement Flow
```
Request to API Server
    ↓
OPA/Gatekeeper (Admission Webhook)
├── Check image registries
├── Check required labels
├── Check privilege settings
└── Allow/Deny
    ↓
Kyverno Policies (Mutation + Validation)
├── Pod Security Standards
├── Resource limits
└── Security context
    ↓
Object created/rejected
    ↓
Falco (Runtime Monitoring)
├── Syscall monitoring
├── Container behavior analysis
└── Alert on threats
    ↓
Audit Logging captures all changes
```

## Security Posture

### Network Level
- Default-deny all traffic (Cilium)
- Explicit allow rules per service
- mTLS encryption (Istio)
- TLS for all external communication

### Pod Level
- Non-root containers (runAsNonRoot)
- Read-only root filesystem
- No privileged mode
- Resource limits enforced
- Security context validation

### Cluster Level
- RBAC for all service accounts
- Pod Security Standards enforcement
- Image registry whitelisting
- Audit logging for all API changes
- Secret encryption (sealed-secrets)

### Application Level
- JWT authentication (Istio RequestAuthentication)
- Zero-trust authorization (default-deny)
- API rate limiting (via timeout/retries)
- Database connection pooling
- Observability for anomaly detection

## Scalability Considerations

### Metrics Collection
- Prometheus Operator handles thousands of targets
- Service discovery via ServiceMonitor
- 30-second scrape interval (configurable)
- Multi-replica support planned

### Log Aggregation
- Loki handles high-volume log ingestion
- Compression reduces storage 10x
- Distributed deployment ready
- Query-side caching included

### Tracing
- Tempo sampler reduces volume
- Distributed span processing
- Efficient storage format
- Real-time trace queries

### Networking
- Cilium supports 5000+ pods/cluster
- eBPF programs scale linearly
- No centralpoint of failure
- Policy caching for performance

## High Availability

### Current (Development)
- Single replica for most components
- In-memory state (suitable for testing)
- Local storage for metrics/logs/traces

### Production Upgrades
- Multi-replica Prometheus operators
- Distributed Loki (ingester, distributor, querier)
- Distributed Tempo
- External storage (S3, GCS, AzureBlob)
- Persistent volumes with replication

## Troubleshooting Guide

### Metrics Not Appearing
1. Check ServiceMonitor created: `kubectl get servicemonitor -A`
2. Verify scrape target: `kubectl port-forward -n monitoring svc/prometheus-operator 9090:9090`
3. Check target status in Prometheus UI

### Logs Missing
1. Check Promtail daemonset running: `kubectl get ds -n monitoring promtail`
2. Verify logs are collected: `kubectl logs -n loki deployment/loki`
3. Query in Grafana: Explore → Loki → any label

### Traces Not Showing
1. Check collector running: `kubectl get deployment -n monitoring otel-collector`
2. Verify app exports traces: `kubectl logs -n app deployment/my-app`
3. Check Tempo has data: `kubectl port-forward -n tempo svc/tempo 3200:3200`

### Network Policies Not Applied
1. Verify Cilium installed: `kubectl get pods -n kube-system | grep cilium`
2. Check policies exist: `kubectl get ciliumnetworkpolicy -A`
3. Debug traffic: `cilium policy traffic-control`

## Performance Metrics

### Expected Performance
- Pod startup time: 10-30 seconds
- API response time: <500ms (p99)
- Memory per pod: 256Mi-512Mi
- CPU per pod: 100m-500m
- Metrics latency: 1-5 minutes (with 30s scrape)
- Log latency: 5-30 seconds
- Trace latency: 1-5 seconds

### Resource Requirements
- Control Plane: 2 CPU, 4GB RAM
- Worker Nodes: 2 CPU, 4GB RAM each
- Total (3-node): 6 CPU, 12GB RAM minimum
- With observability: Add 2GB RAM per node

## Maintenance

### Regular Tasks
- Certificate renewal (Cert-Manager automated)
- Log retention cleanup (Loki 30-day default)
- Trace retention (Tempo 24-hour default)
- Metric retention (Prometheus 15-day default)
- Policy updates (via ArgoCD)

### Monitoring Health
- ArgoCD Application status: all Synced/Healthy
- Component pod status: all Running
- PVC usage: under 80% full
- Error rates: < 1%

### Upgrade Path
1. Update manifests in git
2. Commit to main branch
3. ArgoCD auto-syncs within 3 minutes
4. Pod disruption budgets prevent downtime
5. Rolling updates applied automatically
