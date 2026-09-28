terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Chicken-and-egg: this stack creates the state bucket, so it keeps its own
  # state locally. It is small, rarely changes and holds no secrets. Once the
  # bucket exists you can migrate it with a backend "s3" block + `init -migrate-state`.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
