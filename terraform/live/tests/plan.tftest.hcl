# Plans the whole stack against a mocked AWS provider (no account needed),
# using the *committed* tfvars, so it proves both environments come from the
# same code and checks what is supposed to differ between them.
# Run from terraform/live once per environment (`make tf-test` does both):
#   terraform init -backend=false
#   terraform test -var-file=env/dev.tfvars
#   terraform test -var-file=env/prod.tfvars

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_vpc_endpoint_service" {
    defaults = {
      service_name = "com.amazonaws.us-east-1.s3"
    }
  }

  mock_data "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-east-1:123456789012:repository/aws-cicd-pipeline-app"
      repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/aws-cicd-pipeline-app"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0123456789abcdef0"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_default_tags" {
    defaults = {
      tags = { Project = "aws-cicd-pipeline" }
    }
  }

  # Computed ARNs that other resources validate as ARNs at plan time.
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:123456789012:mock-alerts"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }

  mock_resource "aws_iam_instance_profile" {
    defaults = {
      arn = "arn:aws:iam::123456789012:instance-profile/mock"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::mock-bucket"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/mock/0123456789abcdef"
      arn_suffix = "app/mock/0123456789abcdef"
      dns_name   = "mock-123456.us-east-1.elb.amazonaws.com"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/mock/0123456789abcdef"
      arn_suffix = "targetgroup/mock/0123456789abcdef"
    }
  }

  mock_resource "aws_launch_template" {
    defaults = {
      id             = "lt-0123456789abcdef0"
      latest_version = 1
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      address = "mock.abcdefghijkl.us-east-1.rds.amazonaws.com"
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-mock"
        kms_key_id    = "arn:aws:kms:us-east-1:123456789012:key/mock"
        secret_status = "active"
      }]
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  image_tag = "0123456789abcdef0123456789abcdef01234567"
}

run "plan" {
  command = plan

  assert {
    condition     = output.environment_summary.nat_gateways == (var.environment == "prod" ? 2 : 1)
    error_message = "prod needs a NAT gateway per AZ; dev shares one"
  }

  assert {
    condition     = output.environment_summary.db_multi_az == (var.environment == "prod")
    error_message = "the database must be Multi-AZ in prod (and only there, to save cost)"
  }

  assert {
    condition     = var.environment != "prod" || (var.asg_min_size >= 2 && var.db_deletion_protection && !var.db_skip_final_snapshot)
    error_message = "prod needs >= 2 instances, RDS deletion protection and a final snapshot"
  }

  assert {
    condition     = output.deployed_image == "123456789012.dkr.ecr.us-east-1.amazonaws.com/aws-cicd-pipeline-app:0123456789abcdef0123456789abcdef01234567"
    error_message = "the image URI must be built from the ECR repository and the requested tag"
  }

  assert {
    condition     = startswith(output.app_url, "http://")
    error_message = "without a certificate the app is served over plain HTTP"
  }
}

run "https_when_certificate_is_set" {
  command = plan

  variables {
    certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    public_domain   = "app.example.com"
  }

  assert {
    condition     = output.app_url == "https://app.example.com" && output.environment_summary.https
    error_message = "app_url should switch to HTTPS on the configured domain"
  }
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}
