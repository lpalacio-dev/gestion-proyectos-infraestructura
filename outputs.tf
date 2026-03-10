# ==============================================================================
# outputs.tf — Valores que Terraform imprime al terminar
# ==============================================================================

# ------------------------------------------------------------------------------
# Etapa 1: ECR + ECS
# ------------------------------------------------------------------------------

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
  description = "ID del Security Group de los tasks ECS"
  value       = aws_security_group.ecs_tasks.id
}

output "cloudwatch_log_group" {
  description = "Nombre del Log Group en CloudWatch donde verás los logs de tu API"
  value       = aws_cloudwatch_log_group.ecs.name
}

# ------------------------------------------------------------------------------
# Etapa 2: ALB
# ------------------------------------------------------------------------------

output "alb_dns_name" {
  description = "DNS público del ALB — úsalo para probar tu API mientras no tengas dominio"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ARN del ALB — necesario para agregar HTTPS en la siguiente etapa"
  value       = aws_lb.main.arn
}

output "alb_security_group_id" {
  description = "ID del Security Group del ALB"
  value       = aws_security_group.alb.id
}

output "target_group_arn" {
  description = "ARN del Target Group — lo usará Auto Scaling en la Etapa 4"
  value       = aws_lb_target_group.backend.arn
}

output "api_url" {
  description = "URL base de tu API — pruébala en el navegador con /health al final"
  value       = "http://${aws_lb.main.dns_name}"
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
