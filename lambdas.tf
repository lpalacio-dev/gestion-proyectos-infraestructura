# ==============================================================================
# lambdas.tf — S3 Media + SNS + SQS + Lambdas
# ==============================================================================
# Este archivo crea toda la infraestructura event-driven del proyecto:
#
#   S3 (profile-images/) → ImageProcessorLambda (genera thumbnail + optimized)
#
#   ECS (.NET) → SNS topic → SQS task-email-queue → TaskNotifierLambda → SES
#                                └── DLQ (mensajes que fallaron 3 veces)
#
# Sobre el código .zip de las Lambdas:
#   Terraform crea la función con un zip placeholder la primera vez.
#   El código real lo subes tú con:
#     aws lambda update-function-code \
#       --function-name <nombre> \
#       --zip-file fileb://publish.zip
#   O con GitHub Actions en cada push al repo de las Lambdas.
#
# Recursos:
#   1.  S3 Bucket de media (imágenes de perfil)
#   2.  IAM Role — ImageProcessorLambda
#   3.  Lambda — ImageProcessorLambda
#   4.  S3 Trigger → ImageProcessorLambda
#   5.  SNS Topic — task-events-topic
#   6.  SQS DLQ — task-email-dlq
#   7.  SQS Queue — task-email-queue (suscrita a SNS)
#   8.  SNS → SQS Subscription
#   9.  IAM Role — TaskNotifierLambda
#   10. Lambda — TaskNotifierLambda
#   11. SQS Trigger → TaskNotifierLambda
# ==============================================================================


# ==============================================================================
# 1. S3 BUCKET DE MEDIA — Imágenes de perfil
# ==============================================================================
# Bucket separado del frontend. Solo almacena uploads de usuarios.
# El ECS Task sube aquí → S3 dispara evento → ImageProcessorLambda procesa.

resource "aws_s3_bucket" "media" {
  bucket = "${var.project_name}-media-${var.aws_account_id}"
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket = aws_s3_bucket.media.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CORS — necesario para que el frontend pueda hacer PUT/GET directamente a S3
# (upload de imagen de perfil desde el navegador)
resource "aws_s3_bucket_cors_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "DELETE", "HEAD"]
    allowed_origins = ["*"]   # En producción real: ["https://tudominio.com"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}


# ==============================================================================
# 2. IAM ROLE — ImageProcessorLambda
# ==============================================================================

resource "aws_iam_role" "image_processor_lambda" {
  name = "${var.project_name}-image-processor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Logs en CloudWatch (básico para toda Lambda)
resource "aws_iam_role_policy_attachment" "image_processor_basic" {
  role       = aws_iam_role.image_processor_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Permisos S3: leer la imagen original y escribir thumbnail + optimized
resource "aws_iam_role_policy" "image_processor_s3" {
  name = "${var.project_name}-image-processor-s3-policy"
  role = aws_iam_role.image_processor_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",    # Leer imagen original subida
        "s3:PutObject",    # Escribir thumbnail y versión optimizada
        "s3:DeleteObject"
      ]
      Resource = "${aws_s3_bucket.media.arn}/*"
    }]
  })
}


# ==============================================================================
# 3. LAMBDA — ImageProcessorLambda
# ==============================================================================
# Handler: el punto de entrada de tu función .NET
# Runtime: dotnet8 — igual que tu backend
#
# El zip placeholder es un archivo mínimo válido para que Terraform
# pueda crear la función. Lo reemplazas con tu código real después.

resource "aws_lambda_function" "image_processor" {
  function_name = "${var.project_name}-image-processor"
  role          = aws_iam_role.image_processor_lambda.arn
  runtime       = "dotnet8"
  handler       = "ImageProcessorLambda::ImageProcessorLambda.Function::FunctionHandler"
  timeout       = 30    # segundos — procesamiento de imagen puede tardar
  memory_size   = 512   # MB — necesita más RAM para manipular imágenes

  # Zip placeholder — Terraform crea la función con este zip vacío.
  # Luego subes el código real con:
  #   aws lambda update-function-code \
  #     --function-name gestion-proyectos-image-processor \
  #     --zip-file fileb://ImageProcessorLambda/publish.zip \
  #     --region us-east-2
  filename         = "${path.module}/placeholder.zip"
  source_code_hash = filebase64sha256("${path.module}/placeholder.zip")

  environment {
    variables = {
      BUCKET_NAME       = aws_s3_bucket.media.bucket
      THUMBNAIL_PREFIX  = "profile-images/thumbnails/"   # Carpeta para 150x150
      OPTIMIZED_PREFIX  = "profile-images/optimized/"    # Carpeta para 500x500
      ASPNETCORE_ENVIRONMENT = "Production"
    }
  }

  # Ignorar cambios en el código — GitHub Actions lo actualiza independientemente
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

# CloudWatch Log Group para ImageProcessorLambda
resource "aws_cloudwatch_log_group" "image_processor" {
  name              = "/aws/lambda/${aws_lambda_function.image_processor.function_name}"
  retention_in_days = 30
}


# ==============================================================================
# 4. S3 TRIGGER → ImageProcessorLambda
# ==============================================================================
# Cada vez que se suba un objeto a profile-images/ (no a thumbnails/ ni optimized/)
# S3 invocará automáticamente la Lambda.

# Permiso para que S3 pueda invocar la Lambda
resource "aws_lambda_permission" "s3_invoke_image_processor" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.image_processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.media.arn
}

# Notificación S3 → Lambda
resource "aws_s3_bucket_notification" "media_uploads" {
  bucket = aws_s3_bucket.media.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "profile-images/"   # Solo archivos en esta carpeta
    # Sin filter_suffix para soportar jpg, jpeg, png, webp, etc.
  }

  depends_on = [aws_lambda_permission.s3_invoke_image_processor]
}


# ==============================================================================
# 5. SNS TOPIC — task-events-topic
# ==============================================================================
# Tu TaskService.cs publica aquí con PublishAsync (fire-and-forget).
# SNS distribuye el mensaje a todas las colas suscritas simultáneamente.

resource "aws_sns_topic" "task_events" {
  name = "${var.project_name}-task-events-topic"
}


# ==============================================================================
# 6. SQS DLQ — Dead Letter Queue
# ==============================================================================
# Recibe mensajes que fallaron 3 veces en task-email-queue.
# Sirve para diagnosticar errores sin perder mensajes.
# Retención: 7 días para que puedas investigar qué salió mal.

resource "aws_sqs_queue" "task_email_dlq" {
  name                      = "${var.project_name}-task-email-dlq"
  message_retention_seconds = 604800  # 7 días
}


# ==============================================================================
# 7. SQS QUEUE — task-email-queue
# ==============================================================================
# Recibe mensajes del SNS Topic.
# TaskNotifierLambda los consume y envía emails vía SES.

resource "aws_sqs_queue" "task_email" {
  name                       = "${var.project_name}-task-email-queue"
  message_retention_seconds  = 86400   # 1 día — como en tu configuración manual
  visibility_timeout_seconds = 60      # Tiempo que la Lambda tiene para procesar
                                       # Debe ser >= timeout de la Lambda (30s aquí con margen)

  # DLQ: si un mensaje falla 3 veces, va a la DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.task_email_dlq.arn
    maxReceiveCount     = 3
  })
}

# Política que permite a SNS enviar mensajes a esta SQS queue
resource "aws_sqs_queue_policy" "task_email" {
  queue_url = aws_sqs_queue.task_email.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.task_email.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_sns_topic.task_events.arn
        }
      }
    }]
  })
}


# ==============================================================================
# 8. SNS → SQS SUBSCRIPTION
# ==============================================================================
# Conecta el SNS Topic con la SQS Queue.
# raw_message_delivery = false → SNS envuelve el mensaje en un sobre JSON
# Tu TaskNotifierLambda deserializa ese sobre (SnsEnvelope → payload real)

resource "aws_sns_topic_subscription" "task_email" {
  topic_arn            = aws_sns_topic.task_events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.task_email.arn
  raw_message_delivery = false  # false = sobre SNS estándar (tu Lambda lo espera así)
}


# ==============================================================================
# 9. IAM ROLE — TaskNotifierLambda
# ==============================================================================

resource "aws_iam_role" "task_notifier_lambda" {
  name = "${var.project_name}-task-notifier-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_notifier_basic" {
  role       = aws_iam_role.task_notifier_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Permisos SQS: leer y borrar mensajes de la cola
resource "aws_iam_role_policy" "task_notifier_sqs" {
  name = "${var.project_name}-task-notifier-sqs-policy"
  role = aws_iam_role.task_notifier_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ]
      Resource = aws_sqs_queue.task_email.arn
    }]
  })
}

# Permisos SES: enviar emails
resource "aws_iam_role_policy" "task_notifier_ses" {
  name = "${var.project_name}-task-notifier-ses-policy"
  role = aws_iam_role.task_notifier_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ses:SendEmail",
        "ses:SendRawEmail"
      ]
      Resource = "*"  # SES no soporta ARN de recurso específico en sandbox
    }]
  })
}


# ==============================================================================
# 10. LAMBDA — TaskNotifierLambda
# ==============================================================================

resource "aws_lambda_function" "task_notifier" {
  function_name = "${var.project_name}-task-notifier"
  role          = aws_iam_role.task_notifier_lambda.arn
  runtime       = "dotnet8"
  handler       = "TaskNotifierLambda::TaskNotifierLambda.Function::FunctionHandler"
  timeout       = 30
  memory_size   = 256  # Menos RAM que ImageProcessor — solo serialización y HTTP

  filename         = "${path.module}/placeholder.zip"
  source_code_hash = filebase64sha256("${path.module}/placeholder.zip")

  environment {
    variables = {
      SES_FROM_EMAIL         = var.ses_sender_email
      ASPNETCORE_ENVIRONMENT = "Production"
      AWS_SES_REGION         = var.aws_region
    }
  }

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

# CloudWatch Log Group para TaskNotifierLambda
resource "aws_cloudwatch_log_group" "task_notifier" {
  name              = "/aws/lambda/${aws_lambda_function.task_notifier.function_name}"
  retention_in_days = 30
}


# ==============================================================================
# 11. SQS TRIGGER → TaskNotifierLambda
# ==============================================================================
# Event Source Mapping: SQS invoca automáticamente la Lambda
# cuando hay mensajes en la cola. Batch size 10 = procesa hasta
# 10 mensajes por invocación (eficiente y dentro del free tier).

resource "aws_lambda_event_source_mapping" "sqs_to_task_notifier" {
  event_source_arn = aws_sqs_queue.task_email.arn
  function_name    = aws_lambda_function.task_notifier.arn
  batch_size       = 10     # Mensajes por invocación
  enabled          = true

  # Reporte parcial de fallos: si 1 mensaje del batch falla,
  # solo ese va a la DLQ — los demás se procesan normalmente.
  # Tu TaskNotifierLambda ya usa SQSBatchResponse para esto.
  function_response_types = ["ReportBatchItemFailures"]
}
