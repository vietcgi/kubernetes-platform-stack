# Cilium LoadBalancer Configuration

This guide explains when and how to use Cilium's native LoadBalancer with L2 announcements.

## Overview

Cilium provides native LoadBalancer service support as an alternative to MetalLB. The configuration includes:
- **CiliumLoadBalancerIPPool**: Allocates external IPs for LoadBalancer services
- **CiliumL2AnnouncementPolicy**: Announces those IPs via Layer 2 (ARP) on specified interfaces

## Use Cases

### ✓ Use Cilium LoadBalancer For:
- **Bare Metal Kubernetes clusters** with L2 network access
- **VM-based clusters** where nodes can announce IPs via ARP
- **Production environments** needing native LoadBalancer support
- **On-premises deployments** without cloud provider integration
- **KIND/Docker development** using Docker bridge network IPs (172.18.1.0/24)

## Configuration Files

Located in `manifests/cilium/`:

### lb-pool.yaml
```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: default
spec:
  blocks:
    # For KIND/Docker: Use Docker bridge network (172.18.1.0/24)
    - cidr: "172.18.1.0/24"
    # For Production: Use your network's range (e.g., 192.168.100.0/24)
    # - cidr: "192.168.100.0/24"
```

### l2-announcement-policy.yaml
```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default
  namespace: kube-system
spec:
  interfaces:
    - eth0              # Network interface to announce on
  externalIPs: true    # Announce ExternalIP type services
  loadBalancerIPs: true # Announce LoadBalancer type services
```

## KIND/Docker Setup (Local Development)

For local development with KIND, the LoadBalancer IPs are allocated from the Docker bridge network:

**Network Configuration:**
- Docker Bridge: `172.18.0.0/16`
- KIND Control Plane: `172.18.0.2`
- KIND Worker: `172.18.0.3`
- **LoadBalancer Pool: `172.18.1.0/24`** (automatically routed to host)

**Why This Works:**
- Docker automatically routes 172.18.0.0/16 traffic to the host
- LoadBalancer IPs (172.18.1.x) are part of the same bridge network
- L2 announcements propagate to the host automatically
- Services get real external IPs without NodePort complexity

**Access Pattern:**
```bash
# Kong example with LoadBalancer
kubectl get svc -n api-gateway kong-kong-proxy
# Shows EXTERNAL-IP: 172.18.1.x

# Access from host:
curl http://172.18.1.x:80/
```

## How to Apply (For Production)

### Manual Application
```bash
# Apply to production cluster
kubectl apply -f manifests/cilium/lb-pool.yaml
kubectl apply -f manifests/cilium/l2-announcement-policy.yaml

# Verify
kubectl get ciliumloadbalancerippools
kubectl get ciliuml2announcementpolicies -n kube-system
```

### In Deployment Script
Add to your Kubernetes deployment automation (not in KIND):

```bash
# After Cilium is ready
kubectl apply -f manifests/cilium/lb-pool.yaml
kubectl apply -f manifests/cilium/l2-announcement-policy.yaml
```

## Helm Configuration

Cilium Helm values (`helm/cilium/values.yaml`) include L2 LoadBalancer settings:

```yaml
loadBalancer:
  l2:
    enabled: true
    interfaces:
    - eth0
  algorithm: maglev    # Consistent hashing for connection affinity
  mode: snat          # Source NAT for external traffic
```

## Troubleshooting

### LoadBalancer services stuck in `<pending>`
```bash
# Check if IP pool exists
kubectl get ciliumloadbalancerippools

# Check if L2 announcement policy exists
kubectl get ciliuml2announcementpolicies -n kube-system

# Check Cilium logs
kubectl logs -n kube-system -l k8s-app=cilium | grep -i loadbalancer
```

### IPs not reachable
Verify:
1. IP pool is in a routable CIDR for your network
2. L2 announcement is enabled on correct interface (usually `eth0` for bare metal)
3. Network switch supports ARP (most do)

### For KIND/Docker (LoadBalancer Should Work)
```bash
# Verify LoadBalancer IPs are assigned
kubectl get svc -n <namespace> <service-name>
# Should show EXTERNAL-IP from 172.18.1.0/24

# Test connectivity
curl http://172.18.1.x:80/service

# If LoadBalancer IP is stuck in <pending>:
# 1. Check logs:
kubectl logs -n kube-system -l k8s-app=cilium | grep -i "allocate\|pool"

# 2. Verify pool and policy exist:
kubectl get ciliumloadbalancerippools
kubectl get ciliuml2announcementpolicies -n kube-system

# 3. Fallback to NodePort if needed:
kubectl patch svc <service> -p '{"spec":{"type":"NodePort"}}'
```

## Best Practices

1. **IP Pool Planning**: Ensure IP range doesn't conflict with:
   - Pod CIDR (default: 10.244.0.0/16)
   - Service CIDR (default: 10.96.0.0/12)
   - Host network

2. **L2 Interface**: Verify the interface name with:
   ```bash
   kubectl exec -it -n kube-system <cilium-pod> -- ip link show
   ```

3. **Network Policy**: LoadBalancer services bypass network policies by default. Use:
   - CiliumNetworkPolicy with `fromEndpoints` to restrict
   - Or apply at the service level

4. **Scaling**: For large IP pools, consider segmentation:
   ```yaml
   cidrs:
     - cidr: "172.20.0.0/25"    # Pool 1: 128 IPs
     - cidr: "172.20.0.128/25"  # Pool 2: 128 IPs
   ```

## Switching Between LoadBalancer and NodePort

### From LoadBalancer to NodePort
```bash
# Delete LoadBalancer config
kubectl delete ciliumloadbalancerippools default
kubectl delete ciliuml2announcementpolicies -n kube-system default

# Update service type
kubectl patch svc <service> -p '{"spec":{"type":"NodePort"}}'
```

### From NodePort to LoadBalancer
```bash
# Apply LoadBalancer config
kubectl apply -f manifests/cilium/lb-pool.yaml
kubectl apply -f manifests/cilium/l2-announcement-policy.yaml

# Update service type
kubectl patch svc <service> -p '{"spec":{"type":"LoadBalancer"}}'
```

## References
- [Cilium LoadBalancer Documentation](https://docs.cilium.io/en/stable/network/loadbalancer/)
- [CiliumL2AnnouncementPolicy API](https://docs.cilium.io/en/stable/reference/k8s-api/policy_v2alpha1/#ciliuml2announcementpolicy)
- [CiliumLoadBalancerIPPool API](https://docs.cilium.io/en/stable/reference/k8s-api/policy_v2alpha1/#ciliumloadbalancerippol)
