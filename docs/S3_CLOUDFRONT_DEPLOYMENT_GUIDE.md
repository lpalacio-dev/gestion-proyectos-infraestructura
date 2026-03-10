# Guía Completa: Deployment a S3 + CloudFront con GitHub Actions

## 📋 Tabla de Contenidos

1. [Arquitectura del Deployment](#arquitectura)
2. [Preparación de AWS](#preparación-de-aws)
3. [Configuración de S3](#configuración-de-s3)
4. [Configuración de CloudFront](#configuración-de-cloudfront)
5. [Configuración de GitHub Actions](#configuración-de-github-actions)
6. [Primer Deployment](#primer-deployment)
7. [Configuración de Dominios Custom](#dominios-custom)
8. [Troubleshooting](#troubleshooting)
9. [Costos y Optimización](#costos-y-optimización)

---

## 🏗️ Arquitectura

```
┌─────────────┐
│   GitHub    │
│ Repository  │
└──────┬──────┘
       │
       │ Push/PR
       ▼
┌─────────────────┐
│ GitHub Actions  │
│   - Install     │
│   - Build       │
│   - Deploy      │
└──────┬──────────┘
       │
       │ Deploy
       ▼
┌─────────────────┐      ┌──────────────────┐
│   S3 Buckets    │      │   CloudFront     │
│   - Dev         │◄─────┤   Distribution   │
│   - Staging     │      │   (CDN Global)   │
│   - Production  │      └────────┬─────────┘
└─────────────────┘               │
                                  │ HTTPS
                                  ▼
                          ┌──────────────┐
                          │   Usuarios   │
                          └──────────────┘
```

**Ventajas:**
- ✅ Altamente escalable
- ✅ CDN global con baja latencia
- ✅ Bajo costo
- ✅ CI/CD automático
- ✅ Rollback fácil

---

## 🔧 Preparación de AWS

### Paso 1: Crear Usuario IAM

1. **Ir a IAM Console:**
   ```
   https://console.aws.amazon.com/iam/
   ```

2. **Crear nuevo usuario:**
   - Nombre: `github-actions-deployer`
   - Access type: ✅ Programmatic access

3. **Crear política personalizada:**

   Nombre: `GitHubActionsDeployPolicy`

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "S3Access",
         "Effect": "Allow",
         "Action": [
           "s3:PutObject",
           "s3:GetObject",
           "s3:DeleteObject",
           "s3:ListBucket",
           "s3:PutObjectAcl"
         ],
         "Resource": [
           "arn:aws:s3:::gestion-proyectos-*",
           "arn:aws:s3:::gestion-proyectos-*/*"
         ]
       },
       {
         "Sid": "CloudFrontInvalidation",
         "Effect": "Allow",
         "Action": [
           "cloudfront:CreateInvalidation",
           "cloudfront:GetInvalidation",
           "cloudfront:ListInvalidations"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

4. **Adjuntar política al usuario**

5. **Guardar credenciales:**
   ```
   AWS_ACCESS_KEY_ID: AKIA...
   AWS_SECRET_ACCESS_KEY: wJalr...
   ```

   ⚠️ **IMPORTANTE:** Guarda estos valores de forma segura. Solo se muestran una vez.

---

## 📦 Configuración de S3

### Crear Buckets para Cada Ambiente

Vamos a crear 3 buckets (uno por ambiente):

#### 1. Development Bucket

```bash
aws s3 mb s3://gestion-proyectos-dev \
  --region us-east-1
```

**Configurar como sitio web estático:**

```bash
aws s3 website s3://gestion-proyectos-dev \
  --index-document index.html \
  --error-document index.html
```

**Política del bucket (hacer público):**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::gestion-proyectos-dev/*"
    }
  ]
}
```

Aplicar política:

```bash
aws s3api put-bucket-policy \
  --bucket gestion-proyectos-dev \
  --policy file://bucket-policy-dev.json
```

**Deshabilitar "Block all public access":**

```bash
aws s3api put-public-access-block \
  --bucket gestion-proyectos-dev \
  --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
```

#### 2. Staging Bucket

Repetir los mismos pasos pero con:
```bash
Nombre: gestion-proyectos-staging
```

#### 3. Production Bucket

Repetir los mismos pasos pero con:
```bash
Nombre: gestion-proyectos-prod
```

### Configuración de CORS (Opcional)

Si tu backend está en un dominio diferente:

```json
[
  {
    "AllowedHeaders": ["*"],
    "AllowedMethods": ["GET", "HEAD"],
    "AllowedOrigins": ["*"],
    "ExposeHeaders": []
  }
]
```

Aplicar:

```bash
aws s3api put-bucket-cors \
  --bucket gestion-proyectos-dev \
  --cors-configuration file://cors-config.json
```

---

## 🌐 Configuración de CloudFront

### Crear Distribution para Development

1. **Ir a CloudFront Console:**
   ```
   https://console.aws.amazon.com/cloudfront/
   ```

2. **Create Distribution:**

   **Origin settings:**
   - Origin domain: `gestion-proyectos-dev.s3-website-us-east-1.amazonaws.com`
   - Protocol: HTTP only (para S3 website endpoint)
   - Name: `gestion-proyectos-dev`

   **Default cache behavior:**
   - Viewer protocol policy: Redirect HTTP to HTTPS
   - Allowed HTTP methods: GET, HEAD, OPTIONS
   - Cache policy: CachingOptimized
   - Origin request policy: CORS-S3Origin

   **Settings:**
   - Price class: Use all edge locations (best performance)
   - Alternate domain names (CNAMEs): `dev.tu-dominio.com` (opcional)
   - SSL Certificate: Default CloudFront certificate (o custom si tienes dominio)
   - Default root object: `index.html`
   - Standard logging: On (opcional)

3. **Custom error responses (CRÍTICO para Angular):**

   Agregar estas reglas:

   | HTTP Error Code | Error Caching Min TTL | Response Page Path | HTTP Response Code |
   |-----------------|----------------------|-------------------|-------------------|
   | 403 | 0 | /index.html | 200 |
   | 404 | 0 | /index.html | 200 |

   Esto asegura que todas las rutas de Angular funcionen correctamente.

4. **Create Distribution**

5. **Copiar Distribution ID:**
   ```
   Distribution ID: E1234567890ABC
   ```

### Repetir para Staging y Production

Crear distributions separadas para staging y production con los buckets correspondientes.

**IDs de ejemplo:**
```
DEV:        E1234567890ABC
STAGING:    E0987654321XYZ
PRODUCTION: E5555555555555
```

---

## 🔐 Configuración de GitHub Actions

### Paso 1: Agregar Secrets a GitHub

1. **Ir a tu repositorio en GitHub:**
   ```
   Settings > Secrets and variables > Actions
   ```

2. **Agregar los siguientes secrets:**

   | Secret Name | Value | Descripción |
   |-------------|-------|-------------|
   | `AWS_ACCESS_KEY_ID` | `AKIA...` | Access key del usuario IAM |
   | `AWS_SECRET_ACCESS_KEY` | `wJalr...` | Secret key del usuario IAM |
   | `DEV_API_URL` | `http://tu-alb-dev.us-east-1.elb.amazonaws.com/api` | URL del backend dev |
   | `STAGING_API_URL` | `http://tu-alb-staging.us-east-1.elb.amazonaws.com/api` | URL del backend staging |
   | `PROD_API_URL` | `http://tu-alb-prod.us-east-1.elb.amazonaws.com/api` | URL del backend prod |

### Paso 2: Actualizar IDs de CloudFront

En `.github/workflows/deploy-s3.yml`, actualizar los `cloudfront_id`:

```yaml
deploy:
  strategy:
    matrix:
      include:
        - branch: develop
          environment: development
          s3_bucket: gestion-proyectos-dev
          cloudfront_id: E1234567890ABC  # ⬅️ TU ID DE DEV
          
        - branch: staging
          environment: staging
          s3_bucket: gestion-proyectos-staging
          cloudfront_id: E0987654321XYZ  # ⬅️ TU ID DE STAGING
          
        - branch: main
          environment: production
          s3_bucket: gestion-proyectos-prod
          cloudfront_id: E5555555555555  # ⬅️ TU ID DE PROD
```

### Paso 3: Commit y Push

```bash
# Agregar archivos
git add .github/workflows/deploy-s3.yml
git add angular.json
git add package.json
git add src/environments/

# Commit
git commit -m "feat: configurar CI/CD con GitHub Actions para S3 + CloudFront"

# Push a develop para probar
git push origin develop
```

---

## 🚀 Primer Deployment

### Deployment Automático a Development

Cuando hagas push a `develop`:

1. GitHub Actions detecta el push
2. Ejecuta el workflow automáticamente:
   - ✅ Install dependencies
   - ✅ Build con `npm run build:dev`
   - ✅ Deploy a S3 `gestion-proyectos-dev`
   - ✅ Invalida cache de CloudFront
   - ✅ Health check

**Monitorear el deployment:**

1. Ir a: `https://github.com/tu-usuario/tu-repo/actions`
2. Ver el workflow en progreso
3. Revisar logs si hay errores

**Tiempo estimado:** 5-7 minutos

### Deployment Manual a Production

Para deployar a producción:

1. **Via GitHub UI:**
   - Ir a: `Actions > Deploy to AWS S3 + CloudFront`
   - Click en `Run workflow`
   - Seleccionar branch: `main`
   - Seleccionar environment: `production`
   - Click `Run workflow`

2. **Via CLI de GitHub:**
   ```bash
   gh workflow run deploy-s3.yml \
     --ref main \
     --field environment=production
   ```

### Verificar Deployment

**URLs de CloudFront:**

```bash
# Development
https://d1234567890abc.cloudfront.net

# Staging
https://d0987654321xyz.cloudfront.net

# Production
https://d5555555555555.cloudfront.net
```

**Verificar contenido:**

```bash
# Dev
curl -I https://d1234567890abc.cloudfront.net

# Production
curl -I https://d5555555555555.cloudfront.net
```

---

## 🌍 Dominios Custom

### Opción 1: Dominio en Route 53

Si tu dominio está en Route 53:

1. **Solicitar certificado SSL en ACM:**

   ```bash
   aws acm request-certificate \
     --domain-name *.tu-dominio.com \
     --subject-alternative-names tu-dominio.com \
     --validation-method DNS \
     --region us-east-1
   ```

   ⚠️ **Debe ser en us-east-1 para CloudFront**

2. **Validar certificado:**

   AWS te dará registros DNS para agregar. Agrégalos en Route 53.

3. **Agregar dominio a CloudFront:**

   - Edit Distribution
   - Alternate domain names (CNAMEs): `app.tu-dominio.com`
   - Custom SSL certificate: Seleccionar el certificado de ACM
   - Save changes

4. **Crear registro en Route 53:**

   ```bash
   # Crear alias record
   aws route53 change-resource-record-sets \
     --hosted-zone-id Z1234567890ABC \
     --change-batch file://route53-record.json
   ```

   `route53-record.json`:
   ```json
   {
     "Changes": [
       {
         "Action": "CREATE",
         "ResourceRecordSet": {
           "Name": "app.tu-dominio.com",
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
   ```

### Opción 2: Dominio Externo

Si tu dominio está en otro registrar:

1. Seguir pasos 1-3 de la Opción 1
2. Crear registro CNAME en tu registrar:
   ```
   Nombre: app
   Tipo: CNAME
   Valor: d5555555555555.cloudfront.net
   TTL: 300
   ```

**Configuración por ambiente:**

```
dev.tu-dominio.com      → d1234567890abc.cloudfront.net
staging.tu-dominio.com  → d0987654321xyz.cloudfront.net
app.tu-dominio.com      → d5555555555555.cloudfront.net
```

---

## 🔧 Troubleshooting

### Problema 1: Build falla en GitHub Actions

**Error:** `npm ERR! missing script: build:dev`

**Solución:**
```bash
# Verificar que package.json tiene los scripts
cat package.json | grep "build:dev"

# Si no existe, agregarlo
"scripts": {
  "build:dev": "ng build --configuration=development",
  "build:staging": "ng build --configuration=staging",
  "build:prod": "ng build --configuration=production"
}
```

### Problema 2: S3 sync falla

**Error:** `An error occurred (AccessDenied) when calling the PutObject operation`

**Solución:**
1. Verificar que las credenciales de AWS están correctas en GitHub Secrets
2. Verificar que el usuario IAM tiene permisos de `s3:PutObject`
3. Verificar que el nombre del bucket es correcto

### Problema 3: CloudFront invalidation falla

**Error:** `An error occurred (NoSuchDistribution)`

**Solución:**
- Verificar que el Distribution ID es correcto
- Verificar que el usuario IAM tiene permisos de `cloudfront:CreateInvalidation`

### Problema 4: Rutas de Angular retornan 404

**Causa:** CloudFront no está configurado para redirigir errores a index.html

**Solución:**
1. Ir a CloudFront Console
2. Edit Distribution
3. Error Pages > Create Custom Error Response:
   - HTTP Error Code: 404
   - Customize Error Response: Yes
   - Response Page Path: /index.html
   - HTTP Response Code: 200
4. Repetir para 403

### Problema 5: Cambios no se reflejan

**Causa:** Cache de CloudFront no invalidado

**Solución:**
```bash
# Invalidar manualmente
aws cloudfront create-invalidation \
  --distribution-id E5555555555555 \
  --paths "/*"
```

### Problema 6: CORS errors

**Causa:** Backend no permite el origen de CloudFront

**Solución:**

Actualizar CORS en backend:

```csharp
builder.Services.AddCors(options =>
{
    options.AddPolicy("CloudFrontOrigins", app =>
    {
        app.WithOrigins(
            "https://d5555555555555.cloudfront.net",
            "https://app.tu-dominio.com"
        )
        .AllowAnyHeader()
        .AllowAnyMethod()
        .AllowCredentials();
    });
});
```

---

## 💰 Costos y Optimización

### Estimación de Costos Mensuales

**Para una app pequeña-mediana:**

```
S3 Storage (3 buckets):
- Storage: 500 MB × 3 = 1.5 GB
- Costo: 1.5 GB × $0.023/GB = $0.03/mes

S3 Requests:
- PUT/COPY/POST: 1,000 requests
- GET: 10,000 requests
- Costo: ~$0.01/mes

CloudFront (3 distributions):
- Data transfer: 10 GB/mes × 3 = 30 GB
- Requests: 100,000 × 3 = 300,000
- Costo: ~$3-5/mes

Route 53 (si usas):
- Hosted zone: $0.50/mes
- Queries: 1M queries = $0.40/mes
- Costo: ~$0.90/mes

TOTAL ESTIMADO: $4-7 USD/mes
```

**Free Tier de AWS:**
- S3: 5 GB storage, 20,000 GET, 2,000 PUT
- CloudFront: 1 TB data transfer, 10M requests
- **Durante el primer año: ¡Prácticamente gratis!**

### Optimizaciones de Costos

#### 1. Comprimir Assets

En `angular.json`:

```json
"optimization": {
  "scripts": true,
  "styles": {
    "minify": true,
    "inlineCritical": true
  },
  "fonts": true
}
```

#### 2. Lazy Loading

```typescript
const routes: Routes = [
  {
    path: 'projects',
    loadComponent: () => import('./features/projects/project-list.component')
  }
];
```

#### 3. Configurar Cache Headers

En S3 sync:

```bash
# Assets con cache largo
aws s3 sync dist/ s3://bucket/ \
  --exclude "*.html" \
  --cache-control "public, max-age=31536000, immutable"

# HTML sin cache
aws s3 sync dist/ s3://bucket/ \
  --exclude "*" \
  --include "*.html" \
  --cache-control "no-cache, no-store, must-revalidate"
```

#### 4. CloudFront Compression

En CloudFront settings:
- Compress objects automatically: ✅ Yes

Esto reduce ~70% el tamaño de transfers.

#### 5. Lifecycle Policies en S3

Para logs y versiones antiguas:

```json
{
  "Rules": [
    {
      "Id": "DeleteOldVersions",
      "Status": "Enabled",
      "NoncurrentVersionExpiration": {
        "NoncurrentDays": 30
      }
    }
  ]
}
```

---

## 📊 Monitoreo

### CloudWatch Metrics

**CloudFront:**
- Requests
- Bytes downloaded
- Error rate
- Cache hit rate

**S3:**
- BucketSizeBytes
- NumberOfObjects
- AllRequests

### Configurar Alarmas

```bash
# Alarma de error rate alto
aws cloudwatch put-metric-alarm \
  --alarm-name cloudfront-high-error-rate \
  --alarm-description "CloudFront error rate > 5%" \
  --metric-name 4xxErrorRate \
  --namespace AWS/CloudFront \
  --statistic Average \
  --period 300 \
  --threshold 5 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2
```

### Logs

**CloudFront Access Logs:**

1. Crear bucket para logs: `gestion-proyectos-logs`
2. En CloudFront Distribution settings:
   - Standard logging: On
   - S3 bucket: `gestion-proyectos-logs`
   - Log prefix: `cloudfront/`

**Analizar logs con Athena:**

```sql
CREATE EXTERNAL TABLE cloudfront_logs (
  `date` DATE,
  time STRING,
  location STRING,
  bytes BIGINT,
  request_ip STRING,
  method STRING,
  host STRING,
  uri STRING,
  status INT,
  referrer STRING,
  user_agent STRING
)
ROW FORMAT DELIMITED 
FIELDS TERMINATED BY '\t'
LOCATION 's3://gestion-proyectos-logs/cloudfront/'
```

---

## ✅ Checklist Final

Antes de considerar el deployment completo:

### AWS Setup
- [ ] Usuario IAM creado con permisos mínimos
- [ ] 3 buckets S3 creados (dev, staging, prod)
- [ ] Buckets configurados como static website
- [ ] 3 CloudFront distributions creadas
- [ ] Custom error responses configuradas (403/404 → 200)
- [ ] Certificados SSL configurados (si usas dominio custom)

### GitHub Setup
- [ ] Secrets configurados (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
- [ ] API URLs configuradas (DEV_API_URL, STAGING_API_URL, PROD_API_URL)
- [ ] Workflow `.github/workflows/deploy-s3.yml` commiteado
- [ ] CloudFront IDs actualizados en workflow

### Código
- [ ] Scripts de build en package.json
- [ ] Configuraciones de ambiente en angular.json
- [ ] Archivos de environment creados (development, staging, production)
- [ ] Script replace-env.sh con permisos de ejecución

### Testing
- [ ] Push a develop funciona y despliega
- [ ] Build artifacts correctos en S3
- [ ] CloudFront invalida cache correctamente
- [ ] Rutas de Angular funcionan correctamente
- [ ] API calls funcionan (CORS configurado)
- [ ] Health check pasa

### Performance
- [ ] Compression habilitada en CloudFront
- [ ] Cache headers configurados correctamente
- [ ] Lazy loading implementado
- [ ] Bundle size < 1MB

### Seguridad
- [ ] HTTPS forzado (redirect HTTP → HTTPS)
- [ ] Bucket policies correctas
- [ ] CORS configurado apropiadamente
- [ ] Credenciales como secrets, no en código

---

## 📚 Recursos Adicionales

### Documentación Oficial
- [S3 Static Website Hosting](https://docs.aws.amazon.com/AmazonS3/latest/userguide/WebsiteHosting.html)
- [CloudFront Developer Guide](https://docs.aws.amazon.com/cloudfront/latest/DeveloperGuide/)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)

### Tutoriales
- [Angular Deployment](https://angular.dev/tools/cli/deployment)
- [AWS CLI Reference](https://awscli.amazonaws.com/v2/documentation/api/latest/reference/index.html)

### Herramientas
- [AWS Cost Calculator](https://calculator.aws/)
- [CloudFront Invalidation Tool](https://github.com/simoneb/cloudfront-invalidation-action)

---

## 🎉 ¡Deployment Completado!

Tu aplicación Angular ahora está:

✅ Desplegada en S3 + CloudFront  
✅ Con CI/CD automático via GitHub Actions  
✅ Servida globalmente con baja latencia  
✅ Con HTTPS habilitado  
✅ Con rollback fácil  
✅ Con múltiples ambientes (dev/staging/prod)  

**URLs de acceso:**
- Development: `https://d1234567890abc.cloudfront.net`
- Staging: `https://d0987654321xyz.cloudfront.net`
- Production: `https://d5555555555555.cloudfront.net`

**Costo estimado:** $4-7 USD/mes (o gratis con Free Tier)

---

*Última actualización: Febrero 2026*
*Versión: 1.0*
