# Stack 02-eks: EKS control plane with a public endpoint restricted to the
# operator, a small managed node group for system pods and a GPU node group
# (3x g5.xlarge, Bottlerocket NVIDIA) for the model servers, and an explicit
# admin access entry. Network comes from 01. Istio, the Endpoint Picker and
# vLLM are installed by the scripts, not by Terraform.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }

  # Partial configuration: the bucket name carries the account ID, so
  # scripts/lib.sh passes it with -backend-config=bucket=... at init.
  backend "s3" {
    key          = "eks/eks.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

# Lab identity: the operator's credentials (AWS_PROFILE). A production repo
# selects a role per workspace and keeps the plan-only role as the fallback;
# here assume_role is used only when var.assume_role.role_arn is set.
provider "aws" {
  region = var.assume_role.region

  default_tags {
    tags = var.tags
  }

  dynamic "assume_role" {
    for_each = var.assume_role.role_arn == null ? [] : [var.assume_role.role_arn]

    content {
      role_arn = assume_role.value
    }
  }
}
