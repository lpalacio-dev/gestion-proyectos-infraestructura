# ==============================================================================
# ecr.tf — Elastic Container Registry
# ==============================================================================
# ECR es el "Docker Hub privado" de AWS. Aquí guardas las imágenes Docker
# de tu API .NET antes de que ECS las ejecute.
#
# Flujo: GitHub Actions buildea imagen → la sube a ECR → ECS la descarga
# ==============================================================================

resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-backend"
  image_tag_mutability = "MUTABLE"  # Permite sobreescribir el tag "latest"

  # Escaneo automático de vulnerabilidades al hacer push
  image_scanning_configuration {
    scan_on_push = true
  }

  # Si haces terraform destroy, esto PROTEGE tus imágenes de ser borradas
  # accidentalmente. Ponlo en false solo si quieres limpiar todo.
  force_delete = false
}

# ------------------------------------------------------------------------------
# Lifecycle Policy — Limpieza automática de imágenes viejas
# ------------------------------------------------------------------------------
# Sin esto, cada deploy acumula imágenes en ECR y los costos crecen.
# Esta política mantiene solo las últimas 2 imágenes "untagged"
# (las intermedias que ya no tienen el tag "latest").
# ------------------------------------------------------------------------------

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Mantener solo las últimas 2 imágenes sin tag"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = 2
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
