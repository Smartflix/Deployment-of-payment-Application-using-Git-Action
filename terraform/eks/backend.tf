terraform {
  backend "s3" {
    bucket = "smartflix-terraform-state-867041163440"
    key    = "terraform.tfstate"
    region = "us-east-1"
  }
}