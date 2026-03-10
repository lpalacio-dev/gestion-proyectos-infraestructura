# ==============================================================================
# alb.tf — Application Load Balancer
# ==============================================================================
# El ALB es el punto de entrada único a tu backend. Ventajas vs IP directa:
#
#   ✅ URL estable (no cambia en cada deploy)
#   ✅ Health checks automáticos (si un task falla, deja de enviarle tráfico)
#   ✅ Rolling deployments sin downtime
#   ✅ Soporte para múltiples tasks (balanceo de carga)
#   ✅ Base para agregar HTTPS en el futuro (solo agregar listener)
#
# Recursos que crea este archivo:
#   1. Security Group del ALB   → permite tráfico HTTP desde internet
#   2. Application Load Balancer
#   3. Target Group             → apunta a los tasks de ECS en puerto 8080
#   4. Listener HTTP :80        → recibe tráfico y lo manda al Target Group
# ==============================================================================


# ==============================================================================
# 1. SECURITY GROUP DEL ALB
# ==============================================================================
# El ALB tiene su propio Security Group separado del ECS.
# Esto es importante: en el SG del ECS vamos a permitir tráfico
# SOLO desde este SG del ALB — nadie más puede hablar directamente
# con los contenedores.

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Trafico publico hacia el ALB"
  vpc_id      = var.vpc_id

  # Permitir HTTP desde cualquier IP de internet
  ingress {
    description = "HTTP publico"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Permitir todo el tráfico saliente del ALB hacia los targets (ECS tasks)
  egress {
    description = "Salida sin restricciones"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# ==============================================================================
# 2. APPLICATION LOAD BALANCER
# ==============================================================================

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false        # false = público (accesible desde internet)
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.subnet_ids  # El ALB necesita estar en al menos 2 subnets

  # Protección contra borrado accidental con "terraform destroy"
  # Ponlo en false cuando quieras destruir la infra intencionalmente
  enable_deletion_protection = false

  # Logs de acceso (opcional, tiene costo de S3)
  # Deshabilitado por ahora — lo activaremos si necesitas auditoría
  # access_logs {
  #   bucket  = "tu-bucket-logs"
  #   prefix  = "alb"
  #   enabled = true
  # }
}


# ==============================================================================
# 3. TARGET GROUP
# ==============================================================================
# El Target Group define CÓMO el ALB se comunica con tus ECS tasks:
#   - En qué puerto escucha tu app (8080)
#   - Cómo verificar que un task está sano (health check)
#
# ECS registra/desregistra tasks automáticamente en este grupo
# cada vez que hace un deploy o un task falla.

resource "aws_lb_target_group" "backend" {
  name        = "${var.project_name}-tg"
  port        = var.container_port  # Puerto de tu API .NET (8080)
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"  # Requerido para Fargate (usa IPs de los tasks, no instancias)

  health_check {
    enabled             = true
    path                = "/healthz"   # Endpoint de health check de tu API .NET
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2   # 2 checks exitosos = task sano
    unhealthy_threshold = 3   # 3 checks fallidos = task removido del balanceo
    timeout             = 5   # Segundos para considerar timeout
    interval            = 30  # Segundos entre cada check
    matcher             = "200" # Código HTTP esperado en /health
  }

  # Tiempo que el ALB espera para que las conexiones activas terminen
  # antes de remover un task que está siendo reemplazado
  deregistration_delay = 30

  lifecycle {
    create_before_destroy = true
  }
}


# ==============================================================================
# 4. LISTENER HTTP — Puerto 80
# ==============================================================================
# El Listener "escucha" en un puerto del ALB y decide qué hacer con
# el tráfico que llega. En este caso: reenviar todo al Target Group.
#
# FUTURO — Cuando agregues HTTPS (Etapa SSL), añadirás:
#   - Un listener en puerto 443 con tu certificado ACM
#   - Este listener :80 lo cambiarás a "redirect" hacia 443

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}
