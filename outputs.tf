# ==============================================================================
# outputs.tf — Valores que Terraform imprime al terminar
# ==============================================================================
# Después de correr "terraform apply", estos valores aparecen en la terminal.
# También los puedes consultar después con: terraform output
#
# Son útiles para copiar en GitHub Secrets, en tu app, o para la siguiente
# etapa de infraestructura.
# ==============================================================================

output "ecr_repository_url" {
  description = "URL del repositorio ECR — úsala en GitHub Actions para hacer push de imágenes"
  value       = aws_ecr_repository.backend.repository_url
}

output "ecr_repository_name" {
  description = "Nombre del repositorio ECR"
  value       = aws_ecr_repository.backend.name
}

output "ecs_cluster_name" {
  description = "Nombre del cluster ECS — necesario en GitHub Actions (ECS_CLUSTER secret)"
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  description = "ARN del cluster ECS"
  value       = aws_ecs_cluster.main.arn
}

output "ecs_service_name" {
  description = "Nombre del servicio ECS — necesario en GitHub Actions (ECS_SERVICE secret)"
  value       = aws_ecs_service.backend.name
}

output "task_definition_family" {
  description = "Nombre de la familia de Task Definition — necesario en GitHub Actions (TASK_FAMILY secret)"
  value       = aws_ecs_task_definition.backend.family
}

output "container_name" {
  description = "Nombre del contenedor — necesario en GitHub Actions (CONTAINER_NAME secret)"
  value       = "${var.project_name}-container"
}

output "ecs_task_execution_role_arn" {
  description = "ARN del rol de ejecución de ECS"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "ecs_security_group_id" {
  description = "ID del Security Group de los tasks ECS — lo usaremos en la Etapa 2 (ALB)"
  value       = aws_security_group.ecs_tasks.id
}

output "cloudwatch_log_group" {
  description = "Nombre del Log Group en CloudWatch donde verás los logs de tu API"
  value       = aws_cloudwatch_log_group.ecs.name
}

# ==============================================================================
# Resumen para GitHub Actions
# ==============================================================================
# Copia estos valores en los Secrets de tu repositorio de GitHub:
#   Settings → Secrets and variables → Actions → New repository secret
# ==============================================================================

output "github_actions_secrets_summary" {
  description = "Valores a configurar como GitHub Secrets"
  value = {
    ECR_REPOSITORY  = aws_ecr_repository.backend.name
    TASK_FAMILY     = aws_ecs_task_definition.backend.family
    CONTAINER_NAME  = "${var.project_name}-container"
    ECS_SERVICE     = aws_ecs_service.backend.name
    ECS_CLUSTER     = aws_ecs_cluster.main.name
  }
}
