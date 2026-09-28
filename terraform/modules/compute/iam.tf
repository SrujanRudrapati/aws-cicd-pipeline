data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Name must stay "<project>-<env>-*": the CI deploy role is only allowed to
# manage IAM roles and instance profiles matching that pattern.
resource "aws_iam_role" "app" {
  name               = "${var.name}-app"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

# Session Manager instead of SSH: no port 22, no key pairs, sessions are logged.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level permissions
  }

  statement {
    sid = "EcrPullAppImage"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [var.ecr_repository_arn]
  }

  statement {
    sid       = "ReadDatabaseCredentials"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }

  statement {
    sid = "ShipContainerLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [aws_cloudwatch_log_group.app.arn, "${aws_cloudwatch_log_group.app.arn}:*"]
  }

  statement {
    sid       = "FetchBootstrapBundle"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.bootstrap.arn}/ansible/*"]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "app-runtime"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name}-app"
  role = aws_iam_role.app.name
}
