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
# Variables de Secrets Manager
# ------------------------------------------------------------------------------

variable "db_secret_arn" {
  description = "ARN del secreto en Secrets Manager que contiene el connection string de PostgreSQL. Si aún no lo tienes, lo crearemos en la Etapa 3 (RDS)."
  type        = string
  default     = ""  # Vacío por ahora, lo rellenaremos cuando agreguemos RDS
}

variable "jwt_secret_arn" {
  description = "ARN del secreto en Secrets Manager que contiene la JWT Key."
  type        = string
  default     = ""  # Vacío por ahora
}
