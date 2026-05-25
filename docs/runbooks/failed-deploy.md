# Runbook: Failed Deployment

**Severity:** HIGH  
**Symptoms:** GitHub Actions deploy job failed, or Argo CD shows a sync error, or pods are not rolling out.

---

## Step 1: Check what failed

```bash
# Check GitHub Actions — go to your repo → Actions tab → find the failed run

# Check pod status in the target namespace
kubectl get pods -n production
kubectl get pods -n staging

# Check rollout status (for canary deployments)
kubectl argo rollouts get rollout payments-api -n production
kubectl argo rollouts get rollout auth-api -n production
```

## Step 2: Check deployment events

```bash
kubectl describe deployment payments-api -n staging
# OR for canary:
kubectl describe rollout payments-api -n production

# Look at the Events section for error messages
```

## Step 3: Common causes and fixes

### Cause A: Image doesn't exist in ECR

```bash
# Verify the image tag was pushed
aws ecr list-images --repository-name payday-payments-api --region us-east-1

# If missing, re-trigger CI to rebuild and push:
# In GitHub: Actions → CI pipeline → Re-run all jobs
```

### Cause B: Wrong secret / missing secret

```bash
# Check secrets exist in the namespace
kubectl get secrets -n production

# Check the secret has the right keys
kubectl describe secret postgres-secret -n production

# Re-create the secret if needed:
kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_PASSWORD="your-password" \
  --from-literal=DATABASE_URL="postgres://payday:your-password@RDS_ENDPOINT/payday?sslmode=require" \
  --namespace production \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Cause C: Pod stuck in Pending (not enough resources)

```bash
# Check node capacity
kubectl top nodes
kubectl get nodes -o wide

# Check if resource quota is blocking
kubectl describe resourcequota -n production

# If cluster is full, add more nodes via Terraform:
# Edit terraform/eks/variables.tf → increase node_desired_size
# Then: terraform apply
```

### Cause D: Canary rollout stuck / analysis failed

```bash
# See why canary was aborted
kubectl argo rollouts get rollout payments-api -n production

# Check AnalysisRun status
kubectl get analysisrun -n production

# If analysis failed (bad metrics), rollback:
kubectl argo rollouts abort payments-api -n production

# Then investigate Prometheus metrics in Grafana before re-deploying
```

## Step 4: Rollback immediately if production is impacted

```bash
# For canary rollouts:
kubectl argo rollouts abort payments-api -n production
kubectl argo rollouts abort auth-api -n production

# For regular deployments:
kubectl rollout undo deployment/payments-api -n staging

# Or use the rollback script:
./scripts/rollback.sh payments-api production
```

## Step 5: Verify and monitor

```bash
./scripts/smoke-test.sh production
# Then watch Grafana error rate panel for 5+ minutes
```
