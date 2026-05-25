# Outputs — displayed after "terraform apply" finishes
# Use these values to connect kubectl and configure your services.

output "cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name"
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "EKS API server endpoint"
  sensitive   = true
}

output "kubeconfig_command" {
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
  description = "Run this command to configure kubectl for your EKS cluster"
}

output "ecr_registry_url" {
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  description = "ECR registry URL prefix — used as REGISTRY in GitHub Actions secrets"
}

output "ecr_repositories" {
  value       = { for k, v in aws_ecr_repository.services : k => v.repository_url }
  description = "ECR repository URLs for each service"
}

output "rds_endpoint" {
  value       = aws_db_instance.payday.endpoint
  description = "RDS PostgreSQL endpoint — use this in your DATABASE_URL secret"
  sensitive   = true
}

output "rds_database_url" {
  value       = "postgres://${var.db_username}:PASSWORD@${aws_db_instance.payday.endpoint}/${var.db_name}?sslmode=require"
  description = "DATABASE_URL template — replace PASSWORD with your actual db_password"
  sensitive   = true
}

output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "VPC ID"
}

output "shared_s3_bucket" {
  value       = aws_s3_bucket.velero.bucket
  description = "Shared S3 bucket — holds Terraform state (terraform/) and Velero backups (velero/)"
}

output "velero_iam_role_arn" {
  value       = aws_iam_role.velero.arn
  description = "IAM role ARN for Velero — use this when installing Velero with IRSA"
}

output "velero_install_command" {
  value = <<-EOT
    velero install \
      --provider aws \
      --plugins velero/velero-plugin-for-aws:v1.9.0 \
      --bucket ${aws_s3_bucket.velero.bucket} \
      --backup-location-config region=${var.aws_region},prefix=velero \
      --snapshot-location-config region=${var.aws_region} \
      --service-account-annotations eks.amazonaws.com/role-arn=${aws_iam_role.velero.arn} \
      --no-secret
  EOT
  description = "Run this command to install Velero on the cluster after terraform apply"
}
