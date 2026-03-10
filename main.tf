# ==============================================================================
# main.tf — Configuración del Provider AWS
# ==============================================================================
# Este archivo le dice a Terraform:
#   1. Qué "proveedor" usar (AWS en este caso)
#   2. En qué región trabajar
#   3. Dónde guardar el "estado" de tu infraestructura
#
# El ESTADO es un archivo (.tfstate) donde Terraform recuerda qué recursos
# ya creó. Por ahora lo guardamos local, en el futuro lo moveremos a S3.
# ==============================================================================

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"  # Usamos AWS Provider v6
    }
  }

  # ESTADO LOCAL — simple para empezar
  # Cuando trabajemos en equipo o en CI/CD, lo moveremos a un S3 bucket
  # backend "s3" { ... }  ← esto vendrá después
}

provider "aws" {
  profile = "luis-admin"
  region = var.aws_region

  # Etiquetas que se aplicarán a TODOS los recursos automáticamente
  # Muy útil para filtrar en la consola de AWS y controlar costos
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
