# Kong Ingress Routes - Demo Domain Setup

All platform services are exposed through Kong API Gateway using a unified domain: `demo.local`

## Accessing Services

### Kong LoadBalancer IP
The Kong API Gateway is exposed via LoadBalancer with EXTERNAL-IP: **172.18.0.2**

### Configure Local Hosts File

Add these entries to your `/etc/hosts` file:

```bash
# Kong Ingress Routes (KIND cluster on Docker)
172.18.0.2 prometheus.demo.local
172.18.0.2 grafana.demo.local
172.18.0.2 loki.demo.local
172.18.0.2 argocd.demo.local
172.18.0.2 vault.demo.local
172.18.0.2 harbor.demo.local
172.18.0.2 jaeger.demo.local
172.18.0.2 kong-admin.demo.local
```

**Note:** The IP `172.18.0.2` is the control plane node IP. If using a different KIND cluster, verify with:
```bash
kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
```

### Service Endpoints

| Service | URL | Description |
|---------|-----|-------------|
| Prometheus | http://prometheus.demo.local | Metrics collection & visualization |
| Grafana | http://grafana.demo.local | Dashboards (admin/prom-operator) |
| Loki | http://loki.demo.local | Log aggregation API |
| ArgoCD | http://argocd.demo.local | GitOps management (admin/<password>) |
| Vault | http://vault.demo.local | Secrets management |
| Harbor | http://harbor.demo.local | Container registry |
| Jaeger | http://jaeger.demo.local | Distributed tracing |
| Kong Admin | http://kong-admin.demo.local | Kong API Gateway management |

## Port Forwarding (If hosts file not configured)

For local development without modifying hosts file, use port-forwarding:

```bash
# Kong LoadBalancer (requires external IP, or use port-forward)
kubectl port-forward -n api-gateway svc/kong-kong-proxy 8000:80 &

# Then access services via:
# http://localhost:8000/prometheus
# http://localhost:8000/grafana
# etc.
```

## Kong Configuration

- **Ingress Class**: `kong`
- **Domain Pattern**: `<service>.demo.local`
- **API Gateway**: Kong (v2.x)
- **Load Balancer IP**: Pending (see Cilium LoadBalancer setup)

## Setting Custom Domain

To use a different domain (e.g., `platform.local`, `company.com`), edit the ingress routes:

```bash
kubectl patch ingress prometheus-ingress -n monitoring -p '{"spec":{"rules":[{"host":"prometheus.company.com"}]}}'
```

Or re-apply the manifests with your preferred domain.

## Kong Admin API

Access Kong's admin API for advanced configuration:

```bash
curl http://kong-admin.demo.local/
```

Common admin endpoints:
- `GET /` - Kong status
- `GET /services` - List services
- `GET /routes` - List routes
- `GET /upstreams` - List upstream pools
