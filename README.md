# Kubernetes Platform Stack

[![Platform](https://img.shields.io/badge/Platform-Kubernetes-blue)](https://kubernetes.io/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![CI/CD](https://github.com/vietcgi/kubernetes-platform-stack/actions/workflows/platform.yml/badge.svg)](https://github.com/vietcgi/kubernetes-platform-stack/actions)

**Enterprise-grade Kubernetes platform demonstration using KIND, Cilium, Istio, ArgoCD, and Crossplane.**

Perfect showcase for senior platform engineers, SREs, and DevOps architects.

## 🎯 What This Is

A **complete, production-ready Kubernetes platform** running entirely in KIND with:

- ✅ **Cilium CNI** - eBPF-powered networking, LoadBalancer, BGP, WireGuard encryption
- ✅ **Istio Service Mesh** - mTLS, authorization policies, traffic management
- ✅ **ArgoCD GitOps** - Declarative application deployment, app-of-apps pattern
- ✅ **Crossplane** - Infrastructure-as-Code for cloud resources
- ✅ **Observability Stack** - Prometheus, Grafana, Loki, Tempo, Cilium Hubble
- ✅ **Network Policies** - Zero-trust security by default
- ✅ **Load Balancing** - Cilium native LoadBalancer (no MetalLB)
- ✅ **Automated Testing** - Security, networking, integration, performance

## 🏗️ Architecture

```
GitHub Actions CI/CD (KIND Cluster)
        ↓
┌──────────────────────────────────────┐
│  Build & Scan Docker Image           │
│  - Trivy vulnerability scan          │
│  - Hadolint Dockerfile lint          │
│  - Container unit tests              │
└──────────────────────────────────────┘
        ↓
┌──────────────────────────────────────┐
│  Create KIND Cluster                 │
│  - 1 control plane                   │
│  - 2 worker nodes                    │
│  - Port mappings (80, 443, 8080)     │
└──────────────────────────────────────┘
        ↓
┌──────────────────────────────────────┐
│  Install Core Components             │
│  - Cilium (CNI + LB + BGP)           │
│  - Istio (Service Mesh + mTLS)       │
│  - ArgoCD (GitOps)                   │
│  - Crossplane (IaC)                  │
└──────────────────────────────────────┘
        ↓
┌──────────────────────────────────────┐
│  Install Observability Stack         │
│  - Prometheus (metrics)              │
│  - Grafana (dashboards)              │
│  - Loki (logs)                       │
│  - Tempo (traces)                    │
│  - Cilium Hubble (network viz)       │
└──────────────────────────────────────┘
        ↓
┌──────────────────────────────────────┐
│  Deploy Application                  │
│  - Load image into KIND              │
│  - Deploy via Helm                   │
│  - Apply network policies            │
│  - Apply mTLS configs                │
└──────────────────────────────────────┘
        ↓
┌──────────────────────────────────────┐
│  Run Test Suite                      │
│  - Network connectivity              │
│  - Security policies                 │
│  - Integration tests                 │
│  - Performance baseline              │
└──────────────────────────────────────┘
```

## 🚀 Quick Start

### Prerequisites

- Docker (for KIND)
- kubectl
- helm
- git

### Local Development

```bash
# Clone repository
git clone git@github.com:vietcgi/kubernetes-platform-stack.git
cd kubernetes-platform-stack

# Create KIND cluster
kind create cluster --config .github/kind-config.yaml

# Install Cilium
helm repo add cilium https://helm.cilium.io
helm repo update
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set cni.chainingMode=none \
  --set loadBalancer.enabled=true \
  --set encryption.enabled=true \
  --wait

# Install Istio
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.18.0 sh -
cd istio-1.18.0
kubectl create namespace istio-system
./bin/istioctl install --set profile=demo -y
cd ..

# Create app namespace
kubectl create namespace app
kubectl label namespace app istio-injection=enabled

# Deploy application
helm install my-app helm/my-app --namespace app --wait

# Verify deployment
kubectl get pods -n app
kubectl get svc -n app

# Access application
kubectl port-forward -n app svc/my-app 8080:80
curl http://localhost:8080/health
```

## 🔒 Security Features

- **Zero-Trust Networking** - Default deny all, explicit allow rules
- **mTLS Encryption** - All service-to-service communication encrypted via Istio
- **WireGuard Tunnel** - Pod-to-pod encryption via Cilium
- **Network Policies** - Cilium eBPF-based policy enforcement
- **Authorization Policies** - Istio fine-grained access control
- **Vulnerability Scanning** - Trivy image scanning in CI/CD
- **Infrastructure as Code** - Checkov scanning of manifests
- **Pod Security Standards** - Non-root, read-only filesystems

## 📊 Observability

### Metrics (Prometheus)
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Access: http://localhost:9090
```

### Dashboards (Grafana)
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Access: http://localhost:3000 (admin/prom-operator)
```

### Logs (Loki)
```bash
kubectl port-forward -n monitoring svc/loki 3100:3100
# Query: http://localhost:3100
```

### Traces (Tempo)
```bash
kubectl port-forward -n monitoring svc/tempo 3100:3100
# Query: http://localhost:3100
```

### Network Observability (Cilium Hubble)
```bash
kubectl port-forward -n kube-system svc/hubble-ui 8081:80
# Access: http://localhost:8081
```

## 🧪 Testing

The CI/CD pipeline runs **15 stages** of tests:

1. ✅ Code quality scanning
2. ✅ Docker image vulnerability scanning
3. ✅ KIND cluster creation
4. ✅ Cilium connectivity tests
5. ✅ Network policy enforcement
6. ✅ Istio mTLS validation
7. ✅ Load balancer functionality
8. ✅ BGP configuration
9. ✅ Authorization policy tests
10. ✅ Integration test suite
11. ✅ Security policy tests
12. ✅ Observability validation
13. ✅ Performance metrics
14. ✅ Resource usage analysis
15. ✅ Overall system health

### Run Tests Locally

```bash
# Unit tests
pytest tests/unit/ -v

# Integration tests (requires running cluster)
pytest tests/integration/ -v

# All tests
pytest tests/ -v --cov=src
```

## 📚 Components

| Component | Version | Purpose |
|-----------|---------|---------|
| KIND | Latest | Local Kubernetes cluster |
| Cilium | 1.14+ | CNI, networking, LoadBalancer, BGP |
| Istio | 1.18+ | Service mesh, mTLS, traffic management |
| ArgoCD | 2.8+ | GitOps continuous deployment |
| Crossplane | 1.13+ | Infrastructure automation |
| Prometheus | 25+ | Metrics collection |
| Grafana | 10+ | Metrics visualization |
| Loki | 2.9+ | Log aggregation |
| Tempo | 2.2+ | Distributed tracing |

## 💰 Cost Analysis

| Solution | Monthly Cost | Setup Time | Cluster Time |
|----------|--------------|-----------|--------------|
| **This (KIND)** | **$0** | 5 min | 30 sec |
| EKS with EC2 | $150-200 | 30 min | 15 min |
| EKS Fargate | $100-150 | 30 min | 10 min |

## 🎓 For Recruiters

This demonstrates:

- ✅ **Deep Kubernetes knowledge** - Advanced networking, security, observability
- ✅ **Enterprise architecture** - Multi-component, production-grade platform
- ✅ **Cloud-native expertise** - Cilium, Istio, ArgoCD, Crossplane
- ✅ **Security-first mindset** - Zero-trust, encryption, policies
- ✅ **DevOps maturity** - CI/CD automation, GitOps, comprehensive testing
- ✅ **Cost optimization** - $0 vs $200+/month with EKS
- ✅ **Observability** - Complete monitoring, logging, and tracing stack
- ✅ **Infrastructure-as-Code** - Helm, Kustomize, Crossplane

## 📖 Documentation

- [Architecture Deep Dive](docs/ARCHITECTURE.md)
- [Cilium Setup Guide](docs/CILIUM.md)
- [Istio Configuration](docs/ISTIO.md)
- [ArgoCD GitOps](docs/ARGOCD.md)
- [Observability Stack](docs/OBSERVABILITY.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)

## 🛠️ Development

### Adding New Components

1. Create manifests in `k8s/`
2. Add to Helm chart in `helm/`
3. Update GitHub Actions workflow
4. Add tests in `tests/`
5. Update documentation in `docs/`

### Project Structure

```
kubernetes-platform-stack/
├── .github/
│   └── workflows/
│       └── platform.yml              # Main CI/CD pipeline
├── helm/
│   └── my-app/                       # Application Helm chart
├── k8s/
│   ├── cilium/                       # Cilium policies
│   ├── istio/                        # Istio configs
│   ├── argocd/                       # ArgoCD apps
│   └── crossplane/                   # Crossplane resources
├── src/
│   └── app.py                        # Flask application
├── tests/
│   ├── unit/                         # Unit tests
│   └── integration/                  # Integration tests
├── docs/                             # Documentation
├── Dockerfile                        # Container image
├── requirements.txt                  # Python dependencies
└── README.md                         # This file
```

## 🤝 Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'feat: add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📝 License

MIT - See [LICENSE](LICENSE) file for details

## 👤 Author

**Kevin Vu**
- Email: vietcgi@gmail.com
- GitHub: [@vietcgi](https://github.com/vietcgi)

## 🔗 Related Projects

- [Cilium](https://cilium.io/) - eBPF-powered networking and security
- [Istio](https://istio.io/) - Service mesh platform
- [ArgoCD](https://argo-cd.readthedocs.io/) - GitOps continuous deployment
- [Crossplane](https://crossplane.io/) - Infrastructure-as-Code
- [KIND](https://kind.sigs.k8s.io/) - Local Kubernetes cluster in Docker

---

**Built to impress senior engineers and tech recruiters.**

⭐ If you find this helpful, please star the repository!
