# Payday Platform — Production DevOps Project

A production-ready Kubernetes platform for a fintech payments system built on **AWS EKS**.

---

## Architecture at a Glance

```
Developer pushes code
        │
        ▼
┌───────────────────────────────────────────────────────────┐
│  GitHub Actions CI (ci.yml)                               │
│  ① Run tests  ② Build Docker images  ③ Trivy security    │
│  scan  ④ Push to Amazon ECR                               │
└──────────────────────────┬────────────────────────────────┘
                           │ on main branch push
                           ▼
┌───────────────────────────────────────────────────────────┐
│  GitHub Actions CD — Staging (deploy-staging.yml)         │
│  ① Apply K8s manifests → staging namespace                │
│  ② Wait for rollout  ③ Smoke tests  ④ Auto-rollback       │
└──────────────────────────┬────────────────────────────────┘
                           │ manual trigger + human approval
                           ▼
┌───────────────────────────────────────────────────────────┐
│  GitHub Actions CD — Production (deploy-production.yml)   │
│  Argo Rollouts CANARY:                                    │
│   10% → Prometheus check → 30% → 5min pause →            │
│   50% → MANUAL APPROVAL → 100%                            │
│   Auto-rollback if error rate > 5%                        │
└──────────────────────────┬────────────────────────────────┘
                           │
                           ▼
┌───────────────────────────────────────────────────────────┐
│  AWS EKS Cluster  (Terraform provisioned)                 │
│  ┌──────────┐ ┌──────────────┐ ┌────────┐ ┌──────────┐  │
│  │ frontend │ │  auth-api    │ │payments│ │  worker  │  │
│  │  Nginx   │ │  Go + JWT    │ │  Flask │ │  Python  │  │
│  └──────────┘ └──────────────┘ └────────┘ └──────────┘  │
│                         ▼                                 │
│                   Amazon RDS (PostgreSQL)                 │
│                                                           │
│  Monitoring: Prometheus + Grafana + Loki + Jaeger         │
│  GitOps:     Argo CD                                      │
│  Backup:     Velero → S3                                  │
└───────────────────────────────────────────────────────────┘
```

---

## Project Structure

```
payday_platform/
├── .github/workflows/
│   ├── ci.yml                     # Build, test, Trivy scan, push to ECR
│   ├── deploy-staging.yml         # Auto-deploy to staging on main push
│   └── deploy-production.yml      # Manual canary deploy to production
│
├── apps/
│   ├── auth-api/                  # Go — JWT authentication service
│   ├── payments-api/              # Python/Flask — payment CRUD
│   ├── worker/                    # Python — background payment processor
│   └── frontend/                  # Nginx + HTML — dashboard UI
│
├── k8s/
│   ├── namespaces/               # staging, production, monitoring, argocd
│   ├── apps/                     # Deployments, Services, HPAs per service
│   ├── rollouts/                 # Argo Rollouts canary configs (production)
│   ├── database/                 # PostgreSQL StatefulSet (for staging)
│   ├── ingress/                  # NGINX Ingress routes
│   ├── observability/            # Prometheus, Grafana, Loki, Jaeger configs
│   ├── autoscaling/              # ResourceQuotas, LimitRanges
│   └── backup/                   # Velero backup schedules
│
├── terraform/eks/                 # AWS EKS + RDS + ECR infrastructure
├── argocd/applications/           # Argo CD app manifests
├── scripts/
│   ├── setup-cluster.sh          # Install all platform tools on EKS
│   ├── rollback.sh               # Emergency rollback any service
│   └── smoke-test.sh             # Verify platform is healthy
├── docs/
│   ├── developer-guide.md        # How to develop, deploy, rollback
│   └── runbooks/                 # On-call incident playbooks
│       ├── pod-crashloop.md
│       ├── failed-deploy.md
│       └── db-connection-loss.md
└── docker-compose.yml            # Local development (no K8s needed)
```

---

## Tools & Technologies

| Category | Tool | Purpose |
|---|---|---|
| **Cloud** | AWS | Cloud provider |
| **Kubernetes** | Amazon EKS | Managed K8s cluster |
| **Database** | Amazon RDS (PostgreSQL) | Managed database |
| **Registry** | Amazon ECR | Docker image storage |
| **IaC** | Terraform | Provision EKS + RDS + ECR |
| **CI/CD** | GitHub Actions | Build, test, deploy pipeline |
| **GitOps** | Argo CD | Sync git → K8s |
| **Canary** | Argo Rollouts | Safe gradual traffic shifting |
| **Security** | Trivy | Image vulnerability scanning |
| **Ingress** | NGINX Ingress | Route external traffic |
| **Metrics** | Prometheus + Grafana | Dashboards + alerting |
| **Logs** | Grafana Loki | Centralized log aggregation |
| **Traces** | Jaeger | Distributed request tracing |
| **Autoscaling** | Kubernetes HPA | Scale pods on CPU/memory |
| **Backup** | Velero | Backup cluster + volumes to S3 |

---

## Step-by-Step Setup Guide 

### Prerequisites — Install these tools first

```bash
# 1. AWS CLI — to talk to AWS from your terminal
#    Download from: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html
aws --version

# 2. Terraform — to create the cloud infrastructure
#    Download from: https://developer.hashicorp.com/terraform/downloads
terraform --version

# 3. kubectl — to talk to Kubernetes
#    Download from: https://kubernetes.io/docs/tasks/tools/
kubectl version --client

# 4. Helm — Kubernetes package manager
#    Download from:wget https://helm.sh/docs/intro/install/
helm version

# 5. Configure AWS credentials
aws configure
# Enter your AWS Access Key ID, Secret, Region (e.g. us-east-1), Output (json)
```

### Step 1: Provision AWS Infrastructure with Terraform

```bash
cd terraform/eks

# Download required Terraform modules
terraform init

# See what will be created (no changes yet)
terraform plan -var="db_password=YourStrongPassword123!"

# Create everything (takes 15-20 minutes)
terraform apply -var="db_password=YourStrongPassword123!"

# When done, you'll see outputs like:
#   kubeconfig_command = "aws eks update-kubeconfig --name payday-cluster --region us-east-1"
#   ecr_registry_url   = "123456789.dkr.ecr.us-east-1.amazonaws.com"
#   rds_endpoint       = "payday-cluster-postgres.xyz.us-east-1.rds.amazonaws.com"
```

### Step 2: Connect kubectl to your EKS cluster

```bash
# Run the kubeconfig_command from terraform output:
aws eks update-kubeconfig --name payday-cluster --region us-east-1

# Test the connection:
kubectl get nodes
# You should see 3 nodes listed as Ready
```

### Step 3: Install platform tools on the cluster

```bash
cd ../../  # Back to project root
chmod +x scripts/setup-cluster.sh
./scripts/setup-cluster.sh

# This installs:
# - NGINX Ingress Controller
# - Argo CD
# - Argo Rollouts
# - Prometheus + Grafana
# - Loki
# - Jaeger
# (Takes about 10 minutes)
```

### Step 4: Configure GitHub Secrets

Go to: **GitHub → Your Repo → Settings → Secrets and variables → Actions**

Add these secrets:

| Secret Name | Value | Where to find it |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Your AWS access key | AWS Console → IAM → Users |
| `AWS_SECRET_ACCESS_KEY` | Your AWS secret key | AWS Console → IAM → Users |
| `AWS_REGION` | `us-east-1` | Same region you used for Terraform |
| `AWS_ACCOUNT_ID` | Your 12-digit account ID | AWS Console → top-right dropdown |
| `EKS_CLUSTER_NAME` | `payday-cluster` | From Terraform output |
| `DB_PASSWORD` | Your DB password | The password you used in terraform apply |
| `JWT_SECRET` | Any random string | Generate: `openssl rand -hex 32` |
| `RDS_ENDPOINT` | Your RDS host | From `terraform output rds_endpoint` |

Also configure **Environments** in GitHub:
1. Go to Settings → Environments
2. Create environment called `staging`
3. Create environment called `production`
4. For `production` → add yourself as a Required reviewer

### Step 5: Configure Argo CD

```bash
# Access Argo CD UI:
kubectl port-forward svc/argocd-server -n argocd 8443:443
# Open https://localhost:8443 (accept the self-signed cert warning)
# Username: admin
# Password: (run this command to get it):

# Register your git repo in Argo CD:
# (First update argocd/applications/app-of-apps.yaml with YOUR repo URL)
# Then apply:
kubectl apply -f argocd/applications/app-of-apps.yaml
```

### Step 6: Push code to trigger your first pipeline

```bash
git add -A
git commit -m "initial platform setup"
git push origin main

# Go to GitHub → Actions tab → watch the CI pipeline run
# After CI passes → staging deployment starts automatically
# Check staging: kubectl get pods -n staging
```

### Step 7: Deploy to production (first time)

```bash
# After staging looks healthy, deploy to production:
# GitHub → Actions → "CD — Deploy to Production (Canary)" → Run workflow
# Enter: confirm = DEPLOY
# Approve the deployment when prompted
# Monitor: kubectl argo rollouts get rollout payments-api -n production --watch
# Promote: kubectl argo rollouts promote payments-api -n production
```

---

## Daily Commands

```bash
# See all pods
kubectl get pods -n staging
kubectl get pods -n production

# See logs
kubectl logs -l app=payments-api -n production -f

# Check canary status
kubectl argo rollouts get rollout payments-api -n production

# Emergency rollback
./scripts/rollback.sh payments-api production

# Run smoke tests
./scripts/smoke-test.sh production

# Access Grafana
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
# http://localhost:3000 admin/payday-grafana-admin

# Access Argo CD
kubectl port-forward svc/argocd-server -n argocd 8443:443
# https://localhost:8443

# Access Jaeger traces
kubectl port-forward svc/jaeger -n monitoring 16686:16686
# http://localhost:16686
```

---

## GitHub Secrets Required Summary

```
CI/CD:
  AWS_ACCESS_KEY_ID       ← AWS IAM credentials
  AWS_SECRET_ACCESS_KEY   ← AWS IAM credentials
  AWS_REGION              ← e.g. us-east-1
  AWS_ACCOUNT_ID          ← 12-digit account number

Kubernetes:
  EKS_CLUSTER_NAME        ← e.g. payday-cluster

Application:
  DB_PASSWORD             ← Strong PostgreSQL password
  JWT_SECRET              ← Random 32-char string
  RDS_ENDPOINT            ← From terraform output
```

---

## Deliverables Checklist

- [x] **Architecture Diagram** — see above diagram in this README
- [x] **Infrastructure as Code** — `terraform/eks/` (VPC + EKS + RDS + ECR)
- [x] **Containerized App** — 4 microservices with Dockerfiles + docker-compose
- [x] **CI/CD Pipeline** — GitHub Actions with tests + Trivy scan + ECR push
- [x] **Canary Deployment** — Argo Rollouts in `k8s/rollouts/`
- [x] **Security** — Trivy image scanning + non-root containers + K8s Secrets
- [x] **Observability** — Prometheus + Grafana + Loki + Jaeger + custom alerts
- [x] **Autoscaling** — HPA for all services + ResourceQuotas
- [x] **Backup** — Velero daily + weekly schedules to S3
- [x] **Runbooks** — 3 incident runbooks in `docs/runbooks/`
- [x] **Developer Guide** — `docs/developer-guide.md`

---

*Built with GitHub Actions + AWS EKS + Argo CD + Argo Rollouts + Prometheus/Grafana*
