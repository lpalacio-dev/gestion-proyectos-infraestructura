# ==============================================================================
# secrets.tf — AWS Secrets Manager
# ==============================================================================
# Guarda las credenciales sensibles de forma segura.
# Los tasks de ECS los leen en tiempo de ejecución como variables de entorno,
# nunca están hardcodeados en el código ni en la Task Definition.
#
# Flujo:
#   Terraform crea el secret → ECS Task lo lee al arrancar →
#   tu app .NET lo recibe como variable de entorno normal
#
# Recursos:
#   1. Secret: Connection String de PostgreSQL
#   2. Secret: JWT Key
# ==============================================================================


# ==============================================================================
# 1. SECRET — CONNECTION STRING POSTGRESQL
# ==============================================================================

resource "aws_secretsmanager_secret" "db_connection" {
  name        = "${var.project_name}/db-connection-string"
  description = "Connection string de PostgreSQL para ${var.project_name}"

  # Tiempo de espera antes de borrar definitivamente el secret
  # (por si haces terraform destroy por error — tienes 7 días para recuperarlo)
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_connection" {
  secret_id = aws_secretsmanager_secret.db_connection.id

  # Formato de connection string que espera tu app .NET (Entity Framework / Npgsql)
  # Terraform lo construye automáticamente con el endpoint del RDS que acaba de crear
  secret_string = "Host=${aws_db_instance.postgres.address};Port=5432;Database=${var.db_name};Username=${var.db_username};Password=${var.db_password};SSL Mode=Require;Trust Server Certificate=true"
}


# ==============================================================================
# 2. SECRET — JWT KEY
# ==============================================================================

resource "aws_secretsmanager_secret" "jwt_key" {
  name        = "${var.project_name}/jwt-key"
  description = "Clave secreta JWT para firma de tokens de ${var.project_name}"

  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "jwt_key" {
  secret_id     = aws_secretsmanager_secret.jwt_key.id
  secret_string = var.jwt_secret_value
}
