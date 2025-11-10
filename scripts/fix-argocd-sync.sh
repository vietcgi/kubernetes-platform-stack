#!/bin/bash

# Quick fix script for ArgoCD sync issues
# Refreshes and syncs all OutOfSync applications

set -e

echo "=========================================="
echo "ArgoCD Sync Fix Script"
echo "=========================================="
echo ""

# Refresh ApplicationSet
echo "1. Refreshing ApplicationSet..."
kubectl patch applicationset platform-applications -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' 2>/dev/null
echo "   ✓ ApplicationSet refreshed"
echo ""

# Wait for reconciliation
echo "2. Waiting for reconciliation (10s)..."
sleep 10
echo ""

# Refresh all OutOfSync applications
echo "3. Refreshing OutOfSync applications..."
outofsync=$(kubectl get applications -n argocd -o json 2>/dev/null | jq -r '[.items[] | select(.status.sync.status == "OutOfSync") | .metadata.name] | .[]' 2>/dev/null || echo "")

if [ -z "$outofsync" ]; then
    echo "   ✓ No OutOfSync applications found"
else
    for app in $outofsync; do
        kubectl patch application "$app" -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' 2>/dev/null
        echo "   ✓ Refreshed $app"
    done
fi
echo ""

# Sync Healthy but OutOfSync applications
echo "4. Syncing Healthy but OutOfSync applications..."
healthy_outofsync=$(kubectl get applications -n argocd -o json 2>/dev/null | jq -r '[.items[] | select(.status.sync.status == "OutOfSync" and .status.health.status == "Healthy") | .metadata.name] | .[]' 2>/dev/null || echo "")

if [ -z "$healthy_outofsync" ]; then
    echo "   ✓ No Healthy OutOfSync applications to sync"
else
    for app in $healthy_outofsync; do
        kubectl patch application "$app" -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}' 2>/dev/null
        echo "   ✓ Synced $app"
    done
fi
echo ""

# Wait for sync to complete
echo "5. Waiting for sync to complete (15s)..."
sleep 15
echo ""

# Show final status
echo "=========================================="
echo "Final Status"
echo "=========================================="
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status | head -20
echo ""

# Count remaining issues
remaining=$(kubectl get applications -n argocd -o json 2>/dev/null | jq -r '[.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")] | length' 2>/dev/null || echo "0")

if [ "$remaining" -eq 0 ]; then
    echo "✓ All applications are synced and healthy!"
else
    echo "⚠ $remaining applications still need attention"
    echo ""
    echo "Run './scripts/diagnose-argocd-sync.sh' for detailed analysis"
fi


