# Developer Guide — Payday Platform

This guide explains how to work with the Payday Platform as a developer.  
No DevOps experience required.

---

## Table of Contents
1. [Local Development Setup](#local-development)
2. [Feature Branch Workflow](#feature-branch-workflow)
3. [How CI/CD Works](#how-cicd-works)
4. [How to Promote to Production](#promote-to-production)
5. [How to Rollback](#rollback)
6. [Viewing Logs and Metrics](#observability)

---

## 1. Local Development

Run the entire platform on your laptop with Docker Compose:

```bash
# Prerequisites: Docker Desktop installed

# Clone the repo
git clone https://github.com/YOUR_ORG/payday_platform.git
cd payday_platform

# Start everything (PostgreSQL + all 4 services)
docker compose up --build

# Services are now available at:
#   Frontend:     http://localhost:8080
#   Auth API:     http://localhost:8081
#   Payments API: http://localhost:8082
#   Worker:       http://localhost:8083
#   PostgreSQL:   localhost:5432

# To stop everything:
docker compose down

# To stop AND delete all data (fresh start):
docker compose down -v
```

---

## 2. Feature Branch Workflow

```
main branch        → Production (via canary)
any other branch   → CI runs tests + security scan, NO deployment
```

### Step-by-step for a new feature:

```bash
# 1. Create a feature branch
git checkout -b feature/add-refund-endpoint

# 2. Make your changes
#    Edit apps/payments-api/app.py (or whichever service)

# 3. Test locally
docker compose up --build

# 4. Commit and push
git add -A
git commit -m "feat: add refund endpoint to payments-api"
git push origin feature/add-refund-endpoint

# 5. GitHub Actions CI automatically runs:
#    - Tests for all services
#    - Docker image builds
#    - Trivy security scan
#    You can watch it here: GitHub → Actions tab

# 6. Open a Pull Request targeting main
#    → CI must pass before merging is allowed

# 7. After PR is approved and merged → CI runs on main → Images pushed to ECR
#    → Deploy to staging automatically starts
```

---

## 3. How CI/CD Works

```
Push to any branch:
  └─ CI Pipeline (ci.yml)
       ├─ Run tests (Go, Python)
       ├─ Build Docker images
       ├─ Scan for vulnerabilities (Trivy)
       │    └─ BLOCKS if HIGH/CRITICAL CVEs found
       └─ Push images to ECR (only on main branch)

Push to main (after PR merge):
  └─ Deploy Staging (deploy-staging.yml)
       ├─ Update image tags in k8s manifests
       ├─ Apply to staging namespace
       ├─ Wait for pods to be Ready
       └─ Run smoke tests
            └─ Auto-rollback if tests fail

Manual trigger:
  └─ Deploy Production (deploy-production.yml)
       ├─ Human types "DEPLOY" to confirm
       ├─ GitHub asks required reviewer to approve
       ├─ Canary rollout starts: 10% traffic → new version
       ├─ Prometheus checks error rate every 60s
       │    └─ Auto-rollback if error rate > 5%
       ├─ Advances to 30%, then 50%
       └─ Human promotes to 100% after review
```

---

## 4. How to Promote to Production

### Step 1: Trigger the production workflow

1. Go to GitHub → your repo → **Actions** tab
2. Click **"CD — Deploy to Production (Canary)"**
3. Click **"Run workflow"**
4. Enter the image tag (e.g. `sha-abc1234`) — find it in the CI run logs
5. Type `DEPLOY` in the confirmation field
6. Click **"Run workflow"**

### Step 2: Approve the deployment

GitHub will pause and wait for a required reviewer to approve.  
The reviewer goes to: GitHub → Actions → the waiting run → **Review deployments** → **Approve**

### Step 3: Monitor the canary (10 minutes)

Watch the Grafana dashboard during rollout:

```bash
# Access Grafana:
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
# Open: http://localhost:3000
# Dashboard: "Payday Platform — SLO Dashboard"

# OR watch the rollout directly:
kubectl argo rollouts get rollout payments-api -n production --watch
```

You should see:
- Error rate staying below 5%
- Latency staying below 500ms
- No spike in pod restarts

### Step 4: Promote to 100%

If metrics look healthy after 10+ minutes:

```bash
kubectl argo rollouts promote payments-api -n production
kubectl argo rollouts promote auth-api -n production
```

The new version now handles 100% of traffic.

---

## 5. How to Rollback

### Emergency rollback (canary abort):

```bash
# Immediately revert canary — old version takes 100% traffic back
./scripts/rollback.sh payments-api production
./scripts/rollback.sh auth-api production
```

### Rollback staging:

```bash
./scripts/rollback.sh payments-api staging
```

### Rollback to a specific version:

```bash
# See rollout history
kubectl argo rollouts history rollout/payments-api -n production

# Rollback to a specific revision
kubectl argo rollouts undo payments-api -n production --to-revision=3
```

---

## 6. Viewing Logs and Metrics

### Logs (via Grafana/Loki):

```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
# Open Grafana → Explore → Select Loki → Filter by:
#   {app="payments-api", namespace="production"}
```

Or view directly with kubectl:

```bash
# Last 100 lines from all payments-api pods
kubectl logs -l app=payments-api -n production --tail=100

# Follow live logs
kubectl logs -l app=payments-api -n production -f

# Previous crashed container logs
kubectl logs <pod-name> -n production --previous
```

### Metrics (Grafana):

```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
# Open: http://localhost:3000
# Username: admin
# Password: payday-grafana-admin
```

Key dashboards:
- **Payday Platform — SLO Dashboard**: Error rates, latency, request volume
- **Kubernetes / Compute Resources / Namespace**: CPU, memory per namespace
- **Kubernetes / Pods**: Individual pod health

### Distributed Traces (Jaeger):

```bash
kubectl port-forward svc/jaeger -n monitoring 16686:16686
# Open: http://localhost:16686
# Select service: payments-api
# Find traces showing slow requests or errors
```
