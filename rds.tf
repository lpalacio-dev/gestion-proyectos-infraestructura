# ==============================================================================
# rds.tf — PostgreSQL 17 en RDS (Free Tier)
# ==============================================================================
# Recursos que crea este archivo:
#
#   1. DB Subnet Group   → le dice a RDS en qué subnets puede vivir
#   2. Security Group    → solo acepta conexiones desde los tasks de ECS
#   3. RDS Instance      → PostgreSQL 17, db.t3.micro, Free Tier
#
# Arquitectura de red:
#   Internet → ALB → ECS Task → RDS (puerto 5432)
#                               ↑
#                     nadie más llega aquí
# ==============================================================================


# ==============================================================================
# 1. DB SUBNET GROUP
# ==============================================================================
# Agrupa las subnets donde RDS puede crear la instancia.
# RDS requiere al menos 2 subnets en distintas AZs aunque solo
# uses una instancia (es un requisito de AWS para alta disponibilidad futura).

resource "aws_db_subnet_group" "main" {
  name        = "${var.project_name}-db-subnet-group"
  subnet_ids  = var.subnet_ids
  description = "Subnet group para RDS PostgreSQL de ${var.project_name}"
}


# ==============================================================================
# 2. SECURITY GROUP DEL RDS
# ==============================================================================
# Solo permite conexiones en el puerto 5432 (PostgreSQL) y ÚNICAMENTE
# si vienen del Security Group de los tasks ECS.
# Ninguna IP de internet puede alcanzar la base de datos directamente.

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Acceso a RDS solo desde ECS tasks"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL desde ECS tasks unicamente"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]  # ← referencia al SG de ECS
  }

  # RDS necesita salida para actualizaciones de sistema y backups a S3
  egress {
    description = "Salida sin restricciones"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# ==============================================================================
# 3. RDS INSTANCE — PostgreSQL 17
# ==============================================================================

resource "aws_db_instance" "postgres" {
  identifier = "${var.project_name}-db"

  # --- Motor ---
  engine               = "postgres"
  engine_version       = "17.4"          # PostgreSQL 17, última versión disponible
  instance_class       = var.db_instance_class  # db.t3.micro = Free Tier

  # --- Almacenamiento ---
  allocated_storage     = 20       # GB — mínimo y máximo en Free Tier
  max_allocated_storage = 20       # Sin autoscaling de storage (Free Tier)
  storage_type          = "gp2"    # General Purpose SSD — incluido en Free Tier
  storage_encrypted     = true     # Cifrado en reposo (buena práctica, sin costo extra)

  # --- Base de datos inicial ---
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password  # Viene de variables, se guarda en Secrets Manager abajo

  # --- Red ---
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false   # ← NO exponer a internet, solo acceso desde ECS

  # --- Backups ---
  backup_retention_period = 1      # Free Tier permite máximo 1 día de retención
  backup_window           = "03:00-04:00"   # UTC — hora de menor tráfico
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # --- Disponibilidad ---
  multi_az              = false    # Free Tier no incluye Multi-AZ
  deletion_protection   = false    # Ponlo en true cuando vayas a producción real

  # --- Snapshots ---
  # Al hacer terraform destroy, toma un snapshot final antes de borrar
  # Cámbialo a true en producción para no perder datos
  skip_final_snapshot       = true
  # final_snapshot_identifier = "${var.project_name}-db-final-snapshot"

  # --- Performance Insights ---
  performance_insights_enabled = false  # Free Tier no lo incluye

  # --- Parámetros ---
  # Sin parameter group personalizado por ahora — usamos el default de postgres17
  # En el futuro podemos crear uno para tunear conexiones, logs, etc.
}
