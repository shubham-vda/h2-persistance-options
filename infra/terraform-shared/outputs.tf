output "efs_file_system_id" {
  value = aws_efs_file_system.mock_service_data.id
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.mock_service.name
}

output "execution_role_arn" {
  value = aws_iam_role.execution_role.arn
}

output "task_role_arn" {
  value = aws_iam_role.task_role.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.mock_service.name
}
