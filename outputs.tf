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

# ------------------------------------------------------------------------------
# Etapa 3: RDS + Secrets Manager
# ------------------------------------------------------------------------------

output "rds_endpoint" {
  description = "Endpoint del RDS — host al que se conecta tu app (sin puerto)"
  value       = aws_db_instance.postgres.address
}

output "rds_port" {
  description = "Puerto PostgreSQL"
  value       = aws_db_instance.postgres.port
}

output "rds_db_name" {
  description = "Nombre de la base de datos creada en RDS"
  value       = aws_db_instance.postgres.db_name
}

output "db_secret_arn" {
  description = "ARN del connection string — cópialo en terraform.tfvars como db_secret_arn"
  value       = aws_secretsmanager_secret.db_connection.arn
}

output "jwt_secret_arn" {
  description = "ARN del JWT Key secret — cópialo en terraform.tfvars como jwt_secret_arn"
  value       = aws_secretsmanager_secret.jwt_key.arn
}

# ------------------------------------------------------------------------------
# Etapa 5: S3 + CloudFront (Frontend)
# ------------------------------------------------------------------------------

output "s3_bucket_name" {
  description = "Nombre del bucket S3 — úsalo en GitHub Actions para subir el build de Angular"
  value       = aws_s3_bucket.frontend.id
}

output "s3_bucket_arn" {
  description = "ARN del bucket S3 frontend"
  value       = aws_s3_bucket.frontend.arn
}

output "cloudfront_distribution_id" {
  description = "ID de la distribución CloudFront — necesario para invalidar caché en cada deploy"
  value       = aws_cloudfront_distribution.frontend.id
}

output "cloudfront_domain_name" {
  description = "URL pública de tu frontend — ábrela en el navegador para ver tu Angular app"
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

# ------------------------------------------------------------------------------
# Etapa 4: CloudWatch Alarms
# ------------------------------------------------------------------------------

output "cloudwatch_alarms" {
  description = "Nombres de las alarms creadas — búscalas en CloudWatch → Alarms"
  value = {
    ecs_cpu_high           = aws_cloudwatch_metric_alarm.ecs_cpu_high.alarm_name
    ecs_memory_high        = aws_cloudwatch_metric_alarm.ecs_memory_high.alarm_name
    alb_5xx_errors         = aws_cloudwatch_metric_alarm.alb_5xx_errors.alarm_name
    alb_4xx_errors         = aws_cloudwatch_metric_alarm.alb_4xx_errors.alarm_name
    alb_latency_high       = aws_cloudwatch_metric_alarm.alb_latency_high.alarm_name
    alb_no_healthy_targets = aws_cloudwatch_metric_alarm.alb_no_healthy_targets.alarm_name
  }
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
