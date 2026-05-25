#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# SMOKE TEST — Quick checks that the platform is working end-to-end
# ─────────────────────────────────────────────────────────────────────────────
# USAGE:
#   ./scripts/smoke-test.sh [namespace]
# EXAMPLES:
#   ./scripts/smoke-test.sh staging
#   ./scripts/smoke-test.sh production

set -euo pipefail

NAMESPACE="${1:-staging}"
PASS=0
FAIL=0

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Smoke Tests — namespace: ${NAMESPACE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

pass() { echo "  ✓ PASS: $1"; ((PASS++)); }
fail() { echo "  ✗ FAIL: $1"; ((FAIL++)); }

# ── Port-forward services for testing ──────────────────────────────────────
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

kubectl port-forward svc/auth-api 8081:8081 -n "${NAMESPACE}" &>/dev/null &
PIDS+=($!)
kubectl port-forward svc/payments-api 8082:8082 -n "${NAMESPACE}" &>/dev/null &
PIDS+=($!)
sleep 5

# ── Test 1: auth-api health ────────────────────────────────────────────────
HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/health 2>/dev/null)
[ "$HTTP" = "200" ] && pass "auth-api /health returns 200" || fail "auth-api /health returned $HTTP"

# ── Test 2: payments-api health ───────────────────────────────────────────
HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8082/health 2>/dev/null)
[ "$HTTP" = "200" ] && pass "payments-api /health returns 200" || fail "payments-api /health returned $HTTP"

# ── Test 3: auth-api metrics ──────────────────────────────────────────────
HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/metrics 2>/dev/null)
[ "$HTTP" = "200" ] && pass "auth-api /metrics returns 200" || fail "auth-api /metrics returned $HTTP"

# ── Test 4: payments-api metrics ──────────────────────────────────────────
HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8082/metrics 2>/dev/null)
[ "$HTTP" = "200" ] && pass "payments-api /metrics returns 200" || fail "payments-api /metrics returned $HTTP"

# ── Test 5: Login with valid credentials ──────────────────────────────────
RESP=$(curl -s -X POST http://localhost:8081/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"password123"}' 2>/dev/null)
if echo "$RESP" | grep -q '"token"'; then
  pass "Login with valid credentials returns JWT token"
  TOKEN=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null)
else
  fail "Login did not return JWT token. Response: $RESP"
  TOKEN=""
fi

# ── Test 6: Login with invalid credentials ────────────────────────────────
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8081/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"wrongpassword"}' 2>/dev/null)
[ "$HTTP" = "401" ] && pass "Login with wrong password returns 401" || fail "Expected 401, got $HTTP"

# ── Test 7: List payments (authenticated) ─────────────────────────────────
if [ -n "$TOKEN" ]; then
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8082/payments \
    -H "Authorization: Bearer $TOKEN" 2>/dev/null)
  [ "$HTTP" = "200" ] && pass "GET /payments returns 200" || fail "GET /payments returned $HTTP"
fi

# ── Test 8: Create a payment ──────────────────────────────────────────────
HEADERS="-H 'Content-Type: application/json'"
if [ -n "$TOKEN" ]; then HEADERS="$HEADERS -H 'Authorization: Bearer $TOKEN'"; fi

RESP=$(eval curl -s -X POST http://localhost:8082/payments \
  -H "'Content-Type: application/json'" \
  -d "'{"merchant_id":"test","amount":99.99,"description":"smoke test"}'" 2>/dev/null) || RESP=""

if echo "$RESP" | grep -q '"id"'; then
  pass "POST /payments creates a payment"
  PAYMENT_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
  # Test 9: Get the payment we just created
  if [ -n "$PAYMENT_ID" ]; then
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8082/payments/"${PAYMENT_ID}" 2>/dev/null)
    [ "$HTTP" = "200" ] && pass "GET /payments/:id returns 200" || fail "GET /payments/:id returned $HTTP"
  fi
else
  fail "POST /payments failed. Response: $RESP"
fi

# ── Test 10: Pod readiness check ───────────────────────────────────────────
NOT_READY=$(kubectl get pods -n "${NAMESPACE}" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==false)].metadata.name}' 2>/dev/null)
[ -z "$NOT_READY" ] && pass "All pods are in Ready state" || fail "Not-ready pods: $NOT_READY"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$FAIL" -gt 0 ]; then
  echo "SMOKE TESTS FAILED — check above for details"
  exit 1
fi
echo "All smoke tests PASSED!"
