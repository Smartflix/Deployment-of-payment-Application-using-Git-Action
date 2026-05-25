# Runbook: Pod CrashLoopBackOff

**Severity:** HIGH  
**Alert:** `PodCrashLooping` in Alertmanager  
**Symptoms:** A pod keeps restarting. Its status shows `CrashLoopBackOff`.

---

## What is CrashLoopBackOff?
It means the container starts, crashes immediately, Kubernetes tries to restart it, it crashes again — over and over. Kubernetes adds delays between restarts (backoff).

---

## Step 1: Identify the crashing pod

```bash
# See all pods across staging and production
kubectl get pods -n production
kubectl get pods -n staging

# Look for pods showing CrashLoopBackOff or high RESTARTS count
# Example output:
# NAME                            READY   STATUS             RESTARTS   AGE
# payments-api-abc123-xyz         0/1     CrashLoopBackOff   8          15m
```

## Step 2: Get the crash logs

```bash
# Get logs from the CURRENT (crashing) container
kubectl logs <pod-name> -n production

# Get logs from the PREVIOUS (already crashed) container — often more useful
kubectl logs <pod-name> -n production --previous

# Example:
kubectl logs payments-api-abc123-xyz -n production --previous
```

**What to look for in logs:**
- `Error connecting to database` → Database issue (see DB runbook)
- `address already in use` → Port conflict
- `Permission denied` → Security/file permission issue
- `OOMKilled` → Out of memory → increase memory limit
- Python `ImportError` or `ModuleNotFoundError` → Missing dependency

## Step 3: Describe the pod for more details

```bash
kubectl describe pod <pod-name> -n production
```

Look at the `Events` section at the bottom. Common messages:
- `OOMKilled` → Pod ran out of memory
- `Liveness probe failed` → Health check keeps failing
- `Back-off pulling image` → Can't pull Docker image from ECR

## Step 4: Common fixes

### Fix A: OOMKilled (Out of Memory)
```bash
# Increase memory limit in the deployment/rollout YAML:
# resources:
#   limits:
#     memory: 512Mi   ← increase this

# Then apply:
kubectl set resources deployment/payments-api -n production \
  --limits=memory=512Mi --requests=memory=256Mi
```

### Fix B: Image pull error
```bash
# Check ECR credentials secret exists
kubectl get secret -n production

# Verify the image tag exists in ECR
aws ecr list-images --repository-name payday-payments-api --region us-east-1
```

### Fix C: Database connection failing
```bash
# Check DB secret exists and is correct
kubectl get secret postgres-secret -n production -o yaml

# Test DB connectivity from inside the pod (before it crashes)
kubectl run db-test --image=postgres:16-alpine -n production --rm -it -- \
  psql "postgres://payday:PASSWORD@RDS_ENDPOINT/payday"
```

## Step 5: Emergency — rollback immediately

```bash
# If you can't fix quickly, rollback to the last working version:
./scripts/rollback.sh payments-api production
```

## Step 6: Verify recovery

```bash
kubectl get pods -n production -w   # Watch pods stabilize
./scripts/smoke-test.sh production  # Run smoke tests
```
