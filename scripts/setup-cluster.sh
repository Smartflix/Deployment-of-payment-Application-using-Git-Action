#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# SETUP SCRIPT — Install all platform components on your EKS cluster
# ─────────────────────────────────────────────────────────────────────────────
# Run this ONCE after your EKS cluster is created by Terraform.
# It installs: NGINX Ingress, Argo CD, Argo Rollouts, Prometheus/Grafana, Loki, Jaeger, Velero
#
# USAGE:
#   chmod +x scripts/setup-cluster.sh
#   ./scripts/setup-cluster.sh

set -euo pipefail   # Exit on any error

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Payday Platform — Cluster Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Prerequisites check ────────────────────────────────────────────────────────
for tool in kubectl helm aws; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: '$tool' is not installed. Please install it first."
    exit 1
  fi
done

echo "✓ Prerequisites OK (kubectl, helm, aws)"

# ── Step 1: Apply namespaces ──────────────────────────────────────────────────
echo ""
echo "STEP 1: Creating namespaces..."
kubectl apply -f k8s/namespaces/namespaces.yaml
echo "✓ Namespaces created"

# ── Step 2: Install NGINX Ingress Controller ──────────────────────────────────
echo ""
echo "STEP 2: Installing NGINX Ingress Controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.type=LoadBalancer \
  --wait --timeout 5m
echo "✓ NGINX Ingress installed"

# ── Step 3: Install Argo CD ───────────────────────────────────────────────────
echo ""
echo "STEP 3: Installing Argo CD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
echo "✓ Argo CD installed"

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo ""
echo "  Argo CD UI:      kubectl port-forward svc/argocd-server -n argocd 8443:443"
echo "  Argo CD URL:     https://localhost:8443"
echo "  Username:        admin"
echo "  Password:        ${ARGOCD_PASSWORD}"
echo ""

# ── Step 4: Install Argo Rollouts ─────────────────────────────────────────────
echo "STEP 4: Installing Argo Rollouts..."
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=120s

# Install the Argo Rollouts kubectl plugin
curl -sLO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
echo "✓ Argo Rollouts installed"

# ── Step 5: Install Prometheus + Grafana ──────────────────────────────────────
echo ""
echo "STEP 5: Installing Prometheus + Grafana (kube-prometheus-stack)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values k8s/observability/prometheus-values.yaml \
  --wait --timeout 10m
echo "✓ Prometheus + Grafana installed"
echo ""
echo "  Grafana URL:     kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80"
echo "  Grafana user:    admin"
echo "  Grafana pass:    payday-grafana-admin"

# ── Step 6: Install Loki (log aggregation) ────────────────────────────────────
echo ""
echo "STEP 6: Installing Loki (centralized logging)..."
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install loki grafana/loki-stack \
  --namespace monitoring \
  --values k8s/observability/loki-values.yaml \
  --wait --timeout 5m
echo "✓ Loki installed"

# ── Step 7: Install Jaeger (distributed tracing) ──────────────────────────────
echo ""
echo "STEP 7: Installing Jaeger..."
kubectl apply -f k8s/observability/jaeger.yaml
echo "✓ Jaeger installed"
echo "  Jaeger UI:       kubectl port-forward svc/jaeger -n monitoring 16686:16686"

# ── Step 8: Apply custom alert rules ──────────────────────────────────────────
echo ""
echo "STEP 8: Applying Prometheus alert rules..."
kubectl apply -f k8s/observability/alert-rules.yaml
echo "✓ Alert rules applied"

# ── Step 9: Apply resource quotas ─────────────────────────────────────────────
echo ""
echo "STEP 9: Applying resource quotas..."
kubectl apply -f k8s/autoscaling/resource-quotas.yaml
echo "✓ Resource quotas applied"

# ── Step 10: Install Velero (backup) ─────────────────────────────────────────
echo ""
echo "STEP 10: Velero backup..."
echo "  NOTE: Velero requires manual setup with your AWS S3 bucket."
echo "  Follow the instructions in k8s/backup/velero-schedule.yaml"
echo ""

# ── Done ─────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cluster setup COMPLETE!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "NEXT STEPS:"
echo "  1. Register your Git repo in Argo CD:"
echo "     kubectl apply -f argocd/applications/app-of-apps.yaml"
echo "  2. Set up GitHub Secrets (see README.md)"
echo "  3. Push code to trigger your first CI/CD run"
echo ""
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "<pending>")
echo "  Ingress Hostname: ${INGRESS_IP}"
echo "  Point your domain's DNS to the hostname above."
