# ==============================================================================
# monitoring.tf — CloudWatch Alarms
# ==============================================================================
# Alertas automáticas que te avisan cuando algo va mal en tu infraestructura.
# Por ahora solo registran el estado en CloudWatch (ALARM / OK).
#
# En el futuro, cuando agregues SNS, estas mismas alarms pueden enviarte
# un email o disparar una Lambda — sin modificar este archivo.
#
# Alarms que crea este archivo:
#   ECS:
#     1. CPU alta       → ECS task usando demasiada CPU
#     2. Memoria alta   → ECS task cerca del límite de RAM
#   ALB:
#     3. Errores 5xx    → tu API está devolviendo errores internos
#     4. Errores 4xx    → muchas requests inválidas (posible ataque o bug)
#     5. Latencia alta  → tu API responde lento
#     6. Targets sanos  → ningún task está pasando el health check
# ==============================================================================

locals {
  # Prefijo reutilizable para nombres de alarms
  alarm_prefix = "${var.project_name}-${var.environment}"
}


# ==============================================================================
# ALARMS DE ECS
# ==============================================================================

# --- 1. CPU Alta ---
# Se dispara si la CPU promedio supera el 80% por 2 períodos consecutivos de 5 min.
# Señal de que necesitas más tasks (Auto Scaling — Etapa 5) o más CPU en la task.

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${local.alarm_prefix}-ecs-cpu-high"
  alarm_description   = "ECS CPU supera el 80% — considera escalar o revisar la app"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2          # Debe superar el umbral 2 veces seguidas (evita falsos positivos)
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300        # Evalúa cada 5 minutos
  statistic           = "Average"
  threshold           = 80         # % de CPU
  treat_missing_data  = "notBreaching" # Si no hay datos, no considera que está en alarma

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.backend.name
  }

  # alarm_actions = [aws_sns_topic.alerts.arn]  ← se activa cuando agregues SNS
  # ok_actions    = [aws_sns_topic.alerts.arn]  ← notifica también cuando se recupera
}

# --- 2. Memoria Alta ---
# Se dispara si la memoria promedio supera el 80% por 2 períodos de 5 min.
# Con 1024 MB de RAM, el 80% son ~820 MB — señal de memory leak o falta de RAM.

resource "aws_cloudwatch_metric_alarm" "ecs_memory_high" {
  alarm_name          = "${local.alarm_prefix}-ecs-memory-high"
  alarm_description   = "ECS Memoria supera el 80% — revisa posible memory leak"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80         # % de memoria
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.backend.name
  }

  # alarm_actions = [aws_sns_topic.alerts.arn]
}


# ==============================================================================
# ALARMS DEL ALB
# ==============================================================================

# --- 3. Errores 5xx (errores del servidor) ---
# HTTPCode_Target_5XX_Count: errores que genera TU app (.NET devuelve 500, 503, etc.)
# HTTPCode_ELB_5XX_Count:    errores del ALB mismo (no llega al task, timeout, etc.)
# Umbral: más de 10 errores en 5 minutos = algo está mal.

resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
  alarm_name          = "${local.alarm_prefix}-alb-5xx-errors"
  alarm_description   = "Más de 10 errores 5xx en 5 min — tu API está fallando"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"  # Sin tráfico = sin errores, no es alarma

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  # alarm_actions = [aws_sns_topic.alerts.arn]
}

# --- 4. Errores 4xx (errores del cliente) ---
# Un pico de 4xx puede indicar: bug en el frontend, scraping, o intento de ataque.
# Umbral más alto (100) porque los 4xx son más comunes y menos críticos que los 5xx.

resource "aws_cloudwatch_metric_alarm" "alb_4xx_errors" {
  alarm_name          = "${local.alarm_prefix}-alb-4xx-errors"
  alarm_description   = "Más de 100 errores 4xx en 5 min — posible bug en frontend o ataque"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_4XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 100
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  # alarm_actions = [aws_sns_topic.alerts.arn]
}

# --- 5. Latencia Alta ---
# TargetResponseTime: tiempo que tarda tu API en responder (en segundos).
# Si supera 2 segundos en promedio, algo está lento (query pesada, cold start, etc.)

resource "aws_cloudwatch_metric_alarm" "alb_latency_high" {
  alarm_name          = "${local.alarm_prefix}-alb-latency-high"
  alarm_description   = "Latencia promedio supera 2 segundos — la API responde lento"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Average"
  threshold           = 2          # segundos
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  # alarm_actions = [aws_sns_topic.alerts.arn]
}

# --- 6. Sin Targets Sanos ---
# HealthyHostCount = 0 significa que NINGÚN task de ECS está pasando el health check.
# Es la alarm más crítica — tu API está completamente caída.

resource "aws_cloudwatch_metric_alarm" "alb_no_healthy_targets" {
  alarm_name          = "${local.alarm_prefix}-alb-no-healthy-targets"
  alarm_description   = "CRÍTICO: No hay tasks sanos — la API está caída"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60         # Evalúa cada minuto (es crítico, queremos saber rápido)
  statistic           = "Minimum"
  threshold           = 0
  treat_missing_data  = "breaching" # Sin datos = asume que está caído

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.backend.arn_suffix
  }

  # alarm_actions = [aws_sns_topic.alerts.arn]
}
