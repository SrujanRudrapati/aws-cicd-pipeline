# terraform init -backend-config=env/dev.backend.hcl -backend-config=bucket=$TF_STATE_BUCKET
key          = "aws-cicd-pipeline/dev/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true # S3-native state locking (Terraform >= 1.10)
