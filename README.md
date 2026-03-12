# 🏗️ Infraestructura como Código — Sistema de Gestión de Proyectos

> Terraform · AWS · us-east-2 (Ohio) · Provider `hashicorp/aws ~> 5.0`

[![Terraform](https://img.shields.io/badge/Terraform-1.0+-7B42BC?logo=terraform)](https://www.terraform.io/)
[![AWS](https://img.shields.io/badge/AWS-us--east--2-FF9900?logo=amazonaws)](https://aws.amazon.com/)
[![.NET](https://img.shields.io/badge/.NET-8.0-512BD4?logo=dotnet)](https://dotnet.microsoft.com/)

Infraestructura completa del [Sistema de Gestión de Proyectos](../gestion-de-proyectos) desplegada en AWS mediante Terraform. Construida de forma incremental en 7 etapas, cubriendo backend, frontend, base de datos, procesamiento asíncrono y observabilidad.

---

## 📋 Tabla de Contenidos

- [Arquitectura](#-arquitectura)
- [Estructura de Archivos](#-estructura-de-archivos)
- [Etapas de Construcción](#-etapas-de-construcción)
- [Variables](#-variables)
- [Outputs](#-outputs)
- [Primeros Pasos](#-primeros-pasos)
- [Pipeline CI/CD](#-pipeline-cicd)
- [Gestión de Costos](#-gestión-de-costos)
- [Modelo de Seguridad](#-modelo-de-seguridad)
- [Checklist de Producción](#-checklist-de-producción)

---

## 🏛️ Arquitectura

```
Internet (HTTPS)
       │
       ▼
  CloudFront ──────────────────────────────────── CDN global
       │
       ├── /*        ──► S3 Bucket (Angular build)
       │
       └── /api/*    ──► ALB (HTTP interno)
                           │
                           ▼
                    ECS Fargate  ◄──── Auto Scaling (1–4 tasks)
                    (.NET 8 API)
                           │
              ┌────────────┼────────────┐
              │            │            │
              ▼            ▼            ▼
          S3 Media      RDS PG17     SNS Topic
         (imágenes)   (privado)         │
              │                    SQS Queue ──► DLQ
              │                         │
              ▼                         ▼
     ImageProcessor             TaskNotifier
        Lambda                    Lambda
     (thumbnail +               (email · SES)
      optimized)
```

| Componente | Servicio AWS | Detalle |
|---|---|---|
| **Frontend** | CloudFront + S3 | Angular SPA, bucket privado con OAC |
| **API** | ECS Fargate + ALB | .NET 8, rolling deploy, health checks |
| **Base de datos** | RDS PostgreSQL 17 | db.t3.micro, cifrado en reposo |
| **Procesamiento async** | SNS + SQS + Lambda | Fan-out, DLQ, batch parcial |
| **Imágenes** | S3 + Lambda | Resize automático en upload |
| **Secrets** | Secrets Manager | Inyección en runtime, sin hardcode |
| **Observabilidad** | CloudWatch Alarms | 6 alarmas ECS + ALB |
| **Escalado** | Application Auto Scaling | Target Tracking CPU + Memoria |

---

## 📁 Estructura de Archivos

```
terraform/
├── main.tf              # Provider AWS y configuración global
├── variables.tf         # Definición de todas las variables (30+)
├── terraform.tfvars     # Valores concretos — ⚠️ agregar a .gitignore
├── outputs.tf           # Valores expuestos tras cada apply
│
├── ecr.tf               # ECR repository + lifecycle policy
├── ecs.tf               # Cluster, IAM roles, SG, Task Definition, Service
├── alb.tf               # ALB, Target Group, Listener HTTP :80
├── rds.tf               # RDS PostgreSQL 17, SG, subnet group
├── secrets.tf           # Secrets Manager (connection string + JWT key)
├── frontend.tf          # S3 bucket, OAC, CloudFront distribution
├── monitoring.tf        # 6 CloudWatch Alarms (ECS + ALB)
├── autoscaling.tf       # Scalable target + 2 políticas Target Tracking
├── lambdas.tf           # S3 media, SNS, SQS, DLQ, 2 Lambdas + triggers
└── placeholder.zip      # ZIP mínimo para crear Lambdas (se reemplaza con código real)
```

---

## 🚀 Etapas de Construcción

La infraestructura se construyó de forma incremental. Cada etapa agrega un archivo nuevo sin modificar los anteriores.

### Etapa 1 — ECR + ECS

Base de cómputo del backend.

| Recurso | Nombre en AWS |
|---|---|
| ECR Repository | `gestion-proyectos-terraform-backend` |
| ECS Cluster | `gestion-proyectos-terraform-cluster` |
| IAM Role (execution) | `gestion-proyectos-terraform-ecs-execution-role` |
| IAM Role (task) | `gestion-proyectos-terraform-ecs-task-role` |
| Security Group ECS | `gestion-proyectos-terraform-ecs-tasks-sg` |
| CloudWatch Log Group | `/ecs/gestion-proyectos-terraform` |
| Task Definition | `gestion-proyectos-terraform-task` (CPU 512 / RAM 1024 MB) |
| ECS Service | `gestion-proyectos-terraform-service` |

### Etapa 2 — ALB + Security Groups

Punto de entrada único con URL estable y health checks automáticos.

| Recurso | Detalle |
|---|---|
| Security Group ALB | Ingress 80/tcp desde `0.0.0.0/0` |
| Application Load Balancer | Internet-facing, subnets públicas |
| Target Group | `target_type=ip`, health check `GET /health` cada 30s |
| Listener HTTP :80 | Forward → Target Group |

### Etapa 3 — RDS PostgreSQL 17

Base de datos completamente privada — solo accesible desde los tasks ECS.

| Parámetro | Valor |
|---|---|
| Motor | PostgreSQL 17.4 |
| Instancia | `db.t3.micro` (Free Tier) |
| Almacenamiento | 20 GB gp2 |
| Cifrado en reposo | ✅ Habilitado |
| Acceso público | ❌ Deshabilitado |
| Retención backups | 1 día (límite Free Tier) |
| Multi-AZ | ❌ (Free Tier) |

### Etapa 4 — Secrets Manager

Credenciales inyectadas en runtime como variables de entorno. Nunca hardcodeadas en código ni en la Task Definition.

| Secret | Ruta | Variable de entorno en ECS |
|---|---|---|
| Connection String | `gestion-proyectos-terraform/db-connection-string` | `ConnectionStrings__PostgreSQLConnection` |
| JWT Key | `gestion-proyectos-terraform/jwt-key` | `Jwt__Key` |

> `recovery_window_in_days = 0` permite destruir y recrear sin errores de nombre duplicado.

### Etapa 5 — CloudFront + S3 (Frontend Angular)

El bucket S3 es **privado** — CloudFront accede mediante OAC (Origin Access Control con SigV4). Esto resuelve el problema de Mixed Content sin necesidad de dominio propio: CloudFront actúa como proxy HTTPS hacia el ALB para las llamadas `/api/*`.

| Behavior | Origin | Caché |
|---|---|---|
| `/*` | S3 (Angular build) | 1 día default / 1 año para assets con hash |
| `/api/*` | ALB (HTTP interno) | Sin caché — `min_ttl = max_ttl = 0` |

- **Custom errors 403/404 → `/index.html` con 200** — Angular Router maneja las rutas SPA
- **Certificado SSL:** CloudFront default certificate (`*.cloudfront.net`) — gratuito
- **Price class:** `PriceClass_100` (US + Europa)

### Etapa 6 — Auto Scaling ECS

Dos políticas Target Tracking. AWS calcula cuántos tasks agregar o quitar para mantener los objetivos.

| Política | Métrica | Target | Scale-out | Scale-in |
|---|---|---|---|---|
| CPU | `ECSServiceAverageCPUUtilization` | 70% | 2 min | 5 min |
| Memoria | `ECSServiceAverageMemoryUtilization` | 75% | 2 min | 5 min |

- **Mínimo:** 1 task siempre activo
- **Máximo:** 4 tasks (costo controlado)

### Etapa 7 — Lambdas + SNS + SQS

Capa event-driven desacoplada. El backend publica en SNS (fire-and-forget) y las Lambdas procesan de forma independiente.

```
ECS (.NET) ──PublishAsync──► SNS Topic
                                  │
                             SQS Queue ──► TaskNotifierLambda ──► SES
                                  └──► DLQ (3 fallos → dead letter)

S3 profile-images/ ──ObjectCreated──► ImageProcessorLambda
                                           ├── thumbnails/ (150×150)
                                           └── optimized/  (500×500)
```

| Recurso | Nombre en AWS | Detalle |
|---|---|---|
| S3 Media | `gestion-proyectos-terraform-media-{account_id}` | CORS habilitado, privado |
| SNS Topic | `gestion-proyectos-terraform-task-events-topic` | Broker pub/sub |
| SQS Queue | `gestion-proyectos-terraform-task-email-queue` | Retención 1 día, timeout 60s |
| SQS DLQ | `gestion-proyectos-terraform-task-email-dlq` | Retención 7 días, tras 3 fallos |
| Lambda ImageProcessor | `gestion-proyectos-terraform-image-processor` | dotnet8, 512 MB, 30s |
| Lambda TaskNotifier | `gestion-proyectos-terraform-task-notifier` | dotnet8, 256 MB, 30s, `ReportBatchItemFailures` |

> El código real de las Lambdas vive en el repositorio [`gestion-proyectos-lambdas`](../gestion-proyectos-lambdas). Terraform crea la infraestructura con un `placeholder.zip`; el código se despliega con `aws lambda update-function-code`.

---

## ⚙️ Variables

Las variables se definen en `variables.tf` y sus valores en `terraform.tfvars`.

> ⚠️ Agrega `terraform.tfvars` a `.gitignore` — contiene valores sensibles como `db_password` y `jwt_secret_value`.

| Variable | Default | Descripción |
|---|---|---|
| `aws_region` | `us-east-2` | Región AWS |
| `project_name` | `gestion-proyectos-terraform` | Prefijo para todos los recursos |
| `environment` | `production` | `development` / `staging` / `production` |
| `aws_account_id` | *(requerido)* | 12 dígitos — sufijo en nombres únicos de S3 |
| `vpc_id` | *(requerido)* | ID de la VPC |
| `subnet_ids` | *(requerido)* | Lista de subnets (mín. 2 AZs distintas) |
| `container_port` | `8080` | Puerto de la API .NET |
| `task_cpu` | `512` | 0.5 vCPU por task Fargate |
| `task_memory` | `1024` | 1 GB RAM por task Fargate |
| `db_instance_class` | `db.t3.micro` | Free Tier |
| `db_name` | `gestion_proyectos` | Nombre de la base de datos |
| `db_username` | `dbadmin` | Usuario administrador RDS |
| `db_password` | *(sensible)* | Pasar vía `TF_VAR_db_password` |
| `jwt_secret_value` | *(sensible)* | Mínimo 32 caracteres |
| `ses_sender_email` | `noreply@...` | Email verificado en SES |
| `autoscaling_min_capacity` | `1` | Tasks mínimos siempre activos |
| `autoscaling_max_capacity` | `4` | Tasks máximos permitidos |
| `autoscaling_cpu_target` | `70` | % CPU objetivo |
| `autoscaling_memory_target` | `75` | % Memoria objetivo |

Para pasar valores sensibles sin escribirlos en archivos:

```bash
export TF_VAR_db_password="MiPassword2024!"
export TF_VAR_jwt_secret_value="miJwtKeySuperSecretaDe32CaracteresMinimo"
```

---

## 📤 Outputs

Valores que Terraform imprime al finalizar `terraform apply`. Los marcados con 🔑 son los que van como **GitHub Secrets**.

| Output | Uso |
|---|---|
| `ecr_repository_url` | 🔑 URL para `docker push` en GitHub Actions |
| `ecs_cluster_name` | 🔑 GitHub Secret: `ECS_CLUSTER` |
| `ecs_service_name` | 🔑 GitHub Secret: `ECS_SERVICE` |
| `task_definition_family` | 🔑 GitHub Secret: `TASK_FAMILY` |
| `container_name` | 🔑 GitHub Secret: `CONTAINER_NAME` |
| `cloudfront_domain_name` | URL pública del frontend Angular |
| `alb_dns_name` | URL base del API (sin dominio propio) |
| `rds_endpoint` | Host de conexión PostgreSQL |
| `db_secret_arn` | ARN referenciado en la Task Definition |
| `jwt_secret_arn` | ARN referenciado en la Task Definition |
| `sns_topic_arn` | Valor de `AWS__SnsTopicArn` en Task Definition |
| `s3_media_bucket_name` | Valor de `S3_BUCKET_NAME` en Task Definition |
| `cloudfront_distribution_id` | Para invalidar caché en cada deploy del frontend |
| `sqs_task_email_dlq_url` | Monitorear mensajes fallidos de notificaciones |

Consultar outputs en cualquier momento:
```bash
terraform output
terraform output cloudfront_domain_name
```

---

## 🛠️ Primeros Pasos

### Pre-requisitos

- [Terraform](https://www.terraform.io/downloads) >= 1.0
- [AWS CLI](https://aws.amazon.com/cli/) configurado con `aws configure`
- Cuenta AWS con permisos sobre ECS, ECR, RDS, S3, CloudFront, Lambda, SNS, SQS

### Obtener valores de red

```bash
# Account ID
aws sts get-caller-identity --query Account --output text

# VPC default
aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query "Vpcs[0].VpcId" --output text --region us-east-2

# Subnets (copia al menos 2)
aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=TU_VPC_ID \
  --query "Subnets[*].SubnetId" --output text --region us-east-2
```

### Inicializar y aplicar

```bash
cd terraform

# Descargar el provider de AWS (solo la primera vez)
terraform init

# Ver qué va a crear sin crear nada
terraform plan

# Crear la infraestructura
terraform apply
```

### Desplegar código de las Lambdas

```bash
# Desde el repo gestion-proyectos-lambdas
cd ImageProcessorLambda
dotnet lambda package -o publish.zip
aws lambda update-function-code \
  --function-name gestion-proyectos-terraform-image-processor \
  --zip-file fileb://publish.zip --region us-east-2

cd ../TaskNotifierLambda
dotnet lambda package -o publish.zip
aws lambda update-function-code \
  --function-name gestion-proyectos-terraform-task-notifier \
  --zip-file fileb://publish.zip --region us-east-2
```

### Desplegar el frontend

```bash
# Build de Angular
ng build --configuration production

# Subir al bucket
aws s3 sync dist/tu-app/browser/ \
  s3://$(terraform output -raw s3_bucket_name) --delete

# Invalidar caché de CloudFront
aws cloudfront create-invalidation \
  --distribution-id $(terraform output -raw cloudfront_distribution_id) \
  --paths "/*"
```

---

## 🔄 Pipeline CI/CD

El archivo `.github/workflows/deploy-backend.yml` se ejecuta en cada push a `develop`.

```
push → develop
     │
     ▼
1. Checkout
2. Configure AWS credentials
3. Login a Amazon ECR
4. docker build  ← dos tags: commit SHA + latest
5. docker push   ← ambos tags (una sola transferencia)
6. Download Task Definition desde ECS + limpieza con jq
7. Render Task Definition ← inyecta imagen con SHA exacto
8. Deploy ECS ← rolling update, espera estabilidad
```

> El output del paso build usa el **SHA del commit** (no `latest`) para que cada Task Definition registrada apunte a una versión inmutable — los rollbacks son predecibles.

### GitHub Secrets requeridos

| Secret | Valor |
|---|---|
| `AWS_ACCESS_KEY_ID` | Access key del usuario IAM de deploy |
| `AWS_SECRET_ACCESS_KEY` | Secret key del usuario IAM de deploy |
| `ECR_REPOSITORY` | `terraform output -raw ecr_repository_name` |
| `ECS_CLUSTER` | `terraform output -raw ecs_cluster_name` |
| `ECS_SERVICE` | `terraform output -raw ecs_service_name` |
| `TASK_FAMILY` | `terraform output -raw task_definition_family` |
| `CONTAINER_NAME` | `terraform output -raw container_name` |

---

## 💰 Gestión de Costos

### Costos estimados activos

| Servicio | Costo |
|---|---|
| ECS Fargate (1 task) | ~$0.05/hora (~$35/mes continuo) |
| RDS db.t3.micro | ~$0.017/hora (~$12/mes) |
| ALB | ~$5.50/mes fijo + uso |
| CloudFront | Gratis hasta 1 TB/mes + 10M requests |
| S3, ECR, SNS, SQS, Lambda | Prácticamente gratis en uso bajo |
| Secrets Manager | $0.40/secret/mes (2 secrets = $0.80/mes) |

### Pausa temporal (días / semanas)

```bash
# Apagar ECS — ahorro inmediato
aws ecs update-service \
  --cluster gestion-proyectos-terraform-cluster \
  --service gestion-proyectos-terraform-service \
  --desired-count 0 --region us-east-2

# Detener RDS — ahorro inmediato (AWS lo reinicia automáticamente a los 7 días)
aws rds stop-db-instance \
  --db-instance-identifier gestion-proyectos-terraform-db \
  --region us-east-2
```

Para eliminar el ALB y ahorrar los ~$5.50/mes fijos:
```bash
terraform destroy \
  -target=aws_lb_listener.http \
  -target=aws_lb_target_group.backend \
  -target=aws_lb.main \
  -target=aws_security_group.alb
```
> CloudFront sigue funcionando para el frontend. Solo el path `/api/*` dará 502 hasta recrear el ALB.

### Reactivar

```bash
# Encender ECS
aws ecs update-service \
  --cluster gestion-proyectos-terraform-cluster \
  --service gestion-proyectos-terraform-service \
  --desired-count 1 --region us-east-2

# Encender RDS
aws rds start-db-instance \
  --db-instance-identifier gestion-proyectos-terraform-db \
  --region us-east-2

# Recrear ALB si lo destruiste
terraform apply \
  -target=aws_security_group.alb \
  -target=aws_lb.main \
  -target=aws_lb_target_group.backend \
  -target=aws_lb_listener.http \
  -target=aws_ecs_service.backend
```

### Destrucción completa

```bash
terraform destroy
```

> Terraform resuelve el orden automáticamente. Los Secrets Manager se eliminan de inmediato (`recovery_window_in_days = 0`) y pueden recrearse sin errores en el próximo `apply`.

---

## 🔒 Modelo de Seguridad

| Capa | Control |
|---|---|
| Internet → CloudFront | HTTPS obligatorio, redirect HTTP → HTTPS |
| CloudFront → S3 | Bucket privado + OAC SigV4 — sin acceso público directo |
| CloudFront → ALB | HTTP interno — el navegador nunca ve esta conexión |
| Internet → ECS | Bloqueado — SG de ECS solo acepta tráfico desde SG del ALB |
| ECS → RDS | Puerto 5432 solo accesible desde SG de ECS |
| ECS → Secrets | IAM role con `secretsmanager:GetSecretValue` |
| Lambda → S3 Media | IAM role con `s3:GetObject` + `s3:PutObject` solo en ese bucket |
| Lambda → SES | IAM role con `ses:SendEmail` únicamente |
| Credenciales en código | **Ninguna** — todo vía Secrets Manager o IAM roles |

---

## ✅ Checklist de Producción

Esta infraestructura fue construida con fines de aprendizaje. Antes de usar en producción:

- [ ] Agregar certificado SSL en ACM y listener HTTPS `:443` en el ALB
- [ ] Configurar `redirect-to-https` en el listener `:80`
- [ ] Habilitar `deletion_protection = true` en RDS y ALB
- [ ] Cambiar `backup_retention_period` de RDS a 7+ días
- [ ] Habilitar Multi-AZ en RDS
- [ ] Configurar CORS en la API .NET con dominios específicos (no `*`)
- [ ] Verificar email remitente en SES y solicitar salida del Sandbox
- [ ] Conectar las CloudWatch Alarms a un SNS topic de alertas (email/PagerDuty)
- [ ] Migrar el estado de Terraform a un S3 backend (evitar estado local)
- [ ] Implementar rate limiting en la API
- [ ] Configurar Route 53 con dominio propio apuntando a CloudFront y ALB
- [ ] Revisar y reducir permisos IAM al mínimo necesario por recurso

---

## 🔗 Repositorios Relacionados

| Repositorio | Descripción |
|---|---|
| [`gestion-de-proyectos`](../gestion-de-proyectos) | Backend ASP.NET Core 8 — API REST |
| [`project-management-front`](../project-management-front) | Frontend Angular 20 |
| [`gestion-proyectos-lambdas`](../gestion-proyectos-lambdas) | Lambdas .NET 8 — ImageProcessor + TaskNotifier |

---

*Terraform · AWS ECS Fargate · PostgreSQL 17 · CloudFront · Lambda · v1.0.0*
