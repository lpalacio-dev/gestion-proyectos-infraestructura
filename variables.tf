# ==============================================================================
# variables.tf — Definición de Variables
# ==============================================================================
# Aquí DEFINES las variables (su nombre, tipo y descripción).
# Los VALORES concretos van en terraform.tfvars (siguiente archivo).
#
# Ventaja: el mismo código sirve para distintos entornos (dev, prod)
# solo cambiando el .tfvars
# ==============================================================================

# ------------------------------------------------------------------------------
# Variables Generales
# ------------------------------------------------------------------------------

variable "aws_region" {
  description = "Región de AWS donde se desplegará la infraestructura"
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Nombre del proyecto — se usa como prefijo en todos los recursos"
  type        = string
  default     = "gestion-proyectos-terraform"
}

variable "environment" {
  description = "Entorno de despliegue"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "El entorno debe ser: development, staging o production."
  }
}

# ------------------------------------------------------------------------------
# Variables de AWS Account
# ------------------------------------------------------------------------------

variable "aws_account_id" {
  description = "Tu AWS Account ID (12 dígitos). Lo encuentras en la consola → arriba derecha → tu nombre → Account ID"
  type        = string

  validation {
    condition     = length(var.aws_account_id) == 12
    error_message = "El AWS Account ID debe tener exactamente 12 dígitos."
  }
}

# ------------------------------------------------------------------------------
# Variables de Red (VPC)
# ------------------------------------------------------------------------------

variable "vpc_id" {
  description = "ID de la VPC donde vivirá la infraestructura. Para la VPC default usa el comando: aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text"
  type        = string
}

variable "subnet_ids" {
  description = "Lista de Subnet IDs públicas. ECS necesita al menos 2 subnets en distintas AZs. Comando: aws ec2 describe-subnets --filters Name=vpc-id,Values=TU_VPC_ID --query 'Subnets[*].SubnetId' --output text"
  type        = list(string)
}

# ------------------------------------------------------------------------------
# Variables de ECS / Contenedor
# ------------------------------------------------------------------------------

variable "container_port" {
  description = "Puerto en el que escucha tu API .NET dentro del contenedor"
  type        = number
  default     = 8080
}

variable "task_cpu" {
  description = "CPU para la task de Fargate en unidades (256=0.25vCPU, 512=0.5vCPU, 1024=1vCPU)"
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Memoria RAM para la task en MB"
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Número de instancias (tasks) que quieres corriendo"
  type        = number
  default     = 1
}

# ------------------------------------------------------------------------------
# Variables de Auto Scaling
# ------------------------------------------------------------------------------

variable "autoscaling_min_capacity" {
  description = "Número mínimo de tasks ECS siempre corriendo. Con 1 siempre hay disponibilidad."
  type        = number
  default     = 1
}

variable "autoscaling_max_capacity" {
  description = "Número máximo de tasks ECS. Controla el costo máximo posible."
  type        = number
  default     = 4
}

variable "autoscaling_cpu_target" {
  description = "% de CPU objetivo. Auto Scaling mantiene este valor agregando o quitando tasks."
  type        = number
  default     = 70
}

variable "autoscaling_memory_target" {
  description = "% de Memoria objetivo. Complementa el escalado por CPU."
  type        = number
  default     = 75
}

# ------------------------------------------------------------------------------
# Variables de RDS
# ------------------------------------------------------------------------------

variable "db_instance_class" {
  description = "Tipo de instancia RDS. db.t3.micro es Free Tier."
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Nombre de la base de datos PostgreSQL que se creará automáticamente"
  type        = string
  default     = "gestion_proyectos"
}

variable "db_username" {
  description = "Usuario administrador de la base de datos"
  type        = string
  default     = "dbadmin"
}

variable "db_password" {
  description = "Contraseña del usuario administrador. Mínimo 8 caracteres, sin @, /, o espacios."
  type        = string
  sensitive   = true  # Terraform no la mostrará en los logs ni en el plan
}

# ------------------------------------------------------------------------------
# Variables de Secrets Manager
# ------------------------------------------------------------------------------

variable "db_secret_arn" {
  description = "ARN del connection string — se rellena automáticamente desde outputs después de aplicar secrets.tf"
  type        = string
  default     = ""
}

variable "jwt_secret_arn" {
  description = "ARN del JWT Key secret — se rellena automáticamente desde outputs después de aplicar secrets.tf"
  type        = string
  default     = ""
}

variable "jwt_secret_value" {
  description = "Valor de la clave JWT. Mínimo 32 caracteres, usa una cadena aleatoria segura."
  type        = string
  sensitive   = true  # No aparece en logs ni en terraform plan
}
