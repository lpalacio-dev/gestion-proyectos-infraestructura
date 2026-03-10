# ==============================================================================
# ecs.tf — ECS Cluster + IAM Roles + Task Definition + Service
# ==============================================================================
# Este archivo crea TODO lo necesario para correr tu API en Fargate:
#
#   1. ECS Cluster      → el "datacenter virtual" que agrupa tus servicios
#   2. IAM Roles        → permisos que necesita ECS para operar
#   3. Security Group   → firewall del contenedor
#   4. CloudWatch Logs  → para ver los logs de tu API
#   5. Task Definition  → el "molde" de tu contenedor (imagen, CPU, RAM, env vars)
#   6. ECS Service      → mantiene corriendo N copias de tu task
# ==============================================================================


# ==============================================================================
# 1. ECS CLUSTER
# ==============================================================================

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  # Container Insights: métricas avanzadas en CloudWatch (CPU, memoria por task)
  # Tiene un pequeño costo adicional, pero es muy útil para debugging
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# Registrar los capacity providers (FARGATE y FARGATE_SPOT)
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # Por defecto usa FARGATE normal (más estable)
  # FARGATE_SPOT es hasta 70% más barato pero AWS puede interrumpirlo
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}


# ==============================================================================
# 2. IAM ROLES
# ==============================================================================

# --- Rol de Ejecución (Task Execution Role) ---
# Este rol lo usa ECS para:
#   - Descargar la imagen de ECR
#   - Leer secrets de Secrets Manager
#   - Escribir logs en CloudWatch

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-ecs-execution-role"

  # "Trust policy": dice quién puede asumir este rol
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Permiso base de ECS (ECR + CloudWatch Logs)
resource "aws_iam_role_policy_attachment" "ecs_execution_base" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Permiso adicional para leer Secrets Manager
# (necesario para las variables ConnectionString y JWT Key)
resource "aws_iam_role_policy" "ecs_secrets" {
  name = "${var.project_name}-ecs-secrets-policy"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = [
        "secretsmanager:GetSecretValue",
        "ssm:GetParameters",
        "kms:Decrypt"
      ]
      Resource = "*"  # En producción avanzada limitarías a los ARNs específicos
    }]
  })
}

# --- Rol de Tarea (Task Role) ---
# Este rol lo usa TU APLICACIÓN en tiempo de ejecución para llamar a otros
# servicios de AWS (S3, SNS, SQS, etc.)

resource "aws_iam_role" "ecs_task" {
  name = "${var.project_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Permisos de S3 (para subida de archivos/avatares)
resource "aws_iam_role_policy" "ecs_task_s3" {
  name = "${var.project_name}-ecs-task-s3-policy"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ]
      Resource = "*"  # Cuando crees el bucket S3 lo limitaremos al ARN exacto
    }]
  })
}

# Permisos de SNS (para notificaciones)
resource "aws_iam_role_policy" "ecs_task_sns" {
  name = "${var.project_name}-ecs-task-sns-policy"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = "*"
    }]
  })
}


# ==============================================================================
# 3. SECURITY GROUP DEL CONTENEDOR
# ==============================================================================
# ETAPA 2: Ahora el ECS Task SOLO acepta tráfico desde el ALB.
# Nadie en internet puede llegar directamente al contenedor.
# El flujo es: Internet → ALB SG → ALB → ECS SG → Task
#
# Usamos source_security_group_id en lugar de cidr_blocks — esto le dice
# a AWS "solo permite tráfico que venga del SG del ALB", sin importar IPs.

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-ecs-tasks-sg"
  description = "Trafico para tasks ECS ALB"
  vpc_id      = var.vpc_id

  # Solo acepta tráfico en el puerto de la app Y solo si viene del ALB
  ingress {
    description     = "HTTP desde el ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]  # ← referencia al SG del ALB
  }

  # Salida libre: necesario para conectarse a RDS, ECR, Secrets Manager, SNS, etc.
  egress {
    description = "Salida sin restricciones"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# ==============================================================================
# 4. CLOUDWATCH LOG GROUP
# ==============================================================================
# Donde aparecerán los logs de tu API .NET (Console.WriteLine, errores, etc.)

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 30  # Guarda logs por 30 días (gratis hasta 5GB/mes)
}


# ==============================================================================
# 5. TASK DEFINITION
# ==============================================================================
# Es el "blueprint" de tu contenedor. Define:
#   - Qué imagen Docker usar
#   - Cuánta CPU y RAM asignar
#   - Variables de entorno
#   - Secrets (connection string, JWT key)
#   - Configuración de logs

resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.project_name}-task"
  network_mode             = "awsvpc"     # Requerido para Fargate
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "${var.project_name}-container"
      image     = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.project_name}-backend:latest"
      essential = true  # Si este contenedor muere, toda la task se reinicia

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      # Variables de entorno NO sensibles
      environment = [
        {
          name  = "ASPNETCORE_ENVIRONMENT"
          value = "Production"
        },
        {
          name  = "ASPNETCORE_URLS"
          value = "http://+:${var.container_port}"
        }
      ]

      # Secrets — se inyectan de Secrets Manager en tiempo de ejecución
      # La app los recibe como variables de entorno normales
      # NOTA: Cuando db_secret_arn y jwt_secret_arn estén vacíos (Etapa 1),
      # ECS simplemente no inyectará esos secrets. Los agregaremos en Etapa 3.
      secrets = [
        for secret in [
          {
            name      = "ConnectionStrings__PostgreSQLConnection"
            valueFrom = var.db_secret_arn
          },
          {
            name      = "Jwt__Key"
            valueFrom = var.jwt_secret_arn
          }
        ] : secret if secret.valueFrom != ""
      ]

      # Configuración de logs → CloudWatch
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "backend"
        }
      }

      # Health check — ECS verifica que tu app responde
      # Asegúrate de tener el endpoint /health en tu API .NET
      # healthCheck = {
      #   command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/health || exit 1"]
      #   interval    = 30
      #   timeout     = 5
      #   retries     = 3
      #   startPeriod = 60  # Da 60s al arranque antes de empezar a verificar
      # }
    }
  ])
}


# ==============================================================================
# 6. ECS SERVICE
# ==============================================================================
# ETAPA 2: El Service ahora está conectado al ALB a través del Target Group.
# El ALB registra/desregistra tasks automáticamente al escalar o hacer deploy.

resource "aws_ecs_service" "backend" {
  name            = "${var.project_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Configuración de red para cada task
  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true  # Necesario para que el task pueda salir a internet (ECR, RDS, etc.)
  }

  # Integración con el ALB
  # Cada task que levante ECS se registrará automáticamente en el Target Group
  # y el ALB empezará a enviarle tráfico cuando pase el health check
  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "${var.project_name}-container"
    container_port   = var.container_port
  }

  # Deployment sin downtime: levanta el task nuevo antes de bajar el viejo.
  # Con el ALB esto es seamless — el viejo sigue recibiendo tráfico hasta
  # que el nuevo pase el health check y esté listo.
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  # El Service debe esperar que el ALB exista antes de crearse
  depends_on = [aws_lb_listener.http]

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}
