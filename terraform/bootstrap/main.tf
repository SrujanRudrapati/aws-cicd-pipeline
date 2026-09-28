data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition
  state_bucket = "${var.project}-tfstate-${local.account_id}"
}

# ---------------------------------------------------------------- state bucket
# Remote state for terraform/live. Locking uses S3 conditional writes
# (`use_lockfile = true`, Terraform >= 1.10), so no DynamoDB table is needed.

resource "aws_s3_bucket" "state" {
  bucket        = local.state_bucket
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 20
    }
  }
}

data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---------------------------------------------------------------------- ECR

resource "aws_ecr_repository" "app" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "IMMUTABLE" # a tag (git SHA) always means the same bytes
  force_delete         = var.force_destroy

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Drop untagged layers/manifests after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 30 most recent images (enough history to roll back)"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ------------------------------------------------------ GitHub Actions (OIDC)
# The workflow exchanges its short-lived GitHub OIDC token for AWS credentials,
# so no long-lived access keys are stored in GitHub.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # No thumbprint_list: AWS validates GitHub's certificate chain itself.
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only pushes to main (image push) and jobs bound to a GitHub Environment
    # (deploy-dev / deploy-prod, which carry their own protection rules).
    # Pull requests, including ones from forks, cannot assume this role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:ref:refs/heads/main",
        "repo:${var.github_repository}:environment:*",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = "${var.project}-github-actions"
  description          = "Assumed by GitHub Actions in ${var.github_repository} to push images and run Terraform."
  assume_role_policy   = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600
}

# PowerUserAccess covers every service Terraform manages here except IAM.
resource "aws_iam_role_policy_attachment" "github_power_user" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

# IAM is granted narrowly: only the instance role / profile the compute module
# creates, named "<project>-<env>-*". The role cannot touch any other IAM entity,
# and can only attach the SSM managed policy, so it cannot escalate itself.
locals {
  env_role_arns = [
    for env in var.environments : "arn:${local.partition}:iam::${local.account_id}:role/${var.project}-${env}-*"
  ]
  env_profile_arns = [
    for env in var.environments : "arn:${local.partition}:iam::${local.account_id}:instance-profile/${var.project}-${env}-*"
  ]
}

data "aws_iam_policy_document" "github_iam" {
  statement {
    sid    = "ManageEnvironmentRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:PassRole",
    ]
    resources = local.env_role_arns
  }

  statement {
    sid       = "AttachOnlySsmCore"
    effect    = "Allow"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = local.env_role_arns

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"]
    }
  }

  statement {
    sid    = "ManageEnvironmentInstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:ListInstanceProfileTags",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = local.env_profile_arns
  }

  statement {
    sid    = "CreateServiceLinkedRoles"
    effect = "Allow"
    # First-time use of ASG / ELB / RDS in an account creates these.
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"]
  }
}

resource "aws_iam_role_policy" "github_iam" {
  name   = "scoped-iam"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_iam.json
}
