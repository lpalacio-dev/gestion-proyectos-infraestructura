# ==============================================================================
# frontend.tf — S3 + CloudFront para Angular SPA
# ==============================================================================
# Arquitectura (actualizada con proxy al API):
#
#   Navegador → HTTPS → CloudFront → /api/*  → HTTP → ALB → ECS (.NET)
#                                  → /*      → S3 (Angular build)
#
# Esto resuelve el Mixed Content: el navegador solo ve HTTPS hacia CloudFront.
# CloudFront habla con el ALB por HTTP internamente — transparente para el usuario.
#
# Recursos:
#   1. S3 Bucket                       → almacena el build de Angular
#   2. S3 Bucket Policy                → solo CloudFront puede leer el bucket
#   3. CloudFront Origin Access Control → identidad para autenticarse con S3
#   4. CloudFront Distribution         → CDN con dos origins: S3 y ALB
# ==============================================================================


# ==============================================================================
# 1. S3 BUCKET
# ==============================================================================

resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project_name}-frontend-${var.aws_account_id}"
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  versioning_configuration {
    status = "Disabled"
  }
}


# ==============================================================================
# 2. CLOUDFRONT ORIGIN ACCESS CONTROL (OAC)
# ==============================================================================

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project_name}-oac"
  description                       = "OAC para S3 frontend de ${var.project_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}


# ==============================================================================
# 3. S3 BUCKET POLICY — Solo esta distribución CloudFront puede leer el bucket
# ==============================================================================

resource "aws_s3_bucket_policy" "frontend" {
  bucket     = aws_s3_bucket.frontend.id
  depends_on = [aws_s3_bucket_public_access_block.frontend]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.frontend.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
          }
        }
      }
    ]
  })
}


# ==============================================================================
# 4. CLOUDFRONT DISTRIBUTION — Dos origins: S3 y ALB
# ==============================================================================

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  comment             = "Frontend Angular + proxy API de ${var.project_name}"

  # --------------------------------------------------------------------------
  # Origin 1: S3 — sirve el build de Angular
  # --------------------------------------------------------------------------
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.frontend.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # --------------------------------------------------------------------------
  # Origin 2: ALB — proxy hacia tu API .NET
  # CloudFront habla con el ALB por HTTP internamente.
  # El navegador nunca ve esta conexión HTTP — solo ve HTTPS hacia CloudFront.
  # --------------------------------------------------------------------------
  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "ALB-${var.project_name}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"  # ALB solo tiene HTTP por ahora
      origin_ssl_protocols   = ["TLSv1.2"]  # Requerido aunque usemos http-only
    }
  }

  # --------------------------------------------------------------------------
  # Behavior para /api/* → ALB (se evalúa ANTES que el default)
  # --------------------------------------------------------------------------
  # SIN caché — las respuestas de tu API son dinámicas.
  # Pasa Authorization, Content-Type y headers de CORS al backend.
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "ALB-${var.project_name}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = true  # Pasar ?page=1, ?filter=x, etc. al API
      headers = [
        "Authorization",                  # JWT token
        "Content-Type",                   # application/json
        "Accept",
        "Origin",                         # Para CORS
        "Access-Control-Request-Headers",
        "Access-Control-Request-Method"
      ]
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 0  # Sin caché para el API
    max_ttl     = 0
  }

  # --------------------------------------------------------------------------
  # Behavior por defecto /* → S3 (Angular build)
  # --------------------------------------------------------------------------
  default_cache_behavior {
    target_origin_id       = "S3-${aws_s3_bucket.frontend.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 86400     # 1 día
    max_ttl     = 31536000  # 1 año para assets con hash de Angular
  }

  # --------------------------------------------------------------------------
  # Manejo de errores para Angular Router (SPA)
  # --------------------------------------------------------------------------
  # /proyectos/123 no existe en S3 → S3 devuelve 403 → CloudFront sirve index.html
  # Angular recibe la página y su router resuelve la ruta localmente.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Certificado SSL gratuito de CloudFront para *.cloudfront.net
  # Cuando agregues dominio propio → reemplazar por certificado ACM
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
