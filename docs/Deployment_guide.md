# 🚀 Guía Completa: Deploy del Backend .NET a AWS ECS Fargate

## 📋 Índice
1. [Pre-requisitos](#pre-requisitos)
2. [Configuración de AWS](#configuración-de-aws)
3. [Configuración de GitHub](#configuración-de-github)
4. [Deployment](#deployment)
5. [Gestión de Costos](#gestión-de-costos)
6. [Troubleshooting](#troubleshooting)

---

## 1️⃣ Pre-requisitos

### Herramientas necesarias:
- ✅ Cuenta de AWS (Free Tier disponible)
- ✅ AWS CLI instalado y configurado
- ✅ Cuenta de GitHub con tu repositorio
- ✅ Docker Desktop (para testing local)
- ✅ Git
- ✅ .NET 8 SDK

### Archivos del proyecto:
```
tu-repo/
├── .github/
│   └── workflows/
│       └── deploy-backend.yml    ← Pipeline CI/CD
├── Dockerfile                     ← Imagen Docker
├── .dockerignore                  ← Optimización de build
├── gestion-de-proyectos.csproj   ← Tu proyecto .NET
├── Program.cs
├── appsettings.json
└── ...resto de archivos
```

---

## 2️⃣ Configuración de AWS

### **Paso 2.1: Crear ECR Repository (Registro de Imágenes)**

1. **Por CLI:**
```bash
aws ecr create-repository \
  --repository-name gestion-proyectos-backend \
  --region us-east-2 \
  --image-scanning-configuration scanOnPush=true
```

2. **Por Consola:**
- Ve a: https://console.aws.amazon.com/ecr/
- Click en "Create repository"
- Repository name: `gestion-proyectos-backend`
- Enable scan on push: ✅
- Encryption: Default (AES-256)
- Click "Create repository"

**Guarda el URI del repositorio:**
```
123456789012.dkr.ecr.us-east-2.amazonaws.com/gestion-proyectos-backend
```

---

### **Paso 2.2: Crear VPC y Subnets (si no tienes)**

**Opción A: Usar VPC Default (Más Rápido)**
```bash
# Obtener VPC ID default
aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId"

# Obtener Subnets
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<VPC_ID>" --query "Subnets[*].SubnetId"
```

**Opción B: Crear VPC Nueva (Recomendado para Producción)**
```bash
# Crear VPC
aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=gestion-proyectos-vpc}]'

# Crear Subnet Pública 1 (us-east-2a)
aws ec2 create-subnet --vpc-id <VPC_ID> --cidr-block 10.0.1.0/24 --availability-zone us-east-2a

# Crear Subnet Pública 2 (us-east-2b) - ECS requiere 2 subnets mínimo
aws ec2 create-subnet --vpc-id <VPC_ID> --cidr-block 10.0.2.0/24 --availability-zone us-east-2b

# Crear Internet Gateway
aws ec2 create-internet-gateway --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=gestion-proyectos-igw}]'

# Attach IGW a VPC
aws ec2 attach-internet-gateway --internet-gateway-id <IGW_ID> --vpc-id <VPC_ID>

# Crear Route Table y asociar subnets (ver documentación extendida)
```

---

### **Paso 2.3: Crear Security Group**

```bash
# Crear Security Group
aws ec2 create-security-group \
  --group-name gestion-proyectos-sg \
  --description "Security group for backend ECS tasks" \
  --vpc-id <VPC_ID>

# Permitir tráfico HTTP en puerto 8080 (o el que uses)
aws ec2 authorize-security-group-ingress \
  --group-id <SG_ID> \
  --protocol tcp \
  --port 8080 \
  --cidr 0.0.0.0/0

# Permitir tráfico HTTPS (si usas)
aws ec2 authorize-security-group-ingress \
  --group-id <SG_ID> \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0
```

**Guardar el Security Group ID:**
```
sg-0123456789abcdef0
```

---

### **Paso 2.4: Crear ECS Cluster**

```bash
aws ecs create-cluster \
  --cluster-name gestion-proyectos-cluster \
  --region us-east-2 \
  --capacity-providers FARGATE FARGATE_SPOT \
  --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1
```

**Por Consola:**
- Ve a: https://console.aws.amazon.com/ecs/
- Click "Create Cluster"
- Cluster name: `gestion-proyectos-cluster`
- Infrastructure: AWS Fargate (serverless)
- Click "Create"

---

### **Paso 2.5: Crear IAM Role para ECS Task Execution**

**Crear rol:**
```bash
# Crear archivo trust-policy.json
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Crear rol
aws iam create-role \
  --role-name ecsTaskExecutionRole \
  --assume-role-policy-document file://trust-policy.json

# Adjuntar política necesaria
aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```

**Por Consola:**
- Ve a IAM → Roles → Create role
- Trusted entity: AWS service → Elastic Container Service → ECS Task
- Permissions: `AmazonECSTaskExecutionRolePolicy`
- Role name: `ecsTaskExecutionRole`

**Guardar el ARN:**
```
arn:aws:iam::123456789012:role/ecsTaskExecutionRole
```

---

### **Paso 2.6: Crear Task Definition**

**Crear archivo `task-definition.json`:**

```json
{
  "family": "gestion-proyectos-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "arn:aws:iam::123456789012:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "gestion-proyectos-container",
      "image": "123456789012.dkr.ecr.us-east-2.amazonaws.com/gestion-proyectos-backend:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8080,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "ASPNETCORE_ENVIRONMENT",
          "value": "Production"
        },
        {
          "name": "ASPNETCORE_URLS",
          "value": "http://+:8080"
        }
      ],
      "secrets": [
        {
          "name": "ConnectionStrings__PostgreSQLConnection",
          "valueFrom": "arn:aws:secretsmanager:us-east-2:123456789012:secret:db-connection-string"
        },
        {
          "name": "Jwt__Key",
          "valueFrom": "arn:aws:secretsmanager:us-east-2:123456789012:secret:jwt-key"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/gestion-proyectos",
          "awslogs-region": "us-east-2",
          "awslogs-stream-prefix": "backend"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ]
}
```

**Registrar Task Definition:**
```bash
aws ecs register-task-definition \
  --cli-input-json file://task-definition.json
```

---

### **Paso 2.7: Crear Secrets en AWS Secrets Manager**

**Para Connection String:**
```bash
aws secretsmanager create-secret \
  --name db-connection-string \
  --secret-string "Host=tu-rds-endpoint.rds.amazonaws.com;Database=gestion_proyectos;Username=admin;Password=tu-password"
```

**Para JWT Key:**
```bash
aws secretsmanager create-secret \
  --name jwt-key \
  --secret-string "tu-clave-secreta-jwt-de-minimo-32-caracteres"
```

---

### **Paso 2.8: Crear CloudWatch Log Group**

```bash
aws logs create-log-group \
  --log-group-name /ecs/gestion-proyectos
```

---

### **Paso 2.9: Crear ECS Service**

```bash
aws ecs create-service \
  --cluster gestion-proyectos-cluster \
  --service-name gestion-proyectos-service \
  --task-definition gestion-proyectos-task \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx,subnet-yyy],securityGroups=[sg-xxx],assignPublicIp=ENABLED}" \
  --region us-east-2
```

**Por Consola:**
- Ve a ECS → Clusters → gestion-proyectos-cluster → Services → Create
- Launch type: Fargate
- Task Definition: gestion-proyectos-task
- Service name: gestion-proyectos-service
- Number of tasks: 1
- VPC: Selecciona tu VPC
- Subnets: Selecciona 2 subnets públicas
- Security group: gestion-proyectos-sg
- Auto-assign public IP: ENABLED
- Click "Create Service"

---

## 3️⃣ Configuración de GitHub

### **Paso 3.1: Crear GitHub Secrets**

Ve a tu repositorio → Settings → Secrets and variables → Actions → New repository secret

**Secrets necesarios:**

| Secret Name | Valor | Ejemplo |
|-------------|-------|---------|
| `AWS_ACCESS_KEY_ID` | Tu Access Key ID | `AKIAIOSFODNN7EXAMPLE` |
| `AWS_SECRET_ACCESS_KEY` | Tu Secret Access Key | `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` |
| `AWS_ACCOUNT_ID` | Tu AWS Account ID | `123456789012` |
| `ECR_REPOSITORY` | Nombre del repo ECR | `gestion-proyectos-backend` |
| `TASK_FAMILY` | Nombre de Task Definition | `gestion-proyectos-task` |
| `CONTAINER_NAME` | Nombre del contenedor | `gestion-proyectos-container` |
| `ECS_SERVICE` | Nombre del servicio ECS | `gestion-proyectos-service` |
| `ECS_CLUSTER` | Nombre del cluster ECS | `gestion-proyectos-cluster` |
| `DEV_URL` | URL de desarrollo | `http://tu-ip-publica:8080` |
| `PROD_URL` | URL de producción | `http://tu-ip-publica:8080` |

**Cómo obtener AWS Access Keys:**
1. IAM → Users → Tu usuario → Security credentials
2. Create access key
3. Use case: CLI
4. **IMPORTANTE:** Guarda ambas claves en un lugar seguro (no las podrás ver de nuevo)

---

### **Paso 3.2: Configurar Branches Protected (Opcional)**

Settings → Branches → Add branch protection rule:
- Branch name pattern: `main`
- ✅ Require status checks to pass before merging
- ✅ Require branches to be up to date before merging

---

## 4️⃣ Deployment

### **Primer Deployment**

1. **Commit y push los archivos:**
```bash
git add .github/workflows/deploy-backend.yml
git add Dockerfile
git add .dockerignore
git commit -m "feat: add CI/CD pipeline for AWS ECS Fargate"
git push origin develop
```

2. **Verificar el workflow:**
- Ve a: https://github.com/tu-usuario/tu-repo/actions
- Verás el workflow ejecutándose
- Monitorea cada step

3. **Verificar deployment en AWS:**
```bash
# Ver tasks en ejecución
aws ecs list-tasks --cluster gestion-proyectos-cluster --service gestion-proyectos-service

# Obtener IP pública del task
aws ecs describe-tasks --cluster gestion-proyectos-cluster --tasks <TASK_ARN> --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text

# Obtener IP pública de la network interface
aws ec2 describe-network-interfaces --network-interface-ids <ENI_ID> --query "NetworkInterfaces[0].Association.PublicIp"
```

4. **Probar la API:**
```bash
curl http://<IP_PUBLICA>:8080/health
curl http://<IP_PUBLICA>:8080/swagger
```

---

### **Deployments Posteriores**

Cada vez que hagas push a `develop` o `main`:
1. GitHub Actions se ejecutará automáticamente
2. Construirá nueva imagen Docker
3. La subirá a ECR
4. Actualizará ECS Service
5. Fargate hará rolling update (sin downtime)

---

## 5️⃣ Gestión de Costos

### **Estrategias para minimizar costos:**

#### **Opción 1: Apagar el servicio cuando no lo uses**
```bash
# Reducir tasks a 0 (apagar)
aws ecs update-service \
  --cluster gestion-proyectos-cluster \
  --service gestion-proyectos-service \
  --desired-count 0

# Volver a 1 (encender)
aws ecs update-service \
  --cluster gestion-proyectos-cluster \
  --service gestion-proyectos-service \
  --desired-count 1
```

#### **Opción 2: Usar Fargate Spot (ahorro de hasta 70%)**
Modifica tu service para usar Fargate Spot:
```bash
aws ecs update-service \
  --cluster gestion-proyectos-cluster \
  --service gestion-proyectos-service \
  --capacity-provider-strategy capacityProvider=FARGATE_SPOT,weight=1
```

**⚠️ Advertencia:** Fargate Spot puede interrumpir tareas con 2 minutos de aviso.

#### **Opción 3: Schedule con Lambda**
Crea una Lambda function que apague/encienda el servicio en horarios específicos.

#### **Costos Estimados (Free Tier):**

**Fargate:**
- 512 CPU, 1GB RAM = ~$0.049/hora
- 720 horas/mes (siempre encendido) = ~$35/mes
- 160 horas/mes (8h/día, 5 días/semana) = ~$8/mes

**ECR:**
- 500 MB de almacenamiento = Gratis (primer año)

**CloudWatch Logs:**
- 5 GB de ingestion/mes = Gratis
- 5 GB de almacenamiento = Gratis

**Total estimado:** $8-35/mes dependiendo del uso

---

## 6️⃣ Troubleshooting

### **Problema 1: Task no inicia**

**Diagnóstico:**
```bash
# Ver logs del task
aws ecs describe-tasks --cluster gestion-proyectos-cluster --tasks <TASK_ARN>

# Ver logs de CloudWatch
aws logs tail /ecs/gestion-proyectos --follow
```

**Soluciones comunes:**
- ✅ Verificar que el Security Group permite tráfico en el puerto
- ✅ Verificar que las secrets existen en Secrets Manager
- ✅ Verificar que la imagen existe en ECR
- ✅ Revisar task execution role permissions

---

### **Problema 2: No puedo acceder a la API**

**Diagnóstico:**
```bash
# Verificar que el task tiene IP pública asignada
aws ecs describe-tasks --cluster gestion-proyectos-cluster --tasks <TASK_ARN> --query "tasks[0].attachments[0].details"

# Verificar Security Group
aws ec2 describe-security-groups --group-ids <SG_ID>
```

**Soluciones:**
- ✅ Asegurar que `assignPublicIp=ENABLED`
- ✅ Verificar reglas de ingress en Security Group
- ✅ Verificar que la subnet es pública (tiene route a Internet Gateway)

---

### **Problema 3: Pipeline falla en build**

**Diagnóstico:**
Ver logs en GitHub Actions

**Soluciones comunes:**
- ✅ Verificar que Dockerfile está en la raíz
- ✅ Verificar que los secrets de AWS están configurados
- ✅ Verificar permisos de ECR

---

### **Problema 4: Health check failing**

**Soluciones:**
- ✅ Asegurar que tu app expone un endpoint `/health`
- ✅ Ajustar el `startPeriod` en health check (dar más tiempo inicial)
- ✅ Verificar los logs para ver por qué la app no arranca

---

## 🎯 Comandos Útiles

### **Monitoreo**
```bash
# Ver tasks en ejecución
aws ecs list-tasks --cluster gestion-proyectos-cluster

# Ver logs en tiempo real
aws logs tail /ecs/gestion-proyectos --follow

# Ver estado del servicio
aws ecs describe-services --cluster gestion-proyectos-cluster --services gestion-proyectos-service

# Ver métricas de CPU/RAM
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name CPUUtilization \
  --dimensions Name=ServiceName,Value=gestion-proyectos-service Name=ClusterName,Value=gestion-proyectos-cluster \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-01T23:59:59Z \
  --period 300 \
  --statistics Average
```

### **Rollback**
```bash
# Listar revisiones de task definition
aws ecs list-task-definitions --family-prefix gestion-proyectos-task

# Rollback a versión anterior
aws ecs update-service \
  --cluster gestion-proyectos-cluster \
  --service gestion-proyectos-service \
  --task-definition gestion-proyectos-task:1 \
  --force-new-deployment
```

### **Limpieza Completa**
```bash
# 1. Eliminar servicio
aws ecs delete-service --cluster gestion-proyectos-cluster --service gestion-proyectos-service --force

# 2. Eliminar cluster
aws ecs delete-cluster --cluster gestion-proyectos-cluster

# 3. Deregister task definitions (todas las revisiones)
for i in {1..10}; do
  aws ecs deregister-task-definition --task-definition gestion-proyectos-task:$i
done

# 4. Eliminar imágenes de ECR
aws ecr batch-delete-image \
  --repository-name gestion-proyectos-backend \
  --image-ids imageTag=latest

# 5. Eliminar repositorio ECR
aws ecr delete-repository --repository-name gestion-proyectos-backend --force

# 6. Eliminar secrets
aws secretsmanager delete-secret --secret-id db-connection-string --force-delete-without-recovery
aws secretsmanager delete-secret --secret-id jwt-key --force-delete-without-recovery

# 7. Eliminar log group
aws logs delete-log-group --log-group-name /ecs/gestion-proyectos
```

---

## 📚 Próximos Pasos

Una vez que tengas esto funcionando:

1. **Load Balancer:** Agregar ALB para dominio personalizado y HTTPS
2. **Auto Scaling:** Configurar escalado automático basado en CPU/Memoria
3. **RDS Database:** Mover PostgreSQL a RDS para persistencia
4. **Route 53:** Dominio personalizado
5. **CloudFront:** CDN para mejor performance
6. **WAF:** Web Application Firewall para seguridad
7. **Monitoring:** CloudWatch Alarms y SNS notifications

---

## 🆘 Soporte

Si tienes problemas:
1. Revisa los logs de CloudWatch
2. Revisa los eventos del servicio ECS
3. Verifica los secrets y variables de entorno
4. Consulta la documentación oficial de AWS ECS

**Documentación oficial:**
- https://docs.aws.amazon.com/ecs/
- https://docs.aws.amazon.com/AmazonECR/
- https://docs.github.com/en/actions

---

**¡Listo! Ahora tienes un pipeline CI/CD completamente funcional para tu backend .NET en AWS ECS Fargate. 🚀**