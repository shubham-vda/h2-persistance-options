variable "aws_region" {
  description = "AWS region the mock-service fleet runs in."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to every resource created here, e.g. \"mock-svc\"."
  type        = string
  default     = "mock-svc"
}

variable "vpc_id" {
  description = "VPC that the ECS tasks and EFS mount targets live in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets (one per AZ you want mount targets in) for both ECS tasks and the EFS mount targets."
  type        = list(string)
}

variable "ecs_tasks_security_group_id" {
  description = "Security group already attached to the ECS tasks/service; EFS's own SG will allow NFS (2049) from this group."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the mock-service tasks."
  type        = number
  default     = 14
}
