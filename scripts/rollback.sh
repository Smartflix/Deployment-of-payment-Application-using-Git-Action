#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ROLLBACK SCRIPT — Emergency rollback for any service in any namespace
# ─────────────────────────────────────────────────────────────────────────────
# USAGE:
#   ./scripts/rollback.sh <service> <namespace>
# EXAMPLES:
#   ./scripts/rollback.sh payments-api production   # Abort canary, revert to stable
#   ./scripts/rollback.sh auth-api production
#   ./scripts/rollback.sh payments-api staging       # Rollback staging deployment

set -euo pipefail

SERVICE="${1:-}"
NAMESPACE="${2:-production}"

if [ -z "$SERVICE" ]; then
  echo "Usage: $0 <service> [namespace]"
  echo ""
  echo "Services: payments-api, auth-api, worker, frontend"
  echo "Namespaces: production, staging"
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ROLLBACK: ${SERVICE} in ${NAMESPACE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if this is an Argo Rollout or a regular Deployment
if kubectl get rollout "${SERVICE}" -n "${NAMESPACE}" &>/dev/null; then
  echo "Detected: Argo Rollout (canary deployment)"
  echo "Action: Aborting canary → reverting to stable version"
  echo ""
  kubectl argo rollouts abort "${SERVICE}" -n "${NAMESPACE}"
  echo ""
  echo "Waiting for stable version to take full traffic..."
  kubectl argo rollouts status "${SERVICE}" -n "${NAMESPACE}" --timeout=120s || true
  echo ""
  kubectl argo rollouts get rollout "${SERVICE}" -n "${NAMESPACE}"
else
  echo "Detected: Regular Deployment"
  echo "Action: Rolling back to previous ReplicaSet"
  echo ""
  # Show current state
  kubectl rollout history deployment/"${SERVICE}" -n "${NAMESPACE}"
  echo ""
  # Perform rollback
  kubectl rollout undo deployment/"${SERVICE}" -n "${NAMESPACE}"
  echo ""
  echo "Waiting for rollback to complete..."
  kubectl rollout status deployment/"${SERVICE}" -n "${NAMESPACE}" --timeout=120s
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ROLLBACK COMPLETE for ${SERVICE} in ${NAMESPACE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Current pod status:"
kubectl get pods -n "${NAMESPACE}" -l "app=${SERVICE}"
echo ""
echo "IMPORTANT: Check Grafana to confirm error rates are back to normal."
