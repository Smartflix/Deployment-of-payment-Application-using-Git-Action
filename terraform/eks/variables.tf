# ── Required variables ────────────────────────────────────────────────────────
variable "aws_region" {
  description = "AWS region where all resources will be created."
  type        = string
  default     = "us-east-1"
  # Other options: "us-west-2", "eu-west-1", "ap-southeast-1"
}

# ── Optional variables ────────────────────────────────────────────────────────
variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
  default     = "payday-cluster"
}

variable "environment" {
  description = "Environment name used for tagging and naming resources."
  type        = string
  default     = "production"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster. EKS only allows one minor version upgrade at a time (e.g. 1.29 → 1.30, then 1.30 → 1.31)."
  type        = string
  default     = "1.30"
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes. t3.medium = 2 vCPU, 4 GB RAM."
  type        = string
  default     = "t3.medium"
  # Larger: "t3.large" (2 vCPU, 8 GB), "m5.large" (2 vCPU, 8 GB, better for prod)
}

variable "node_min_size" {
  description = "Minimum number of worker nodes (autoscaling lower bound)."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes (autoscaling upper bound)."
  type        = number
  default     = 10
}

variable "node_desired_size" {
  description = "Initial/desired number of worker nodes."
  type        = number
  default     = 3
}

variable "node_disk_size" {
  description = "Size of each node's EBS disk in GB."
  type        = number
  default     = 50
}

# ── RDS (Database) variables ──────────────────────────────────────────────────
variable "db_instance_class" {
  description = "RDS instance type. db.t3.micro is in the AWS free tier."
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Name of the PostgreSQL database."
  type        = string
  default     = "payday"
}

variable "db_username" {
  description = "Master username for the RDS database."
  type        = string
  default     = "payday"
}

variable "db_password" {
  description = "Master password for the RDS database."
  type        = string
  sensitive   = true    # Marked sensitive: hidden from logs and output
  # Set via: terraform apply -var="db_password=YOUR_SECURE_PASSWORD"
  # Or set TF_VAR_db_password environment variable
}

variable "db_allocated_storage" {
  description = "RDS storage in GB."
  type        = number
  default     = 20
}
