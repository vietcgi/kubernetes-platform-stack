#!/bin/bash
# Health check functions for bootstrap monitoring

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_node_health() {
  local ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
  local total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  [ "$ready" -eq "$total" ] && [ "$total" -gt 0 ]
}

check_argocd_app_sync() {
  local status=$(kubectl get application "$1" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)
  [ "$status" = "Synced" ]
}

check_argocd_app_health() {
  local health=$(kubectl get application "$1" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null)
  [ "$health" = "Healthy" ]
}

check_pod_health() {
  local total=$(kubectl get pods -n "$1" -l "$2" --no-headers 2>/dev/null | wc -l)
  local ready=$(kubectl get pods -n "$1" -l "$2" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  [ "$total" -gt 0 ] && [ "$ready" -eq "$total" ]
}

get_app_status() {
  local sync=$(kubectl get application "$1" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  local health=$(kubectl get application "$1" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  local rev=$(kubectl get application "$1" -n argocd -o jsonpath='{.status.sync.revision}' 2>/dev/null | cut -c1-7)
  local sync_icon=$([ "$sync" = "Synced" ] && echo "✓" || echo "✗")
  local health_icon=$([ "$health" = "Healthy" ] && echo "✓" || echo "✗")
  printf "${BLUE}%-20s${NC} Sync: %-10s [%s] Health: %-10s [%s] Rev: %s\n" "$1" "$sync" "$sync_icon" "$health" "$health_icon" "$rev"
}

get_pod_count() {
  local running=$(kubectl get pods -n "$1" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  local total=$(kubectl get pods -n "$1" --no-headers 2>/dev/null | wc -l)
  if [ "$total" -gt 0 ]; then
    local icon=$([ "$running" -eq "$total" ] && echo "✓" || echo "⚠")
    printf "${BLUE}%-20s${NC} Pods: ${GREEN}%d${NC}/${YELLOW}%d${NC} [%s]\n" "$1" "$running" "$total" "$icon"
  fi
}

export -f check_node_health
export -f check_argocd_app_sync
export -f check_argocd_app_health
export -f check_pod_health
export -f get_app_status
export -f get_pod_count
