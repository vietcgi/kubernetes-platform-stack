#!/bin/bash

# ArgoCD Application Sync Diagnostic Script
# Diagnoses why applications are not syncing or unhealthy

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}INFO${NC}: $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

echo "=========================================="
echo "ArgoCD Application Sync Diagnostics"
echo "=========================================="
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl is not installed"
    exit 1
fi

# Check if ArgoCD namespace exists
if ! kubectl get namespace argocd &> /dev/null; then
    log_error "ArgoCD namespace not found. Is ArgoCD installed?"
    exit 1
fi

log_info "Checking ArgoCD server status..."
argocd_server=$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "$argocd_server" -eq 0 ]; then
    log_error "ArgoCD server is not running!"
    echo ""
    log_info "Checking ArgoCD server pods..."
    kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server
    exit 1
else
    log_success "ArgoCD server is running"
fi

echo ""
log_info "Checking ApplicationSet status..."
appset=$(kubectl get applicationset platform-applications -n argocd 2>/dev/null || echo "")
if [ -z "$appset" ]; then
    log_warn "ApplicationSet 'platform-applications' not found"
else
    log_success "ApplicationSet found"
fi

echo ""
log_info "Analyzing application sync status..."
echo ""

# Get all applications
apps=$(kubectl get applications -n argocd -o json 2>/dev/null || echo '{"items":[]}')

# Count by status
total=$(echo "$apps" | jq -r '.items | length')
synced=$(echo "$apps" | jq -r '[.items[] | select(.status.sync.status == "Synced")] | length')
outofsync=$(echo "$apps" | jq -r '[.items[] | select(.status.sync.status == "OutOfSync")] | length')
unknown=$(echo "$apps" | jq -r '[.items[] | select(.status.sync.status == "Unknown")] | length')
healthy=$(echo "$apps" | jq -r '[.items[] | select(.status.health.status == "Healthy")] | length')
unhealthy=$(echo "$apps" | jq -r '[.items[] | select(.status.health.status == "Unhealthy")] | length')
degraded=$(echo "$apps" | jq -r '[.items[] | select(.status.health.status == "Degraded")] | length')
progressing=$(echo "$apps" | jq -r '[.items[] | select(.status.health.status == "Progressing")] | length')
suspended=$(echo "$apps" | jq -r '[.items[] | select(.status.sync.status == "Suspended")] | length')

echo "=========================================="
echo "Application Status Summary"
echo "=========================================="
echo "Total Applications: $total"
echo ""
echo "Sync Status:"
echo "  Synced:     $synced"
echo "  OutOfSync:  $outofsync"
echo "  Unknown:    $unknown"
echo "  Suspended:  $suspended"
echo ""
echo "Health Status:"
echo "  Healthy:     $healthy"
echo "  Unhealthy:   $unhealthy"
echo "  Degraded:    $degraded"
echo "  Progressing: $progressing"
echo ""

# List problematic applications
if [ "$outofsync" -gt 0 ] || [ "$unhealthy" -gt 0 ] || [ "$degraded" -gt 0 ]; then
    echo "=========================================="
    echo "Problematic Applications"
    echo "=========================================="
    echo ""
    
    # OutOfSync applications
    if [ "$outofsync" -gt 0 ]; then
        log_warn "OutOfSync Applications ($outofsync):"
        echo "$apps" | jq -r '.items[] | select(.status.sync.status == "OutOfSync") | "  - \(.metadata.name) (Health: \(.status.health.status // "Unknown"))"'
        echo ""
    fi
    
    # Unhealthy applications
    if [ "$unhealthy" -gt 0 ]; then
        log_error "Unhealthy Applications ($unhealthy):"
        echo "$apps" | jq -r '.items[] | select(.status.health.status == "Unhealthy") | "  - \(.metadata.name) (Sync: \(.status.sync.status // "Unknown"))"'
        echo ""
    fi
    
    # Degraded applications
    if [ "$degraded" -gt 0 ]; then
        log_warn "Degraded Applications ($degraded):"
        echo "$apps" | jq -r '.items[] | select(.status.health.status == "Degraded") | "  - \(.metadata.name) (Sync: \(.status.sync.status // "Unknown"))"'
        echo ""
    fi
    
    # Unknown sync status
    if [ "$unknown" -gt 0 ]; then
        log_warn "Unknown Sync Status ($unknown):"
        echo "$apps" | jq -r '.items[] | select(.status.sync.status == "Unknown") | "  - \(.metadata.name) (Health: \(.status.health.status // "Unknown"))"'
        echo ""
    fi
fi

echo "=========================================="
echo "Detailed Application Analysis"
echo "=========================================="
echo ""

# Analyze each problematic application
problematic_apps=$(echo "$apps" | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | .metadata.name')

if [ -z "$problematic_apps" ]; then
    log_success "All applications are synced and healthy!"
    exit 0
fi

for app in $problematic_apps; do
    echo "----------------------------------------"
    log_info "Analyzing: $app"
    echo "----------------------------------------"
    
    # Get detailed application status
    app_json=$(kubectl get application "$app" -n argocd -o json 2>/dev/null)
    
    if [ -z "$app_json" ]; then
        log_error "Application $app not found"
        continue
    fi
    
    # Extract status information
    sync_status=$(echo "$app_json" | jq -r '.status.sync.status // "Unknown"')
    health_status=$(echo "$app_json" | jq -r '.status.health.status // "Unknown"')
    sync_message=$(echo "$app_json" | jq -r '.status.sync.status // "N/A"')
    conditions=$(echo "$app_json" | jq -r '.status.conditions[]? | "\(.type): \(.message)"' | head -5)
    
    echo "Sync Status: $sync_status"
    echo "Health Status: $health_status"
    echo ""
    
    # Check source repository
    repo_url=$(echo "$app_json" | jq -r '.spec.source.repoURL // "N/A"')
    chart=$(echo "$app_json" | jq -r '.spec.source.chart // "N/A"')
    version=$(echo "$app_json" | jq -r '.spec.source.targetRevision // "N/A"')
    
    echo "Source:"
    echo "  Repository: $repo_url"
    if [ "$chart" != "N/A" ]; then
        echo "  Chart: $chart"
    fi
    echo "  Version: $version"
    echo ""
    
    # Check for common issues
    issues_found=0
    
    # Issue 1: Repository not accessible
    if [[ "$repo_url" == http* ]]; then
        log_info "Checking repository accessibility..."
        if ! curl -s --head --max-time 5 "$repo_url" > /dev/null 2>&1; then
            log_error "Repository may not be accessible: $repo_url"
            ((issues_found++))
        else
            log_success "Repository is accessible"
        fi
    fi
    
    # Issue 2: Wildcard version
    if [ "$version" = "*" ] || [ "$version" = "latest" ]; then
        log_warn "Using wildcard version ($version) - may cause sync issues"
        ((issues_found++))
    fi
    
    # Issue 3: Check conditions for errors
    if [ -n "$conditions" ]; then
        echo "Conditions:"
        echo "$conditions" | while IFS= read -r condition; do
            if [[ "$condition" == *"Error"* ]] || [[ "$condition" == *"Failed"* ]]; then
                log_error "  $condition"
                ((issues_found++))
            else
                echo "  $condition"
            fi
        done
        echo ""
    fi
    
    # Issue 4: Check for sync errors
    sync_result=$(echo "$app_json" | jq -r '.status.operationState.phase // "N/A"')
    if [ "$sync_result" = "Error" ] || [ "$sync_result" = "Failed" ]; then
        log_error "Sync operation failed!"
        message=$(echo "$app_json" | jq -r '.status.operationState.message // "No message"')
        echo "  Error: $message"
        ((issues_found++))
    fi
    
    # Issue 5: Check namespace
    namespace=$(echo "$app_json" | jq -r '.spec.destination.namespace // "N/A"')
    if [ "$namespace" != "N/A" ] && [ "$namespace" != "" ]; then
        if ! kubectl get namespace "$namespace" &> /dev/null; then
            log_warn "Namespace '$namespace' does not exist (should be created by sync)"
        fi
    fi
    
    # Issue 6: Check for resource conflicts
    if [ "$sync_status" = "OutOfSync" ]; then
        log_info "Checking for resource differences..."
        diff_count=$(echo "$app_json" | jq -r '[.status.resources[]? | select(.status == "OutOfSync")] | length')
        if [ "$diff_count" -gt 0 ]; then
            log_warn "Found $diff_count resources out of sync"
            echo "$app_json" | jq -r '.status.resources[]? | select(.status == "OutOfSync") | "  - \(.kind)/\(.name): \(.message // "No message")"' | head -5
        fi
    fi
    
    if [ $issues_found -eq 0 ]; then
        log_info "No obvious issues found - check ArgoCD UI for details"
    fi
    
    echo ""
done

echo "=========================================="
echo "Recommendations"
echo "=========================================="
echo ""

if [ "$outofsync" -gt 0 ]; then
    echo "1. For OutOfSync applications:"
    echo "   - Check if resources were manually modified"
    echo "   - Review sync policy (prune enabled/disabled)"
    echo "   - Run: kubectl get application <app-name> -n argocd -o yaml"
    echo ""
fi

if [ "$unhealthy" -gt 0 ]; then
    echo "2. For Unhealthy applications:"
    echo "   - Check pod status: kubectl get pods -n <namespace>"
    echo "   - Check events: kubectl get events -n <namespace>"
    echo "   - Review application logs in ArgoCD UI"
    echo ""
fi

if [ "$unknown" -gt 0 ]; then
    echo "3. For Unknown sync status:"
    echo "   - Application may be newly created"
    echo "   - Wait for ArgoCD to reconcile"
    echo "   - Check ApplicationSet controller logs"
    echo ""
fi

echo "4. Common fixes:"
echo "   - Sync manually: kubectl patch application <app-name> -n argocd --type merge -p '{\"operation\":{\"initiatedBy\":{\"username\":\"admin\"},\"sync\":{}}}'"
echo "   - Refresh application: kubectl patch application <app-name> -n argocd --type merge -p '{\"metadata\":{\"annotations\":{\"argocd.argoproj.io/refresh\":\"hard\"}}}'"
echo "   - Check repository connectivity: kubectl get application <app-name> -n argocd -o jsonpath='{.status.conditions}'"
echo ""

echo "=========================================="
echo "Quick Fixes"
echo "=========================================="
echo ""
echo "To refresh all applications:"
echo "  kubectl patch applicationset platform-applications -n argocd --type merge -p '{\"metadata\":{\"annotations\":{\"argocd.argoproj.io/refresh\":\"hard\"}}}'"
echo ""
echo "To manually sync a specific application:"
echo "  kubectl patch application <app-name> -n argocd --type merge -p '{\"operation\":{\"initiatedBy\":{\"username\":\"admin\"},\"sync\":{}}}'"
echo ""
echo "To check ArgoCD controller logs:"
echo "  kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=100"
echo ""


