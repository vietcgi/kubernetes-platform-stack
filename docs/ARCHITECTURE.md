# Architecture

## Overview

The Kubernetes Platform Stack is a complete Kubernetes platform running in KIND (Kubernetes in Docker). It includes networking, service mesh, observability, security, storage, and GitOps management.

The platform uses a two-node KIND cluster:
- Node 1: Control plane (API server, etcd, CoreDNS)
- Node 2: Worker (application and system pods)

## Core Components

### Networking Layer

Cilium (v1.18.3)
- eBPF-based Container Network Interface (CNI)
- Provides native LoadBalancer support without requiring cloud providers
- Implements network policies for security
- LoadBalancer IP range: 172.18.1.0/24

Istio (v1.28.0)
- Service mesh for inter-pod communication
- Enforces mTLS (mutual TLS) encryption between services
- Manages traffic policies and routing
- Sidecar proxies automatically injected into labeled namespaces

Kong (v3.x)
- API Gateway for ingress traffic
- Routes external requests to internal services
- Configurable plugins for rate limiting, authentication, etc.

External DNS
- Automatically manages DNS records
- Syncs Kubernetes services to DNS provider
- Integrates with LoadBalancer addresses

### Observability Stack

Prometheus (metrics collection)
- Scrapes metrics from all components
- Stores time-series metrics
- Provides query API for alerting and dashboards

Grafana (dashboards)
- Visualizes Prometheus metrics
- Pre-configured dashboards for cluster and application monitoring
- Multi-user support with role-based access

Loki (log aggregation)
- Collects logs from all pods
- Stores and indexes logs for searching
- Integrates with Grafana for visualization

Tempo (distributed tracing)
- Collects traces from applications
- Stores trace data for analysis
- Helps identify performance bottlenecks

Jaeger (advanced tracing)
- Advanced tracing UI and analysis tools
- Integrates with Tempo for trace storage
- Useful for debugging complex interactions

### Security Layer

Sealed Secrets
- Encrypts sensitive data (passwords, tokens, API keys)
- Stores encrypted secrets in git (safe for version control)
- Automatic decryption in cluster via controller

Cert-Manager (TLS certificates)
- Automatically provisions TLS certificates
- Renews certificates before expiration
- Supports Let's Encrypt and other CAs

Kyverno (policy enforcement)
- Kubernetes-native policy engine
- Enforces security policies (image verification, resource limits, etc.)
- Can generate default configurations

Gatekeeper (OPA policies)
- Open Policy Agent (OPA) integration
- Policy-as-code for infrastructure
- Prevents deployment of non-compliant resources

Falco (runtime security)
- Runtime threat detection
- Monitors system calls and container behavior
- Alerts on suspicious activity

Vault (secrets management)
- Centralized secrets storage
- Dynamic secret generation
- Integration with applications and infrastructure

### Storage & Backup

Longhorn (persistent volumes)
- Distributed block storage
- Replicates data across nodes for high availability
- Provides persistent volumes for stateful applications

Velero (backup and restore)
- Backs up entire namespaces or applications
- Disaster recovery capability
- Can restore to different clusters

### GitOps Management

ArgoCD (application orchestration)
- Declarative continuous deployment
- Syncs git repository state to cluster
- Automatic reconciliation of drift
- Multi-app management via ApplicationSet

ApplicationSet (multi-app deployment)
- Template-based application generation
- Single source of truth for 14 platform applications
- Scales easily to many applications

Helm
- Package manager for Kubernetes applications
- All platform components deployed via Helm charts
- Values pinned to specific versions (no wildcards)

## Design Principles

Security First
- All traffic encrypted with mTLS by default
- Network policies restrict communication by default
- No hardcoded credentials anywhere
- All secrets encrypted at rest

GitOps
- All configuration in git
- Single source of truth via ApplicationSet
- Automatic sync and reconciliation
- Full audit trail via git history

Observability
- All components emit metrics
- Centralized log collection
- Distributed tracing for debugging
- Real-time dashboards

High Availability
- Replicated storage with Longhorn
- Multiple replicas for critical services
- Automatic failure recovery
- Backup and restore capability

Simplicity
- Helm charts for packaging
- ApplicationSet for templating
- Clear separation of concerns
- Self-contained and reproducible

## Resource Usage

Typical resource consumption (idle):

Component              CPU      Memory
Cilium (per node)      50m      128Mi
Prometheus             100m     512Mi
Grafana                50m      128Mi
Istio                  200m     256Mi
ArgoCD                 300m     512Mi
Other services         100m     256Mi
---
TOTAL                  ~800m    ~1.7Gi

On a laptop with 4 CPU and 8GB RAM: comfortable headroom
On a laptop with 2 CPU and 4GB RAM: tight but workable

Adjust replica counts in helm/*/values.yaml if needed.
