# ─────────────────────────────────────────────────────────────────────────────
# TERRAFORM — AWS EKS + RDS + ECR Infrastructure
# ─────────────────────────────────────────────────────────────────────────────
#
# This provisions:
#   - VPC with public + private subnets across 2 AZs
#   - EKS cluster (Elastic Kubernetes Service)
#   - Managed Node Group (EC2 instances that run your pods)
#   - RDS PostgreSQL (managed database — no maintenance needed)
#   - ECR repositories (Docker image registry)
#   - IAM roles with least-privilege permissions
#
# HOW TO USE:
#   1. Install Terraform: https://developer.hashicorp.com/terraform/downloads
#   2. Install AWS CLI:   https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html
#   3. Configure AWS:    aws configure   (enter your AWS Access Key + Secret)
#   4. Run:
#        cd terraform/eks
#        terraform init
#        terraform plan -var="db_password=YourStrongPassword123"
#        terraform apply -var="db_password=YourStrongPassword123"
#   5. Connect kubectl to EKS:
#        aws eks update-kubeconfig --name payday-cluster --region us-east-1

# ── Data sources ──────────────────────────────────────────────────────────────
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# ── VPC ───────────────────────────────────────────────────────────────────────
# A Virtual Private Cloud (VPC) is your isolated network in AWS.
# We use the AWS VPC module — a well-tested, production-grade VPC setup.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"     # Your private network: 10.0.0.0 to 10.0.255.255 (65535 IPs)

  azs = slice(data.aws_availability_zones.available.names, 0, 2)  # Use 2 Availability Zones

  # Public subnets: have internet access (for load balancers)
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  # Private subnets: no direct internet access (for EKS nodes and RDS)
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  # NAT Gateway: lets private subnet resources talk to the internet (for pulling Docker images)
  enable_nat_gateway     = true
  single_nat_gateway     = true    # One NAT gateway (cheaper; for multi-AZ set to false)
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # Required tags for EKS to auto-discover subnets for load balancers
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ── IAM Role for EBS CSI Driver ──────────────────────────────────────────────
# The EBS CSI driver add-on needs this role to create/attach/detach EBS volumes.
# Without it the add-on stays stuck in CREATING forever.
# Uses IRSA (IAM Roles for Service Accounts) — no credentials stored in the cluster.
#
# NOTE: This role references module.eks.oidc_provider_arn which is created by the
# EKS module. Terraform resolves the dependency automatically.

data "aws_iam_policy_document" "ebs_csi_driver_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  name               = "${var.cluster_name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_driver_assume.json
}

# AWS provides a managed policy with exactly the permissions the EBS CSI driver needs
resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets   # Nodes in private subnets
  cluster_endpoint_public_access = true   # Allow kubectl from the internet (set to false in strict prod)

  # EKS Managed Add-ons (AWS maintains these, not you)
  # NOTE: aws-ebs-csi-driver is intentionally excluded here.
  # It is created as a separate resource below so we can attach its IAM role
  # AFTER the OIDC provider exists, avoiding a circular dependency timeout.
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  # Managed Node Group: EC2 instances that run your pods
  eks_managed_node_groups = {
    primary = {
      name           = "${var.cluster_name}-primary"
      instance_types = [var.node_instance_type]
      disk_size      = var.node_disk_size

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Automatically replace unhealthy nodes
      update_config = {
        max_unavailable_percentage = 25
      }

      labels = {
        Environment = var.environment
        NodeGroup   = "primary"
      }
    }
  }

  # Allow current AWS user/role to access the cluster
  enable_cluster_creator_admin_permissions = true
}

# ── EBS CSI Driver Add-On (standalone — avoids circular dependency) ───────────
# Separated from cluster_addons so it can explicitly depend on its IAM role.
# The IAM role must exist before the add-on is created, otherwise AWS cannot
# grant the driver permission to manage EBS volumes and it hangs in CREATING.
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = data.aws_eks_addon_version.ebs_csi.version
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi_driver,  # IAM role must be ready first
    module.eks.eks_managed_node_group_arns,         # Nodes must exist before add-on
  ]
}

# Look up the latest available version of the EBS CSI driver for this K8s version
data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}

# ── ECR Repositories (Docker Image Registry) ──────────────────────────────────
# ECR = Elastic Container Registry — stores your Docker images on AWS.
# GitHub Actions will push images here; EKS will pull from here.
locals {
  services = ["payday-auth-api", "payday-payments-api", "payday-worker", "payday-frontend"]
}

resource "aws_ecr_repository" "services" {
  for_each = toset(local.services)

  name                 = each.value
  image_tag_mutability = "MUTABLE"   # Allow re-tagging (needed for "latest" tag)

  image_scanning_configuration {
    scan_on_push = true   # Scan for vulnerabilities every time a new image is pushed
  }

  # lifecycle policy managed separately below via aws_ecr_lifecycle_policy
}

# ECR Lifecycle Policy: delete old images to save storage costs
resource "aws_ecr_lifecycle_policy" "cleanup" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 20 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── Security Group for RDS ────────────────────────────────────────────────────
resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds-sg"
  description = "Allow PostgreSQL access from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "PostgreSQL from EKS nodes"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS needs a subnet group (tells it which subnets to use)
resource "aws_db_subnet_group" "payday" {
  name       = "${var.cluster_name}-db-subnet"
  subnet_ids = module.vpc.private_subnets
}

# ── RDS PostgreSQL (Managed Database) ────────────────────────────────────────
# AWS manages backups, patching, and failover automatically.
resource "aws_db_instance" "payday" {
  identifier = "${var.cluster_name}-postgres"

  engine         = "postgres"
  engine_version = "16"   # AWS resolves this to the latest available 16.x minor version
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = 100          # Auto-scale storage up to 100 GB
  storage_type          = "gp2"
  storage_encrypted     = true         # Encrypt data at rest

  db_subnet_group_name   = aws_db_subnet_group.payday.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false       # Only accessible from within the VPC

  # Automated backups: keep for 7 days
  backup_retention_period = 7
  backup_window          = "03:00-04:00"   # 3-4 AM UTC
  maintenance_window     = "sun:04:00-sun:05:00"

  # Don't delete the database when you run "terraform destroy"
  deletion_protection      = true
  skip_final_snapshot      = false
  final_snapshot_identifier = "${var.cluster_name}-final-snapshot"

  # Performance Insights: see what's slowing down your database
  performance_insights_enabled = true

  tags = {
    Name = "${var.cluster_name}-postgres"
  }
}

# ── S3 Bucket for Velero Backups + Terraform State ───────────────────────────
# Single bucket, prefix-based separation:
#   terraform/eks/terraform.tfstate  — Terraform remote state
#   velero/                          — Velero cluster backups
resource "aws_s3_bucket" "velero" {
  bucket        = "${var.cluster_name}-velero-backups-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = {
    Name    = "${var.cluster_name}-velero-backups"
    Purpose = "terraform-state-and-velero-backups"
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket = aws_s3_bucket.velero.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning is required for Terraform state — lets you recover from accidental
# state corruption or deletion by rolling back to a previous version.
resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Expire only velero/ objects after 90 days — Terraform state must never be
# auto-deleted, so the lifecycle rule is scoped to the velero/ prefix only.
resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  bucket     = aws_s3_bucket.velero.id
  depends_on = [aws_s3_bucket_versioning.velero]

  rule {
    id     = "expire-old-velero-backups"
    status = "Enabled"

    filter {
      prefix = "velero/"
    }

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}


# IAM policy: gives Velero permission to read/write only under the velero/ prefix
resource "aws_iam_policy" "velero" {
  name        = "${var.cluster_name}-velero-policy"
  description = "Allows Velero to backup/restore K8s resources to S3 and take EBS snapshots"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = "${aws_s3_bucket.velero.arn}/velero/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.velero.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots",
          "ec2:CreateTags",
          "ec2:CreateVolume",
          "ec2:CreateSnapshot",
          "ec2:DeleteSnapshot"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM role for Velero (uses IRSA — IAM Roles for Service Accounts)
# This lets the Velero pod authenticate to AWS without storing credentials
resource "aws_iam_role" "velero" {
  name = "${var.cluster_name}-velero-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:velero:velero"
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "velero" {
  role       = aws_iam_role.velero.name
  policy_arn = aws_iam_policy.velero.arn
}
