# Runbook: Database Connection Loss

**Severity:** CRITICAL  
**Alert:** `PostgreSQLDown` in Alertmanager  
**Symptoms:** Services return 500 errors. Logs show `connection refused` or `could not connect to server`. Payments are failing.

---

## IMMEDIATE ACTIONS (first 5 minutes)

```bash
# 1. Check if RDS is up (for production)
aws rds describe-db-instances \
  --db-instance-identifier payday-cluster-postgres \
  --region us-east-1 \
  --query 'DBInstances[0].DBInstanceStatus'
# Expected: "available" — if "stopped" or "failed", proceed to Step 3

# 2. Check pod-level DB connectivity
kubectl get pods -n production -l app=payments-api
kubectl logs <payments-api-pod> -n production | grep -i "database\|connect\|error" | tail -20

# 3. Check staging DB (for staging issues — in-cluster Postgres)
kubectl get pods -n staging -l app=postgres
kubectl logs postgres-0 -n staging | tail -30
```

---

## Step 1: Test database connectivity

```bash
# From within the cluster, test if we can reach the DB
kubectl run db-test --image=postgres:16-alpine --rm -it -n production -- \
  psql "postgres://payday:PASSWORD@RDS_ENDPOINT/payday?sslmode=require" \
  -c "SELECT 1"
# If this fails → network or security group issue
# If this succeeds → the DB is fine, problem is in the app

# Check the DATABASE_URL secret is correct:
kubectl get secret postgres-secret -n production -o jsonpath='{.data.DATABASE_URL}' | base64 -d
```

## Step 2: Check AWS RDS status

```bash
# View RDS status in AWS console, or via CLI:
aws rds describe-db-instances \
  --db-instance-identifier payday-cluster-postgres \
  --region us-east-1

# Check recent RDS events (errors, failovers, maintenance):
aws rds describe-events \
  --source-identifier payday-cluster-postgres \
  --source-type db-instance \
  --duration 60
```

## Step 3: Common fixes

### Fix A: RDS instance stopped (AWS stopped it due to billing/inactivity)
```bash
# Start the RDS instance:
aws rds start-db-instance \
  --db-instance-identifier payday-cluster-postgres \
  --region us-east-1

# Wait for it to be available (usually 2-5 minutes):
aws rds wait db-instance-available \
  --db-instance-identifier payday-cluster-postgres
```

### Fix B: Security group blocking connections
```bash
# Check security group allows port 5432 from EKS node IPs
aws ec2 describe-security-groups --group-ids <RDS_SECURITY_GROUP_ID>

# Add the EKS node CIDR if missing:
aws ec2 authorize-security-group-ingress \
  --group-id <RDS_SG_ID> \
  --protocol tcp \
  --port 5432 \
  --cidr 10.0.0.0/16
```

### Fix C: Database credentials changed
```bash
# Update the secret with new credentials:
kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_PASSWORD="NEW_PASSWORD" \
  --from-literal=DATABASE_URL="postgres://payday:NEW_PASSWORD@RDS_ENDPOINT/payday?sslmode=require" \
  --namespace production \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart services to pick up new secret:
kubectl rollout restart deployment/payments-api -n production
kubectl rollout restart deployment/auth-api -n production
kubectl rollout restart deployment/worker -n production
```

### Fix D: Staging in-cluster Postgres crashed
```bash
# For staging (PostgreSQL runs as a pod, not RDS):
kubectl get pod postgres-0 -n staging
kubectl describe pod postgres-0 -n staging

# Restart:
kubectl delete pod postgres-0 -n staging
# StatefulSet will recreate it automatically

# If PVC is lost:
kubectl get pvc -n staging
# Create a new one if needed (data will be lost — this is staging, acceptable)
```

## Step 4: Recovery verification

```bash
./scripts/smoke-test.sh production
# Check Grafana: payments-api error rate should drop back to < 1%
# Check: worker_pending_payments gauge — should process backlog within minutes
```
