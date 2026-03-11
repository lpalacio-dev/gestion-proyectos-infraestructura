# ==============================================================================
# autoscaling.tf — Auto Scaling para ECS Fargate
# ==============================================================================
# Ajusta automáticamente el número de tasks según la carga real.
#
# Flujo:
#   CPU/Memoria sube → CloudWatch detecta → Auto Scaling lanza más tasks
#   CPU/Memoria baja → CloudWatch detecta → Auto Scaling reduce tasks
#
# Esto es transparente para el usuario y no requiere cambios en el código.
#
# Recursos:
#   1. Scalable Target  → registra el ECS Service como recurso escalable
#   2. Policy CPU       → escala según CPU promedio (target: 70%)
#   3. Policy Memoria   → escala según Memoria promedio (target: 75%)
# ==============================================================================


# ==============================================================================
# 1. SCALABLE TARGET
# ==============================================================================
# Le dice a Application Auto Scaling qué recurso va a controlar:
# el número de tasks (DesiredCount) del ECS Service.

resource "aws_appautoscaling_target" "ecs" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.backend.name}"
  scalable_dimension = "ecs:service:DesiredCount"

  min_capacity = var.autoscaling_min_capacity  # Mínimo de tasks siempre corriendo
  max_capacity = var.autoscaling_max_capacity  # Máximo de tasks permitidos
}


# ==============================================================================
# 2. POLÍTICA DE ESCALADO — CPU (Target Tracking)
# ==============================================================================
# Target Tracking es el tipo más inteligente de Auto Scaling:
# en lugar de definir "si CPU > 70% agrega 1 task", defines un objetivo
# y AWS calcula automáticamente cuántos tasks agregar o quitar para mantenerlo.
#
# Analogía: es como el control de crucero de un auto — tú dices "mantén 70 km/h"
# y el auto acelera o frena solo para mantener esa velocidad.

resource "aws_appautoscaling_policy" "ecs_cpu" {
  name               = "${var.project_name}-autoscaling-cpu"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    target_value = var.autoscaling_cpu_target  # % de CPU objetivo (70%)

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    # Tiempo de espera después de un scale-OUT antes de evaluar otro scale-OUT
    # Evita que el sistema escale demasiado rápido ante picos momentáneos
    scale_out_cooldown = 120  # 2 minutos

    # Tiempo de espera después de un scale-IN antes de evaluar otro scale-IN
    # Más conservador: espera más para bajar y evitar oscilaciones
    scale_in_cooldown = 300  # 5 minutos
  }
}


# ==============================================================================
# 3. POLÍTICA DE ESCALADO — Memoria (Target Tracking)
# ==============================================================================
# Complementa la política de CPU. Si la app consume mucha memoria
# (ej. procesando archivos grandes o memory leak), también escala.
# El que se dispare primero (CPU o Memoria) activa el escalado.

resource "aws_appautoscaling_policy" "ecs_memory" {
  name               = "${var.project_name}-autoscaling-memory"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    target_value = var.autoscaling_memory_target  # % de Memoria objetivo (75%)

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }

    scale_out_cooldown = 120
    scale_in_cooldown  = 300
  }
}
