# 🌐 Guía Completa: Application Load Balancer + Route 53

## 📋 Tabla de Contenidos

1. [Introducción y Arquitectura](#introducción)
2. [Paso 1: IAM — Permisos Necesarios](#paso-1-iam)
3. [Paso 2: Security Groups](#paso-2-security-groups)
4. [Paso 3: Crear el Application Load Balancer](#paso-3-alb)
5. [Paso 4: Target Group y Health Checks](#paso-4-target-group)
6. [Paso 5: Listeners — HTTP y HTTPS](#paso-5-listeners)
7. [Paso 6: Asociar ECS Service al ALB](#paso-6-ecs)
8. [Paso 7: Certificado SSL con ACM](#paso-7-ssl)
9. [Paso 8: Route 53 — Dominio Personalizado](#paso-8-route53)
10. [Paso 9: Actualizar CORS en el Backend](#paso-9-cors)
11. [Paso 10: Actualizar GitHub Actions](#paso-10-cicd)
12. [Monitoreo y Troubleshooting](#monitoreo)
13. [Costos Estimados](#costos)

---

## 🎯 Introducción

### ¿Qué Vamos a Construir?

Actualmente tu backend en ECS Fargate expone una **IP pública directa** que cambia cada vez que el task se reinicia. Vamos a poner un **Application Load Balancer (ALB)** enfrente para tener una URL estable, y luego **Route 53** para apuntar tu dominio a ese ALB.

### Arquitectura Antes vs Después

**Antes:**
```
Usuario → IP pública del Task ECS (cambia en cada deploy)
```

**Después:**
```
                   ┌──────────────────────────────────────────┐
                   │           VPC (tu red privada)           │
                   │                                           │
Usuario ──HTTPS──► │  ALB (Subnet Pública)                    │
app.dominio.com    │  ├── Listener :443 → Target Group        │
                   │  └── Listener :80  → Redirect a HTTPS    │
                   │              │                            │
                   │              │ HTTP :8080                 │
                   │              ▼                            │
                   │  ECS Fargate Task (Subnet Pública/Privada)│
                   │  [Tu API .NET]                            │
                   │              │                            │
                   │              ▼                            │
                   │  RDS Aurora (Subnet Privada)              │
                   └──────────────────────────────────────────┘
                   
Route 53:
  app.dominio.com → ALIAS → ALB DNS
  api.dominio.com → ALIAS → ALB DNS  (alternativa)
```

### ¿Por qué ALB y no solo la IP del Task?

| Situación | Sin ALB | Con ALB |
|---|---|---|
| Task se reinicia | IP cambia, app cae | ALB detecta nuevo task, transparente |
| Deploy nuevo | Downtime breve | Rolling update sin downtime |
| HTTPS / SSL | Debes configurarlo en .NET | ALB lo maneja, .NET solo HTTP interno |
| Dominio propio | No posible | Route 53 → ALB con 1 registro |
| Health checks | Ninguno | ALB verifica `/health` cada 30s |
| Múltiples tasks | No soportado | Balanceo automático |

---

## 1️⃣ Paso 1: IAM — Permisos Necesarios

Para este setup no necesitas nuevos roles. Solo verifica que tienes acceso a los servicios desde tu usuario de AWS CLI.

```bash
# Verificar que tienes acceso
aws sts get-caller-identity

# Verificar permisos de ELB (debería devolver una lista, aunque esté vacía)
aws elbv2 describe-load-balancers --region us-east-2

# Obtener tu Account ID (lo necesitarás más adelante)
aws sts get-caller-identity --query Account --output text
```

Si usas un usuario IAM en lugar de root, asegúrate de que tiene estas políticas:
- `AmazonEC2FullAccess` (para ALB y Security Groups)
- `ElasticLoadBalancingFullAccess`
- `AmazonRoute53FullAccess`
- `AWSCertificateManagerFullAccess`

---

## 2️⃣ Paso 2: Security Groups

Necesitas **dos Security Groups** separados: uno para el ALB y otro para los tasks ECS.

> **Concepto clave:** El ALB recibe tráfico de internet (puertos 80/443). El ECS Task solo acepta tráfico **desde el ALB** en el puerto de tu app. Esto es defensa en profundidad.

### Paso 2.1: Security Group para el ALB

```bash
# Crear SG para el ALB
aws ec2 create-security-group \
  --group-name gestion-proyectos-alb-sg \
  --description "Security Group para el Application Load Balancer" \
  --vpc-id <VPC_ID> \
  --region us-east-2

# Guardar el ID: sg-XXXXXXXXXXXXXXXXX
```

Permitir tráfico HTTP y HTTPS desde internet:

```bash
# HTTP desde cualquier lugar
aws ec2 authorize-security-group-ingress \
  --group-id <ALB_SG_ID> \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region us-east-2

# HTTPS desde cualquier lugar
aws ec2 authorize-security-group-ingress \
  --group-id <ALB_SG_ID> \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0 \
  --region us-east-2
```

### Paso 2.2: Actualizar el Security Group del ECS Task

El SG de tu ECS Task (el que creaste en el Deployment Guide) debe aceptar tráfico **solo desde el ALB**, no desde internet:

```bash
# PRIMERO: Eliminar la regla que permite tráfico directo desde internet al puerto 8080
aws ec2 revoke-security-group-ingress \
  --group-id <ECS_SG_ID> \
  --protocol tcp \
  --port 8080 \
  --cidr 0.0.0.0/0 \
  --region us-east-2

# AGREGAR: Solo permitir tráfico desde el SG del ALB
aws ec2 authorize-security-group-ingress \
  --group-id <ECS_SG_ID> \
  --protocol tcp \
  --port 8080 \
  --source-group <ALB_SG_ID> \
  --region us-east-2
```

> ⚠️ **Importante:** Si todavía no tienes HTTPS funcionando, deja temporalmente el puerto 8080 abierto a internet mientras pruebas. Ciérralo cuando confirmes que el ALB funciona.

**Obtener IDs si no los tienes:**
```bash
# Ver todos tus Security Groups
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=<VPC_ID>" \
  --query "SecurityGroups[*].{ID:GroupId,Name:GroupName}" \
  --region us-east-2
```

---

## 3️⃣ Paso 3: Crear el Application Load Balancer

El ALB necesita **al menos 2 subnets en diferentes Availability Zones** (requisito de AWS para alta disponibilidad).

### Paso 3.1: Verificar tus subnets

```bash
# Ver subnets disponibles en tu VPC
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<VPC_ID>" \
  --query "Subnets[*].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,Public:MapPublicIpOnLaunch}" \
  --region us-east-2
```

Necesitas 2 subnets **públicas** (MapPublicIpOnLaunch = true) en AZs diferentes.
Si solo tienes una, crea la segunda:

```bash
# Crear segunda subnet pública en AZ diferente
aws ec2 create-subnet \
  --vpc-id <VPC_ID> \
  --cidr-block 10.0.3.0/24 \
  --availability-zone us-east-2b \
  --region us-east-2

# Habilitar IP pública automática
aws ec2 modify-subnet-attribute \
  --subnet-id <NUEVA_SUBNET_ID> \
  --map-public-ip-on-launch

# Asociar a la Route Table pública (la que tiene el Internet Gateway)
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=<VPC_ID>" \
  --region us-east-2

aws ec2 associate-route-table \
  --subnet-id <NUEVA_SUBNET_ID> \
  --route-table-id <ROUTE_TABLE_ID> \
  --region us-east-2
```

### Paso 3.2: Crear el ALB

```bash
aws elbv2 create-load-balancer \
  --name gestion-proyectos-alb \
  --subnets <SUBNET_ID_1> <SUBNET_ID_2> \
  --security-groups <ALB_SG_ID> \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --region us-east-2

# Output importante — guardar:
# LoadBalancerArn: arn:aws:elasticloadbalancing:us-east-2:ACCOUNT:loadbalancer/app/gestion-proyectos-alb/XXXX
# DNSName: gestion-proyectos-alb-XXXXXXXXX.us-east-2.elb.amazonaws.com
```

**Guardar el DNS del ALB** — lo necesitarás para probar antes de tener dominio:
```bash
aws elbv2 describe-load-balancers \
  --names gestion-proyectos-alb \
  --query "LoadBalancers[0].DNSName" \
  --output text \
  --region us-east-2
```

**Agregar etiquetas:**
```bash
aws elbv2 add-tags \
  --resource-arns <ALB_ARN> \
  --tags Key=Project,Value=gestion-proyectos Key=Environment,Value=develop \
  --region us-east-2
```

---

## 4️⃣ Paso 4: Target Group y Health Checks

El **Target Group** es el grupo de destinos (tus tasks ECS) al que el ALB envía el tráfico. Los **Health Checks** verifican que cada task esté respondiendo correctamente antes de enviarle tráfico.

```bash
# Primero necesitas el VPC ID
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" \
  --output text \
  --region us-east-2)

aws elbv2 create-target-group \
  --name gestion-proyectos-tg \
  --protocol HTTP \
  --port 8080 \
  --vpc-id <VPC_ID> \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --region us-east-2

# Guardar el ARN:
# TargetGroupArn: arn:aws:elasticloadbalancing:us-east-2:ACCOUNT:targetgroup/gestion-proyectos-tg/XXXX
```

**Parámetros de Health Check explicados:**

| Parámetro | Valor | Significado |
|---|---|---|
| `health-check-path` | `/health` | El endpoint que ya tienes con `AddHealthChecks()` en Program.cs |
| `health-check-interval-seconds` | 30 | Verificar cada 30 segundos |
| `health-check-timeout-seconds` | 5 | Si no responde en 5s, contar como fallo |
| `healthy-threshold-count` | 2 | 2 checks exitosos → task es saludable |
| `unhealthy-threshold-count` | 3 | 3 fallos → task es eliminado del balanceo |
| `target-type` | ip | Necesario para ECS Fargate (no EC2 instances) |

> ✅ **Tu `Program.cs` ya tiene** `builder.Services.AddHealthChecks()` y el Deployment Guide ya configura `healthCheck` en el task definition. El ALB usará ese mismo endpoint.

---

## 5️⃣ Paso 5: Listeners — HTTP y HTTPS

Los **Listeners** definen cómo el ALB procesa las conexiones entrantes. Crearemos dos:
- Puerto 80 (HTTP) → Redirige automáticamente a HTTPS
- Puerto 443 (HTTPS) → Envía tráfico al Target Group

### Paso 5.1: Listener HTTP (redirige a HTTPS)

```bash
aws elbv2 create-listener \
  --load-balancer-arn <ALB_ARN> \
  --protocol HTTP \
  --port 80 \
  --default-actions '[
    {
      "Type": "redirect",
      "RedirectConfig": {
        "Protocol": "HTTPS",
        "Port": "443",
        "StatusCode": "HTTP_301"
      }
    }
  ]' \
  --region us-east-2
```

### Paso 5.2: Listener HTTPS (requiere certificado SSL)

> ⚠️ **Este paso requiere el ARN del certificado SSL** de ACM (Paso 7). Si aún no tienes dominio ni certificado, crea temporalmente solo el listener HTTP que apunta al Target Group para probar:

```bash
# ── TEMPORAL (sin HTTPS, solo para probar) ──────────────────────────────────
aws elbv2 create-listener \
  --load-balancer-arn <ALB_ARN> \
  --protocol HTTP \
  --port 80 \
  --default-actions '[
    {
      "Type": "forward",
      "TargetGroupArn": "<TARGET_GROUP_ARN>"
    }
  ]' \
  --region us-east-2
# ─────────────────────────────────────────────────────────────────────────────

# ── DEFINITIVO (después de obtener el certificado en el Paso 7) ──────────────
aws elbv2 create-listener \
  --load-balancer-arn <ALB_ARN> \
  --protocol HTTPS \
  --port 443 \
  --certificates CertificateArn=<CERTIFICATE_ARN> \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --default-actions '[
    {
      "Type": "forward",
      "TargetGroupArn": "<TARGET_GROUP_ARN>"
    }
  ]' \
  --region us-east-2
# ─────────────────────────────────────────────────────────────────────────────
```

**Verificar que los listeners se crearon:**
```bash
aws elbv2 describe-listeners \
  --load-balancer-arn <ALB_ARN> \
  --region us-east-2
```

---

## 6️⃣ Paso 6: Asociar ECS Service al ALB

Este paso actualiza tu ECS Service para que registre automáticamente cada task en el Target Group del ALB. A partir de aquí, cada vez que ECS lance un nuevo task, el ALB lo detecta y empieza a enviarle tráfico una vez que el health check pase.

```bash
aws ecs update-service \
  --cluster gestion-proyectos-cluster \
  --service gestion-proyectos-service \
  --load-balancers '[
    {
      "targetGroupArn": "<TARGET_GROUP_ARN>",
      "containerName": "gestion-proyectos-container",
      "containerPort": 8080
    }
  ]' \
  --health-check-grace-period-seconds 60 \
  --force-new-deployment \
  --region us-east-2
```

> **`health-check-grace-period-seconds: 60`** — Da 60 segundos al contenedor para iniciar antes de que el ALB empiece a evaluar los health checks. Tu app .NET necesita tiempo para arrancar.

### Verificar que los targets se registraron

```bash
# Ver tasks registrados en el Target Group
aws elbv2 describe-target-health \
  --target-group-arn <TARGET_GROUP_ARN> \
  --region us-east-2
```

Los targets pasarán por estos estados:
- `initial` → El ALB acaba de registrar el task
- `healthy` → El health check a `/health` devolvió 200 ✅
- `unhealthy` → El health check falló (ver troubleshooting)

### Probar el ALB antes de configurar el dominio

```bash
# El DNS del ALB ya debe responder
curl http://gestion-proyectos-alb-XXXXXXXXX.us-east-2.elb.amazonaws.com/health

# También probar Swagger
curl http://gestion-proyectos-alb-XXXXXXXXX.us-east-2.elb.amazonaws.com/swagger
```

Si responde, el ALB está funcionando correctamente. ✅

---

## 7️⃣ Paso 7: Certificado SSL con ACM

AWS Certificate Manager (ACM) provee certificados SSL **gratuitos** para usar con ALB. El proceso es:

1. Solicitar certificado para tu dominio
2. Validar que eres dueño del dominio (vía DNS con Route 53)
3. ACM emite el certificado automáticamente

### Paso 7.1: Solicitar el certificado

```bash
aws acm request-certificate \
  --domain-name "api.tudominio.com" \
  --subject-alternative-names "*.tudominio.com" \
  --validation-method DNS \
  --region us-east-2

# Guardar el CertificateArn:
# arn:aws:acm:us-east-2:ACCOUNT_ID:certificate/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
```

> **`--subject-alternative-names "*.tudominio.com"`** — El wildcard cubre todos los subdominios (api., app., www., etc.) con un solo certificado.

> ⚠️ **Importante:** Si tu dominio y el ALB están en regiones diferentes, el certificado para CloudFront **debe** estar en `us-east-1`. Para ALB, debe estar en la **misma región** que el ALB.

### Paso 7.2: Obtener los registros DNS de validación

```bash
aws acm describe-certificate \
  --certificate-arn <CERTIFICATE_ARN> \
  --query "Certificate.DomainValidationOptions[*].{Domain:DomainName,Name:ResourceRecord.Name,Value:ResourceRecord.Value,Type:ResourceRecord.Type}" \
  --region us-east-2
```

Output de ejemplo:
```json
[
  {
    "Domain": "api.tudominio.com",
    "Name": "_abc123def456.api.tudominio.com.",
    "Value": "_xyz789.acm-validations.aws.",
    "Type": "CNAME"
  }
]
```

### Paso 7.3: Agregar el registro CNAME en Route 53

En el siguiente paso (Paso 8) crearás la Hosted Zone. Una vez que la tengas, agrega el registro de validación:

```bash
# Obtener el Hosted Zone ID (después del Paso 8.1)
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name tudominio.com \
  --query "HostedZones[0].Id" \
  --output text | sed 's/\/hostedzone\///')

# Crear el registro de validación
cat > acm-validation.json << 'EOF'
{
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "_abc123def456.api.tudominio.com.",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [
          { "Value": "_xyz789.acm-validations.aws." }
        ]
      }
    }
  ]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id $ZONE_ID \
  --change-batch file://acm-validation.json
```

ACM detecta el registro CNAME y emite el certificado en 5-30 minutos. Verifica el estado:

```bash
aws acm describe-certificate \
  --certificate-arn <CERTIFICATE_ARN> \
  --query "Certificate.Status" \
  --region us-east-2
# Output: "ISSUED" cuando está listo
```

Una vez emitido, vuelve al **Paso 5.2** y crea el Listener HTTPS con este certificado.

---

## 8️⃣ Paso 8: Route 53 — Dominio Personalizado

Route 53 es el DNS de AWS. Aquí configuras `api.tudominio.com` para que apunte a tu ALB.

### ¿Tienes dominio? Elige tu caso:

**Caso A: Registrar dominio en Route 53** (~$12/año para `.click` o `.link`, ~$14 para `.com`)
**Caso B: Tienes dominio en otro registrador** (GoDaddy, Namecheap, etc.)
**Caso C: Solo practicar sin dominio real** (usa el DNS del ALB directamente)

---

### Paso 8.1: Crear la Hosted Zone

Una Hosted Zone es el "contenedor" de todos tus registros DNS para un dominio.

```bash
aws route53 create-hosted-zone \
  --name tudominio.com \
  --caller-reference "gestion-proyectos-$(date +%s)" \
  --hosted-zone-config Comment="Hosted zone para gestion-proyectos"

# Output importante — guardar:
# Id: /hostedzone/Z1234567890ABC
# NameServers: ns-XXX.awsdns-XX.com (4 nameservers)
```

**Obtener los nameservers:**
```bash
aws route53 get-hosted-zone \
  --id /hostedzone/<ZONE_ID> \
  --query "DelegationSet.NameServers"
```

Output:
```json
[
  "ns-123.awsdns-45.com",
  "ns-678.awsdns-90.net",
  "ns-111.awsdns-22.org",
  "ns-444.awsdns-55.co.uk"
]
```

### Paso 8.2: Configurar Nameservers (solo Caso B)

Si tu dominio está en otro registrador, debes apuntar sus nameservers a Route 53:

- GoDaddy: My Products → DNS → Nameservers → Change → Enter my own nameservers
- Namecheap: Domain List → Manage → Nameservers → Custom DNS
- Ingresa los 4 nameservers que devolvió el comando anterior

> ⚠️ La propagación de nameservers puede tomar hasta 48 horas (normalmente 1-2 horas).

### Paso 8.3: Crear registro ALIAS para el backend (ALB)

El registro **ALIAS** es específico de AWS y apunta directamente al ALB sin costo adicional de consulta DNS. Es la forma correcta de conectar Route 53 con un ALB (no usar CNAME para esto).

Primero necesitas el **Hosted Zone ID del ALB** (es diferente al de tu Hosted Zone):

```bash
# Obtener el Hosted Zone ID del ALB (propiedad de AWS, no tuya)
aws elbv2 describe-load-balancers \
  --names gestion-proyectos-alb \
  --query "LoadBalancers[0].CanonicalHostedZoneId" \
  --output text \
  --region us-east-2
# Output: Z35SXDOTRQ7X7K (este es el ID fijo de la región us-east-2 para ALBs)
```

**Crear el registro DNS:**

```bash
cat > route53-backend.json << 'EOF'
{
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "api.tudominio.com",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "Z35SXDOTRQ7X7K",
          "DNSName": "gestion-proyectos-alb-XXXXXXXXX.us-east-2.elb.amazonaws.com",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id <ZONE_ID> \
  --change-batch file://route53-backend.json
```

> **`EvaluateTargetHealth: true`** — Si todos los targets del ALB están unhealthy, Route 53 responde con SERVFAIL en lugar de devolver la IP del ALB caído. Esto acelera la detección de fallos.

### Paso 8.4: Crear registro para el frontend (CloudFront)

Si tu frontend está en CloudFront, también puedes apuntar `app.tudominio.com` a él:

```bash
# El Hosted Zone ID de CloudFront es siempre Z2FDTNDATAQYW2 (global, no cambia)
cat > route53-frontend.json << 'EOF'
{
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "app.tudominio.com",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "Z2FDTNDATAQYW2",
          "DNSName": "d5555555555555.cloudfront.net",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id <ZONE_ID> \
  --change-batch file://route53-frontend.json
```

### Paso 8.5: Verificar la propagación DNS

```bash
# Verificar que el registro existe en Route 53
aws route53 list-resource-record-sets \
  --hosted-zone-id <ZONE_ID> \
  --query "ResourceRecordSets[?Name=='api.tudominio.com.']"

# Verificar que resuelve correctamente (puede tardar unos minutos)
nslookup api.tudominio.com
dig api.tudominio.com

# Probar el endpoint con dominio propio
curl https://api.tudominio.com/health
```

---

## 9️⃣ Paso 9: Actualizar CORS en el Backend

Ahora que tienes dominio propio, actualiza la política CORS en `Program.cs` para incluir la nueva URL:

```csharp
// Program.cs — Actualizar la política CORS
builder.Services.AddCors(options =>
{
    options.AddPolicy("WebAppProxy", app =>
    {
        app.WithOrigins(
            "http://localhost:4200",                          // Desarrollo local
            "https://app.tudominio.com",                     // Frontend con dominio propio
            "https://d5555555555555.cloudfront.net"          // Frontend CloudFront (por si acaso)
        )
        .AllowAnyHeader()
        .AllowAnyMethod()
        .AllowCredentials();
    });
});
```

Commitea el cambio y el pipeline de GitHub Actions desplegará automáticamente la nueva versión.

---

## 🔟 Paso 10: Actualizar GitHub Actions y Variables de Entorno

### Paso 10.1: Actualizar secrets de GitHub

En tu repositorio: **Settings → Secrets and variables → Actions**

| Secret | Valor anterior | Valor nuevo |
|---|---|---|
| `DEV_URL` | IP pública del task | `https://api.tudominio.com` |

### Paso 10.2: Actualizar el workflow del frontend

Si tu workflow del frontend (`deploy-front-s3.yml`) referencia la URL del backend, actualízala:

```yaml
# deploy-front-s3.yml — Actualizar la URL de la API
- name: Build
  env:
    VITE_API_URL: https://api.tudominio.com   # ← URL con dominio propio
  run: npm run ${{ env.DEPLOY_AMBIENTE }}
```

### Paso 10.3: Actualizar appsettings o variables de ECS

Si en `appsettings.json` tienes alguna URL de callback o CORS que apuntaba a la IP del ALB:

```json
{
  "AllowedOrigins": "https://app.tudominio.com",
  "ApiBaseUrl": "https://api.tudominio.com"
}
```

En ECS, actualiza la task definition con las nuevas URLs y haz `aws ecs update-service --force-new-deployment`.

---

## 📊 Monitoreo y Troubleshooting

### Monitoreo del ALB

```bash
# Ver estado de los targets en tiempo real
watch -n 5 "aws elbv2 describe-target-health \
  --target-group-arn <TARGET_GROUP_ARN> \
  --region us-east-2 \
  --query 'TargetHealthDescriptions[*].{IP:Target.Id,Puerto:Target.Port,Estado:TargetHealth.State,Razon:TargetHealth.Reason}'"

# Ver métricas del ALB (últimos 30 minutos)
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name RequestCount \
  --dimensions Name=LoadBalancer,Value=app/gestion-proyectos-alb/XXXXXXXXXXXX \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum \
  --region us-east-2
```

### Alarma de targets unhealthy

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name ALBUnhealthyHosts \
  --alarm-description "Hay targets unhealthy en el ALB" \
  --metric-name UnHealthyHostCount \
  --namespace AWS/ApplicationELB \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --dimensions \
    Name=LoadBalancer,Value=app/gestion-proyectos-alb/XXXXXXXXXXXX \
    Name=TargetGroup,Value=targetgroup/gestion-proyectos-tg/XXXXXXXXXXXX \
  --region us-east-2
```

### Monitoreo de Route 53

```bash
# Ver el estado de los health checks de Route 53
aws route53 list-health-checks

# Ver registros de la Hosted Zone
aws route53 list-resource-record-sets \
  --hosted-zone-id <ZONE_ID> \
  --query "ResourceRecordSets[*].{Nombre:Name,Tipo:Type}"
```

---

### Troubleshooting Común

**❌ Problema: Target aparece como `unhealthy` en el ALB**

```bash
# Ver el motivo exacto
aws elbv2 describe-target-health \
  --target-group-arn <TARGET_GROUP_ARN> \
  --query "TargetHealthDescriptions[*].TargetHealth" \
  --region us-east-2
```

Causas comunes:
- `HealthCheckConnectRefused` → El Security Group del ECS Task no permite tráfico desde el SG del ALB. Revisa el Paso 2.2.
- `Target.NotInUse` → El ECS Service aún no asoció el task. Espera 1-2 minutos tras el deploy.
- `Target.FailedHealthChecks` → Tu endpoint `/health` devuelve algo distinto a 200. Prueba directamente: `curl http://<IP_TASK>:8080/health`

---

**❌ Problema: El ALB devuelve 502 Bad Gateway**

502 significa que el ALB contactó al target pero no recibió respuesta válida.

```bash
# Ver logs de CloudWatch del task
aws logs tail /ecs/gestion-proyectos --follow --region us-east-2
```

Causas comunes:
- La app .NET no arrancó correctamente (falta variable de entorno, error en startup)
- El task está escuchando en un puerto diferente al configurado en el Target Group (8080)
- El `startPeriod` del health check es muy corto — aumentarlo a 90 segundos

---

**❌ Problema: `nslookup api.tudominio.com` no resuelve**

```bash
# Verificar que el registro existe en Route 53
aws route53 list-resource-record-sets \
  --hosted-zone-id <ZONE_ID>

# Verificar que los nameservers están apuntando a Route 53
dig NS tudominio.com
```

Si los nameservers no son los de AWS (`*.awsdns-*.com`), la propagación aún no completó o no los configuraste en tu registrador.

---

**❌ Problema: ERR_SSL_PROTOCOL_ERROR al acceder con HTTPS**

El Listener HTTPS no existe o el certificado no se emitió.

```bash
# Verificar listeners
aws elbv2 describe-listeners \
  --load-balancer-arn <ALB_ARN> \
  --region us-east-2

# Verificar estado del certificado
aws acm describe-certificate \
  --certificate-arn <CERTIFICATE_ARN> \
  --query "Certificate.Status" \
  --region us-east-2
```

---

**❌ Problema: CORS error desde el frontend**

```bash
# Verificar que el header aparece en la respuesta
curl -v -H "Origin: https://app.tudominio.com" \
  https://api.tudominio.com/health
```

Si no aparece `Access-Control-Allow-Origin` en la respuesta, el CORS del backend no está configurado para ese origen. Revisa el Paso 9 y redeploya.

---

## 💰 Costos Estimados

Para un proyecto de portafolio con bajo tráfico:

| Servicio | Cálculo | Costo/mes |
|---|---|---|
| **ALB** | ~$0.008/hora × 720h + $0.008 por LCU | ~$5.76 base + uso |
| **Route 53 Hosted Zone** | $0.50 por zona | $0.50 |
| **Route 53 Queries** | Primer millón gratis | $0.00 |
| **ACM Certificado** | Gratuito con ALB | $0.00 |
| **Dominio .click** | ~$12/año | $1.00/mes |
| **Total estimado** | | **~$7-10 USD/mes** |

> **⚠️ Nota sobre el ALB:** El ALB cuesta ~$5.76/mes solo por existir, incluso sin tráfico. Para un portfolio que no necesita estar siempre disponible, puedes:
> ```bash
> # Eliminar el ALB cuando no lo uses (conserva el Target Group y Listeners en la consola para recrearlo rápido)
> aws elbv2 delete-load-balancer --load-balancer-arn <ALB_ARN> --region us-east-2
> ```

---

## ✅ Checklist Final

### ALB
- [ ] Security Group del ALB creado (puertos 80 y 443 desde internet)
- [ ] Security Group del ECS Task actualizado (solo acepta del SG del ALB)
- [ ] ALB creado con 2 subnets públicas en AZs diferentes
- [ ] Target Group creado con health check a `/health`
- [ ] Listener HTTP creado (redirige a HTTPS)
- [ ] Listener HTTPS creado (con certificado ACM)
- [ ] ECS Service actualizado con el Target Group
- [ ] Targets en estado `healthy`
- [ ] `curl http://ALB_DNS/health` responde 200

### Certificado SSL
- [ ] Certificado solicitado en ACM con wildcard `*.tudominio.com`
- [ ] Registro CNAME de validación creado en Route 53
- [ ] Estado del certificado: `ISSUED`

### Route 53
- [ ] Hosted Zone creada para `tudominio.com`
- [ ] Nameservers configurados en el registrador del dominio
- [ ] Registro A ALIAS: `api.tudominio.com` → ALB
- [ ] Registro A ALIAS: `app.tudominio.com` → CloudFront (si aplica)
- [ ] `nslookup api.tudominio.com` resuelve correctamente
- [ ] `curl https://api.tudominio.com/health` responde 200

### Backend
- [ ] CORS actualizado con `https://app.tudominio.com`
- [ ] ECS Service redeployado con nuevas variables
- [ ] GitHub Actions actualizado con nueva URL

---

## 🏗️ Arquitectura Final del Proyecto

```
Usuarios
   │
   │  HTTPS
   ▼
Route 53
  api.tudominio.com (ALIAS)
  app.tudominio.com (ALIAS)
   │                    │
   │                    ▼
   │             CloudFront (CDN)
   │                    │
   │                    ▼
   │             S3 (Frontend Angular)
   │
   ▼
Application Load Balancer
  ├── Listener :443 → Target Group → ECS Tasks
  └── Listener :80  → Redirect HTTPS
            │
            │  Health Check /health cada 30s
            ▼
  ECS Fargate (gestion-proyectos-service)
  [Tu API .NET 8 en contenedor Docker]
            │
            ▼
  RDS Aurora PostgreSQL (subnet privada)

SNS Topic → SQS Queue → Lambda → SES Email
     ▲
     │ PublishAsync
     │
  ECS Task (TaskService.cs)
```

---

## 📚 Próximos Pasos

Una vez que tengas ALB + Route 53 funcionando:

1. **Auto Scaling:** Agregar escalado automático basado en CPU del ECS Service
2. **WAF:** Web Application Firewall para proteger el ALB de ataques comunes
3. **VPC Privada:** Mover RDS y ECS Tasks a subnets privadas con NAT Gateway
4. **SES Producción:** Solicitar salida del Sandbox para enviar emails a cualquier destinatario
5. **CloudWatch Dashboard:** Panel unificado con métricas de ALB, ECS, RDS y Lambda

---

**¡Listo! Ahora tienes un ALB con SSL terminado en el edge y Route 53 apuntando tu dominio a él. Tu backend tiene URL estable, HTTPS automático y health checks activos. 🚀**

---

*Proyecto: gestion-proyectos*
*Región: us-east-2*
*Última actualización: Febrero 2026*
