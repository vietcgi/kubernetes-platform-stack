#!/bin/bash
set -e

CLUSTER_NAME="${CLUSTER_NAME:-platform}"

echo "Creating KIND cluster..."
kind create cluster --config kind-config.yaml --name "$CLUSTER_NAME"

echo ""
echo "Phase 1: Install network prerequisites (CoreDNS + Cilium)"
echo "============================================================"

echo "Waiting for API server to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/coredns -n kube-system 2>/dev/null || true

echo "Patching CoreDNS with resource limits..."
kubectl patch deployment coredns -n kube-system -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "coredns",
            "resources": {
              "limits": {
                "cpu": "100m",
                "memory": "64Mi"
              },
              "requests": {
                "cpu": "50m",
                "memory": "32Mi"
              }
            }
          }
        ]
      }
    }
  }
}' 2>/dev/null || true

echo "Waiting for CoreDNS to be ready..."
kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=300s

echo "Installing Cilium CNI..."
helm repo add cilium https://helm.cilium.io
helm repo update
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost=127.0.0.1 \
  --set k8sServicePort=6443 \
  --set ebpf.enabled=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --wait \
  --timeout=5m

echo "Waiting for Cilium to be ready..."
kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s

echo ""
echo "Phase 2: Install ArgoCD"
echo "======================"

echo "Creating argocd namespace..."
kubectl create namespace argocd 2>/dev/null || true

echo "Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD server to be ready..."
kubectl wait deployment argocd-server -n argocd \
  --for=condition=Available --timeout=300s

echo ""
echo "Phase 3: Bootstrap GitOps"
echo "========================="

echo "Applying root Application for GitOps sync..."
kubectl apply -f argocd/bootstrap/root-app.yaml

echo "Waiting for root-app to sync..."
kubectl wait application root-app -n argocd \
  --for=condition=Synced --timeout=600s 2>/dev/null || true

echo ""
echo "✓ Cluster bootstrapped successfully!"
echo "✓ Phase 1: CoreDNS + Cilium networking installed"
echo "✓ Phase 2: ArgoCD deployed"
echo "✓ Phase 3: GitOps bootstrap initiated"
echo ""
echo "Monitor ArgoCD sync progress:"
echo "  kubectl get applications -n argocd -w"
echo ""
