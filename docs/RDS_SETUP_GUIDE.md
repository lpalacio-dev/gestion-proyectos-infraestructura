# 🗄️ Guía Completa: Amazon RDS PostgreSQL para Gestión de Proyectos

## 📋 Índice
1. [Conceptos Clave](#conceptos-clave)
2. [Arquitectura de la Solución](#arquitectura-de-la-solución)
3. [Configuración Paso a Paso](#configuración-paso-a-paso)
4. [Conexión desde ECS](#conexión-desde-ecs)
5. [Backups y Recuperación](#backups-y-recuperación)
6. [Monitoreo](#monitoreo)
7. [Optimización de Costos](#optimización-de-costos)
8. [Troubleshooting](#troubleshooting)

---

## 1️⃣ Conceptos Clave

### **RDS vs PostgreSQL Self-Hosted**

| Aspecto | PostgreSQL en EC2/Local | Amazon RDS PostgreSQL |
|---------|------------------------|----------------------|
| **Administración** | Manual (actualizaciones, backups) | Automática |
| **Backups** | Debes configurarlos | Automáticos |
| **Alta Disponibilidad** | Requiere configuración compleja | Multi-AZ con un click |
| **Escalabilidad** | Downtime requerido | Escalado vertical con downtime mínimo |
| **Monitoreo** | CloudWatch + herramientas custom | CloudWatch integrado |
| **Costo** | EC2 instance + storage | Más caro pero incluye gestión |

---

### **DB Instance vs DB Cluster**

#### **DB Instance (Lo que usaremos):**
- ✅ Servidor PostgreSQL individual
- ✅ Multi-AZ opcional (replica síncrona en otra zona)
- ✅ Ideal para apps pequeñas-medianas
- ✅ Menor costo

#### **DB Cluster (Aurora PostgreSQL):**
- 🚀 Compatible con PostgreSQL pero engine diferente
- 🚀 Múltiples read replicas automáticas
- 🚀 Escalado automático
- 💰 Más caro (~20% más)
- ⚠️ No necesario para tu proyecto ahora

**Decisión: Usaremos DB Instance con PostgreSQL estándar.**

---

### **Storage Types**

| Tipo | IOPS | Throughput | Costo | Uso Recomendado |
|------|------|------------|-------|-----------------|
| **gp2** | 3 IOPS/GB (max 16,000) | Hasta 250 MB/s | $ | Legacy (no recomendado) |
| **gp3** | 3,000 IOPS base | 125 MB/s base | $ | ✅ **Usar este** |
| **io1** | Hasta 64,000 IOPS | Hasta 1,000 MB/s | $$$ | Apps críticas |

**Decisión: gp3 ofrece mejor performance por el mismo precio que gp2.**

---

### **Backup Retention**

- **Backups automáticos:** Snapshots diarios durante ventana de mantenimiento
- **Retention period:** 1-35 días (7 días recomendado para dev)
- **Point-in-time recovery:** Restaurar a cualquier segundo dentro del retention period
- **Costo:** Gratis hasta el tamaño de tu DB

---

### **Parameter Groups**

Configuraciones del engine PostgreSQL:
- **max_connections:** Número máximo de conexiones
- **shared_buffers:** Memoria para cache
- **work_mem:** Memoria por operación de sort
- **maintenance_work_mem:** Memoria para VACUUM, CREATE INDEX

**Para dev:** El parameter group por defecto funciona bien.

---

## 2️⃣ Arquitectura de la Solución

```
┌─────────────────────────────────────────────────────────────┐
│                         INTERNET                            │
└──────────────────────────┬──────────────────────────────────┘
                           │
                    ┌──────▼──────┐
                    │   ALB/IP    │ (Opcional - futuro)
                    │   Pública   │
                    └──────┬──────┘
                           │
┌──────────────────────────┴──────────────────────────────────┐
│                    VPC (10.0.0.0/16)                        │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Public Subnet (10.0.1.0/24) - us-east-2a          │   │
│  │                                                      │   │
│  │    ┌──────────────────┐                            │   │
│  │    │   ECS Fargate    │                            │   │
│  │    │   Task (Backend) │◄────┐                      │   │
│  │    │   Port: 8080     │     │                      │   │
│  │    └──────────────────┘     │                      │   │
│  └─────────────────────────────┼──────────────────────┘   │
│                                  │                          │
│  ┌─────────────────────────────┼──────────────────────┐   │
│  │  Public Subnet (10.0.2.0/24) - us-east-2b          │   │
│  │                               │                      │   │
│  │                               │                      │   │
│  │                               │                      │   │
│  └─────────────────────────────┼──────────────────────┘   │
│                                  │                          │
│                                  │ PostgreSQL Protocol      │
│                                  │ Port: 5432               │
│  ┌─────────────────────────────┼──────────────────────┐   │
│  │  Private Subnet (10.0.3.0/24) - us-east-2a         │   │
│  │                               │                      │   │
│  │    ┌──────────────────┐      │                      │   │
│  │    │   RDS PostgreSQL │◄─────┘                      │   │
│  │    │   db.t3.micro    │                             │   │
│  │    │   Port: 5432     │                             │   │
│  │    └──────────────────┘                             │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  Security Groups:                                           │
│  ┌────────────────────┐  ┌──────────────────────────┐      │
│  │ ECS Task SG        │  │ RDS SG                   │      │
│  │ Inbound: 8080 (0.0)│  │ Inbound: 5432 (ECS SG)   │      │
│  │ Outbound: All      │  │ Outbound: None           │      │
│  └────────────────────┘  └──────────────────────────┘      │
└──────────────────────────────────────────────────────────────┘
```

**Clave:**
- ✅ ECS en subnets públicas (necesita Internet para ECR)
- ✅ RDS en subnet privada (no accesible desde Internet)
- ✅ Security Group de RDS solo acepta tráfico desde ECS

---

## 3️⃣ Configuración Paso a Paso

### **PASO 1: Crear Subnet Privada para RDS**

#### **Por CLI:**
```bash
# Variables
VPC_ID="vpc-xxxxx"  # Tu VPC ID
REGION="us-east-2"

# Crear Private Subnet en AZ A
PRIVATE_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.3.0/24 \
  --availability-zone us-east-2a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=gestion-proyectos-private-a}]' \
  --query 'Subnet.SubnetId' \
  --output text)

echo "Private Subnet A: $PRIVATE_SUBNET_A"

# Crear Private Subnet en AZ B (para Multi-AZ)
PRIVATE_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.4.0/24 \
  --availability-zone us-east-2b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=gestion-proyectos-private-b}]' \
  --query 'Subnet.SubnetId' \
  --output text)

echo "Private Subnet B: $PRIVATE_SUBNET_B"
```

#### **Por Consola:**
1. EC2 → VPC → Subnets → Create subnet
2. VPC: Selecciona tu VPC
3. Subnet settings:
   - Subnet name: `gestion-proyectos-private-a`
   - Availability Zone: `us-east-2a`
   - IPv4 CIDR block: `10.0.3.0/24`
4. Create subnet
5. Repetir para AZ B con CIDR `10.0.4.0/24`

---

### **PASO 2: Crear DB Subnet Group**

#### **Por CLI:**
```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name gestion-proyectos-db-subnet-group \
  --db-subnet-group-description "Subnet group for gestion-proyectos RDS" \
  --subnet-ids $PRIVATE_SUBNET_A $PRIVATE_SUBNET_B \
  --tags Key=Name,Value=gestion-proyectos-db-subnet-group
```

#### **Por Consola:**
1. RDS → Subnet groups → Create DB subnet group
2. Name: `gestion-proyectos-db-subnet-group`
3. Description: `Subnet group for gestion-proyectos RDS`
4. VPC: Selecciona tu VPC
5. Add subnets:
   - us-east-2a → Selecciona la subnet privada 10.0.3.0/24
   - us-east-2b → Selecciona la subnet privada 10.0.4.0/24
6. Create

---

### **PASO 3: Crear Security Group para RDS**

#### **Por CLI:**
```bash
# Crear Security Group
RDS_SG_ID=$(aws ec2 create-security-group \
  --group-name gestion-proyectos-rds-sg \
  --description "Security group for RDS PostgreSQL" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)

echo "RDS Security Group: $RDS_SG_ID"

# Obtener el SG ID de ECS (el que creaste antes)
ECS_SG_ID="sg-xxxxx"  # Reemplaza con tu ECS Security Group ID

# Permitir tráfico PostgreSQL solo desde ECS
aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG_ID \
  --protocol tcp \
  --port 5432 \
  --source-group $ECS_SG_ID
```

#### **Por Consola:**
1. EC2 → Security Groups → Create security group
2. Basic details:
   - Security group name: `gestion-proyectos-rds-sg`
   - Description: `Security group for RDS PostgreSQL`
   - VPC: Tu VPC
3. Inbound rules → Add rule:
   - Type: PostgreSQL
   - Protocol: TCP
   - Port: 5432
   - Source: Custom
   - Search y selecciona: `gestion-proyectos-sg` (el SG de ECS)
   - Description: `Allow PostgreSQL from ECS tasks`
4. Outbound rules: Dejar vacío (no necesita salir)
5. Create security group

---

### **PASO 4: Crear RDS Instance**

#### **Por CLI:**
```bash
# Generar password seguro
DB_PASSWORD=$(openssl rand -base64 24)
echo "DB Password (SAVE THIS): $DB_PASSWORD"

# Crear RDS instance
aws rds create-db-instance \
  --db-instance-identifier gestion-proyectos-db \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 16.3 \
  --master-username dbadmin \
  --master-user-password "$DB_PASSWORD" \
  --allocated-storage 20 \
  --storage-type gp3 \
  --storage-encrypted \
  --db-subnet-group-name gestion-proyectos-db-subnet-group \
  --vpc-security-group-ids $RDS_SG_ID \
  --backup-retention-period 7 \
  --preferred-backup-window "03:00-04:00" \
  --preferred-maintenance-window "mon:04:00-mon:05:00" \
  --publicly-accessible false \
  --enable-cloudwatch-logs-exports '["postgresql"]' \
  --tags Key=Name,Value=gestion-proyectos-db Key=Environment,Value=dev
```

#### **Por Consola (RECOMENDADO - más fácil):**

**1. Ir a RDS:**
- RDS → Databases → Create database

**2. Engine options:**
- Engine type: **PostgreSQL**
- Engine Version: **PostgreSQL 16.3-R2** (o la última disponible)
- Templates: **Free tier** (si está disponible) o **Dev/Test**

**3. Settings:**
- DB instance identifier: `gestion-proyectos-db`
- Master username: `dbadmin`
- Master password: (Genera uno seguro)
- Confirm password: (Repite)
- ⚠️ **GUARDA ESTE PASSWORD EN UN LUGAR SEGURO**

**4. Instance configuration:**
- DB instance class: **Burstable classes** → **db.t3.micro**
  - vCPUs: 2
  - RAM: 1 GB
  - ✅ Incluido en Free Tier (750 horas/mes primer año)

**5. Storage:**
- Storage type: **General Purpose SSD (gp3)**
- Allocated storage: **20 GiB**
- ☑️ Enable storage autoscaling (opcional)
  - Maximum storage threshold: 100 GiB
- ☑️ Storage encryption: **Enable encryption**

**6. Connectivity:**
- Compute resource: **Don't connect to an EC2 compute resource**
- Network type: **IPv4**
- Virtual private cloud (VPC): Selecciona tu VPC
- DB subnet group: `gestion-proyectos-db-subnet-group`
- Public access: **No** ⚠️ IMPORTANTE
- VPC security group: **Choose existing**
  - Selecciona: `gestion-proyectos-rds-sg`
  - Deselecciona: default
- Availability Zone: No preference
- Certificate authority: **Default (rds-ca-rsa2048-g1)**

**7. Database authentication:**
- Database authentication options: **Password authentication**

**8. Monitoring:**
- ☑️ Enable Enhanced monitoring
  - Granularity: 60 seconds
  - Monitoring Role: Default

**9. Additional configuration:**
- Initial database name: `gestion_proyectos` ⚠️ IMPORTANTE
- DB parameter group: default.postgres16
- Option group: default:postgres-16
- Backup:
  - ☑️ Enable automated backups
  - Backup retention period: **7 days**
  - Backup window: **03:00-04:00 UTC** (choose a time)
- Encryption: (Ya configurado en Storage)
- Log exports:
  - ☑️ PostgreSQL log
- Maintenance:
  - ☑️ Enable auto minor version upgrade
  - Maintenance window: **mon:04:00-mon:05:00 UTC**
- Deletion protection: **☐ Deshabilitado** (para dev)

**10. Estimated monthly costs:**
- Verifica que muestre "Eligible for RDS Free Usage Tier"

**11. Create database**
- Click **Create database**
- ⏱️ Espera 5-10 minutos mientras se crea

---

### **PASO 5: Esperar a que esté disponible**

```bash
# Por CLI - Monitorear status
aws rds describe-db-instances \
  --db-instance-identifier gestion-proyectos-db \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text

# Esperar hasta que muestre: "available"
```

**Por Consola:**
- RDS → Databases → gestion-proyectos-db
- Status debe cambiar de "Creating" → "Available" (5-10 min)

---

### **PASO 6: Obtener el Endpoint**

```bash
# Por CLI
DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier gestion-proyectos-db \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

echo "RDS Endpoint: $DB_ENDPOINT"
```

**Por Consola:**
- RDS → Databases → gestion-proyectos-db
- Connectivity & security tab
- Endpoint: `gestion-proyectos-db.xxxxxxxxx.us-east-2.rds.amazonaws.com`
- Port: `5432`

**⚠️ COPIA ESTE ENDPOINT - LO NECESITARÁS**

---

### **PASO 7: Actualizar Secret en Secrets Manager**

#### **Construir el Connection String:**
```
Host=gestion-proyectos-db.xxxxxxxxx.us-east-2.rds.amazonaws.com;Port=5432;Database=gestion_proyectos;Username=dbadmin;Password=TU_PASSWORD_AQUI;SSL Mode=Require
```

#### **Actualizar Secret:**

```bash
# Por CLI
aws secretsmanager update-secret \
  --secret-id db-connection-string \
  --secret-string "Host=gestion-proyectos-db.xxxxxxxxx.us-east-2.rds.amazonaws.com;Port=5432;Database=gestion_proyectos;Username=dbadmin;Password=TU_PASSWORD;SSL Mode=Require" \
  --region us-east-2
```

**Por Consola:**
1. Secrets Manager → Secrets → db-connection-string
2. Retrieve secret value → Edit
3. Plaintext tab
4. Pega el nuevo connection string
5. Save

---

## 4️⃣ Conexión desde ECS

### **PASO 8: Aplicar Migraciones de Entity Framework**

Como no te interesan los datos actuales, solo necesitamos crear el schema nuevo.

#### **Opción 1: Desde tu máquina local (RECOMENDADO para primera vez)**

**A. Crear un Security Group temporal:**
```bash
# Crear SG temporal para tu IP
TEMP_SG_ID=$(aws ec2 create-security-group \
  --group-name temp-rds-access \
  --description "Temporary access to RDS for migrations" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)

# Obtener tu IP pública
MY_IP=$(curl -s https://checkip.amazonaws.com)

# Permitir acceso PostgreSQL desde tu IP
aws ec2 authorize-security-group-ingress \
  --group-id $TEMP_SG_ID \
  --protocol tcp \
  --port 5432 \
  --cidr ${MY_IP}/32
```

**B. Agregar SG temporal a RDS:**
```bash
aws rds modify-db-instance \
  --db-instance-identifier gestion-proyectos-db \
  --vpc-security-group-ids $RDS_SG_ID $TEMP_SG_ID \
  --apply-immediately
```

**C. Actualizar appsettings.json local:**
```json
{
  "ConnectionStrings": {
    "PostgreSQLConnection": "Host=gestion-proyectos-db.xxxxxxxxx.us-east-2.rds.amazonaws.com;Port=5432;Database=gestion_proyectos;Username=dbadmin;Password=TU_PASSWORD;SSL Mode=Require"
  }
}
```

**D. Ejecutar migraciones:**
```bash
# Desde la raíz de tu proyecto .NET
dotnet ef database update
```

**E. Verificar que funcionó:**
```bash
# Conectar con psql
psql "host=gestion-proyectos-db.xxxxxxxxx.us-east-2.rds.amazonaws.com port=5432 dbname=gestion_proyectos user=dbadmin sslmode=require"

# Ver tablas
\dt

# Deberías ver:
# Projects, Tasks, ProjectMembers, AspNetUsers, etc.
```

**F. Eliminar SG temporal:**
```bash
# Remover de RDS
aws rds modify-db-instance \
  --db-instance-identifier gestion-proyectos-db \
  --vpc-security-group-ids $RDS_SG_ID \
  --apply-immediately

# Esperar 1 minuto

# Eliminar SG
aws ec2 delete-security-group --group-id $TEMP_SG_ID
```

---

#### **Opción 2: Desde ECS (Más complejo pero más seguro)**

**Modificar Dockerfile para incluir herramienta de migración:**

```dockerfile
# Agregar después del ENTRYPOINT
# Este será el entrypoint que ejecuta migraciones antes de arrancar
COPY entrypoint.sh /app/
RUN chmod +x /app/entrypoint.sh
ENTRYPOINT ["/app/entrypoint.sh"]
```

**Crear entrypoint.sh:**
```bash
#!/bin/bash
set -e

# Esperar a que PostgreSQL esté disponible
echo "Waiting for PostgreSQL..."
until dotnet gestion-de-proyectos.dll --check-db 2>/dev/null; do
  echo "PostgreSQL is unavailable - sleeping"
  sleep 2
done

echo "PostgreSQL is up - executing migrations"
dotnet ef database update

echo "Starting application..."
exec dotnet gestion-de-proyectos.dll
```

---

### **PASO 9: Actualizar Task Definition con nuevo Secret**

Tu Task Definition ya debería estar configurada para leer desde Secrets Manager:

```json
"secrets": [
  {
    "name": "ConnectionStrings__PostgreSQLConnection",
    "valueFrom": "arn:aws:secretsmanager:us-east-2:ACCOUNT_ID:secret:db-connection-string-XXXXX"
  }
]
```

**Esto ya lo tienes configurado, solo actualizaste el valor del secret.**

---

### **PASO 10: Forzar nuevo deployment**

```bash
# Por CLI
aws ecs update-service \
  --cluster gestion-proyectos-cluster \
  --service gestion-proyectos-service \
  --force-new-deployment \
  --region us-east-2
```

**Por Consola:**
1. ECS → Clusters → gestion-proyectos-cluster
2. Services → gestion-proyectos-service
3. Update service
4. Force new deployment: ✅
5. Update

---

### **PASO 11: Verificar conexión desde ECS**

```bash
# Ver logs de CloudWatch
aws logs tail /ecs/gestion-proyectos --follow

# Deberías ver:
# "Application started"
# "Connection to PostgreSQL established"
# Sin errores de conexión
```

---

## 5️⃣ Backups y Recuperación

### **Backups Automáticos (Ya configurados)**

```bash
# Ver backups disponibles
aws rds describe-db-snapshots \
  --db-instance-identifier gestion-proyectos-db
```

---

### **Crear Backup Manual**

```bash
# Por CLI
aws rds create-db-snapshot \
  --db-instance-identifier gestion-proyectos-db \
  --db-snapshot-identifier gestion-proyectos-manual-$(date +%Y%m%d-%H%M%S)
```

**Por Consola:**
1. RDS → Databases → gestion-proyectos-db
2. Actions → Take snapshot
3. Snapshot name: `gestion-proyectos-manual-YYYYMMDD`
4. Take snapshot

---

### **Restaurar desde Snapshot**

```bash
# Por CLI
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier gestion-proyectos-db-restored \
  --db-snapshot-identifier gestion-proyectos-manual-20241205 \
  --db-subnet-group-name gestion-proyectos-db-subnet-group \
  --vpc-security-group-ids $RDS_SG_ID
```

---

### **Point-in-Time Recovery**

```bash
# Restaurar a un momento específico
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier gestion-proyectos-db \
  --target-db-instance-identifier gestion-proyectos-db-restored \
  --restore-time 2024-12-05T10:30:00Z \
  --db-subnet-group-name gestion-proyectos-db-subnet-group \
  --vpc-security-group-ids $RDS_SG_ID
```

---

## 6️⃣ Monitoreo

### **Métricas Clave en CloudWatch**

```bash
# Ver CPU utilization
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=gestion-proyectos-db \
  --start-time 2024-12-05T00:00:00Z \
  --end-time 2024-12-05T23:59:59Z \
  --period 300 \
  --statistics Average
```

**Métricas importantes:**
- `CPUUtilization`: Uso de CPU (< 80%)
- `DatabaseConnections`: Número de conexiones activas
- `FreeableMemory`: Memoria libre disponible
- `FreeStorageSpace`: Espacio de almacenamiento libre
- `ReadLatency` / `WriteLatency`: Latencia de I/O

---

### **Configurar Alarmas**

```bash
# Alarma de CPU alta
aws cloudwatch put-metric-alarm \
  --alarm-name rds-high-cpu \
  --alarm-description "Alert when RDS CPU exceeds 80%" \
  --metric-name CPUUtilization \
  --namespace AWS/RDS \
  --statistic Average \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=DBInstanceIdentifier,Value=gestion-proyectos-db
```

---

## 7️⃣ Optimización de Costos

### **Costos Estimados (Free Tier - Primer Año)**

| Recurso | Especificación | Costo Mensual | Free Tier |
|---------|---------------|---------------|-----------|
| RDS Instance | db.t3.micro | $0 | 750 horas/mes |
| Storage | 20 GB gp3 | $0 | 20 GB |
| Backups | 20 GB | $0 | = tamaño DB |
| **Total** | | **$0** | ✅ Primer año |

### **Después del Free Tier:**

| Recurso | Costo Mensual |
|---------|---------------|
| db.t3.micro (730h) | ~$13 |
| Storage 20GB gp3 | ~$2.30 |
| Backups 20GB | ~$2 |
| **Total** | **~$17.30/mes** |

---

### **Estrategias para Ahorrar:**

#### **1. Apagar RDS cuando no lo uses:**
```bash
# Detener instance (solo se guarda el storage)
aws rds stop-db-instance --db-instance-identifier gestion-proyectos-db

# Iniciar instance
aws rds start-db-instance --db-instance-identifier gestion-proyectos-db
```

**Ahorro:** ~$13/mes cuando está detenido (solo pagas storage)

⚠️ **RDS se reinicia automáticamente después de 7 días detenido.**

---

#### **2. Usar Dev/Test pricing (solo para desarrollo):**
Ya incluido si seleccionaste "Dev/Test" en template.

---

#### **3. Reserved Instances (para producción):**
- Compromiso de 1-3 años
- Ahorro de hasta 60%
- No recomendado para aprendizaje

---

## 8️⃣ Troubleshooting

### **Problema 1: No puedo conectar desde ECS**

**Síntoma:**
```
Connection to PostgreSQL failed: could not connect to server
```

**Diagnóstico:**
```bash
# Verificar Security Group
aws ec2 describe-security-groups --group-ids $RDS_SG_ID

# Verificar que ECS SG esté en las reglas de ingress
```

**Solución:**
Asegurar que el Security Group de RDS permite tráfico en puerto 5432 desde el SG de ECS.

---

### **Problema 2: Connection timeout**

**Síntoma:**
```
Timeout expired. The timeout period elapsed prior to completion of the operation
```

**Causas posibles:**
1. RDS en subnet pública sin route a Internet Gateway
2. Security Group bloqueando tráfico
3. Subnet Group incorrecto

**Solución:**
```bash
# Verificar que RDS está en subnet privada
aws rds describe-db-instances \
  --db-instance-identifier gestion-proyectos-db \
  --query 'DBInstances[0].DBSubnetGroup.Subnets[*].[SubnetIdentifier,SubnetAvailabilityZone.Name]'
```

---

### **Problema 3: Password authentication failed**

**Síntoma:**
```
password authentication failed for user "dbadmin"
```

**Solución:**
```bash
# Resetear master password
aws rds modify-db-instance \
  --db-instance-identifier gestion-proyectos-db \
  --master-user-password "NuevoPasswordSeguro123!" \
  --apply-immediately

# Actualizar secret en Secrets Manager
aws secretsmanager update-secret \
  --secret-id db-connection-string \
  --secret-string "Host=...;Password=NuevoPasswordSeguro123!;..."
```

---

### **Problema 4: SSL connection required**

**Síntoma:**
```
The server does not support SSL connections
```

**Solución:**
Agregar `SSL Mode=Require` al connection string:
```
Host=...;SSL Mode=Require
```

---

## 📊 Checklist Final

Antes de dar por terminado:

### **Infraestructura:**
- [ ] Subnets privadas creadas en 2 AZs
- [ ] DB Subnet Group configurado
- [ ] Security Group de RDS permite tráfico desde ECS
- [ ] RDS Instance creado y en estado "Available"

### **Base de Datos:**
- [ ] Database `gestion_proyectos` existe
- [ ] Migraciones de EF Core ejecutadas
- [ ] Tablas creadas correctamente (AspNetUsers, Projects, Tasks, etc.)
- [ ] Usuario admin creado (si aplicaste seed data)

### **Conexión:**
- [ ] Connection string actualizado en Secrets Manager
- [ ] ECS puede conectarse a RDS
- [ ] Logs muestran conexión exitosa
- [ ] No hay errores de autenticación

### **Backups:**
- [ ] Automated backups habilitados (7 días)
- [ ] Backup window configurado
- [ ] Al menos un snapshot manual creado

### **Seguridad:**
- [ ] RDS en subnet privada (no accesible desde Internet)
- [ ] Publicly accessible = No
- [ ] Storage encryption habilitado
- [ ] SSL/TLS requerido en connection string

### **Monitoreo:**
- [ ] CloudWatch Logs habilitados
- [ ] Enhanced monitoring activo
- [ ] Al menos una alarma configurada (CPU alta)

### **Costos:**
- [ ] Verificado que está en Free Tier
- [ ] Deletion protection deshabilitado (para dev)
- [ ] Auto minor version upgrade habilitado

---

## 🎯 Próximos Pasos

Una vez completado esto:

1. **Probar la aplicación end-to-end:**
   - Registro de usuario
   - Crear proyecto
   - Agregar tareas
   - Invitar miembros

2. **Configurar monitoreo avanzado:**
   - Performance Insights (opcional, tiene costo)
   - Slow query log
   - Connection pooling metrics

3. **Optimizar queries:**
   - Revisar índices en tablas
   - Agregar índices faltantes si es necesario

4. **Siguiente fase del aprendizaje:**
   - Application Load Balancer (ALB)
   - Route 53 para dominio personalizado
   - ACM para certificado SSL
   - CloudFront para CDN

---

## 📚 Comandos de Referencia Rápida

```bash
# Ver estado de RDS
aws rds describe-db-instances --db-instance-identifier gestion-proyectos-db

# Ver conexiones activas
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value=gestion-proyectos-db \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average

# Ver backups disponibles
aws rds describe-db-snapshots --db-instance-identifier gestion-proyectos-db

# Ver logs de PostgreSQL
aws rds download-db-log-file-portion \
  --db-instance-identifier gestion-proyectos-db \
  --log-file-name error/postgresql.log

# Conectar con psql (si tienes acceso temporal)
psql "host=gestion-proyectos-db.xxx.us-east-2.rds.amazonaws.com port=5432 dbname=gestion_proyectos user=dbadmin sslmode=require"
```

---

**¡Tu base de datos PostgreSQL en RDS está lista para producción! 🚀**
