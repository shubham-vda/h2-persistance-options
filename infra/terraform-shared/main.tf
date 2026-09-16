terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# One EFS filesystem shared by every QA's mock-service instance. Per-QA
# isolation comes from EFS Access Points (see infra/scripts/provision-qa-instance.sh),
# not from separate filesystems - that keeps this a one-time, mostly-static
# piece of infra instead of something the pipeline has to create per QA.
resource "aws_efs_file_system" "mock_service_data" {
  creation_token  = "${var.name_prefix}-h2-data"
  encrypted       = true
  throughput_mode = "bursting"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name    = "${var.name_prefix}-h2-data"
    Purpose = "Per-QA H2 database files for mock-service instances"
  }
}

resource "aws_security_group" "efs" {
  name        = "${var.name_prefix}-efs-sg"
  description = "Allow NFS from the mock-service ECS tasks"
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from ECS tasks"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [var.ecs_tasks_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-efs-sg"
  }
}

resource "aws_efs_mount_target" "mock_service_data" {
  for_each        = toset(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.mock_service_data.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

resource "aws_ecs_cluster" "mock_service" {
  name = "${var.name_prefix}-cluster"
}

resource "aws_cloudwatch_log_group" "mock_service" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution_role" {
  name               = "${var.name_prefix}-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy_attachment" "execution_role_managed" {
  role       = aws_iam_role.execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role: least-privilege, only what the app itself needs at runtime.
# EFS access is enforced by the access point's POSIX permissions plus the
# task definition's authorizationConfig, not by IAM here - no extra policy
# is needed for basic file read/write over the mounted volume.
resource "aws_iam_role" "task_role" {
  name               = "${var.name_prefix}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}
