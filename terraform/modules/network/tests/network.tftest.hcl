# Plan-only unit tests with a mocked provider: no AWS account or credentials
# needed. Run with `terraform test` from terraform/modules/network.

mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  override_data {
    target = data.aws_vpc_endpoint_service.s3
    values = {
      service_name = "com.amazonaws.us-east-1.s3"
    }
  }
}

variables {
  name     = "test"
  vpc_cidr = "10.10.0.0/16"
  az_count = 2
}

run "dev_uses_a_single_nat_gateway" {
  command = plan

  variables {
    single_nat_gateway = true
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "dev should create exactly one NAT gateway"
  }

  assert {
    condition     = length(aws_route.app_nat) == 2
    error_message = "every app subnet needs a default route, even with a shared NAT"
  }

  assert {
    condition     = join(",", local.azs) == "us-east-1a,us-east-1b"
    error_message = "should span the first two available AZs"
  }
}

run "prod_uses_one_nat_gateway_per_az" {
  command = plan

  variables {
    single_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "prod should create one NAT gateway per AZ"
  }
}

run "tiers_get_non_overlapping_subnets_in_each_az" {
  command = plan

  variables {
    single_nat_gateway = true
  }

  assert {
    condition     = aws_subnet.public[*].cidr_block == ["10.10.0.0/24", "10.10.1.0/24"]
    error_message = "unexpected public subnet CIDRs"
  }

  assert {
    condition     = aws_subnet.app[*].cidr_block == ["10.10.10.0/24", "10.10.11.0/24"]
    error_message = "unexpected app subnet CIDRs"
  }

  assert {
    condition     = aws_subnet.db[*].cidr_block == ["10.10.20.0/24", "10.10.21.0/24"]
    error_message = "unexpected db subnet CIDRs"
  }

  assert {
    condition     = aws_subnet.public[0].availability_zone != aws_subnet.public[1].availability_zone
    error_message = "subnets of a tier must be spread across AZs"
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : !s.map_public_ip_on_launch])
    error_message = "public subnets must not auto-assign public IPs"
  }
}

run "rejects_non_16_cidr" {
  command = plan

  variables {
    vpc_cidr           = "10.10.0.0/20"
    single_nat_gateway = true
  }

  expect_failures = [var.vpc_cidr]
}
