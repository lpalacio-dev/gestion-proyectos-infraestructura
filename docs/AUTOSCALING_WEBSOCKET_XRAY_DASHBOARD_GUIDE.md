# 🔭 Guía Completa: Auto Scaling + WebSocket Lambda + X-Ray + CloudWatch Dashboard

## 📋 Tabla de Contenidos

1. [Auto Scaling — ECS basado en CPU](#parte-1-auto-scaling)
2. [Segunda Lambda — Notificaciones WebSocket en tiempo real](#parte-2-websocket-lambda)
3. [X-Ray — Tracing end-to-end del flujo completo](#parte-3-x-ray)
4. [CloudWatch Dashboard — Panel unificado de métricas](#parte-4-dashboard)
5. [Arquitectura Final del Proyecto](#arquitectura-final)
6. [Costos Estimados](#costos)

---

## 🎯 Visión General

Esta es la guía final del stack. Al terminarla, tu proyecto tendrá **observabilidad completa** (X-Ray + Dashboard), **resiliencia** (Auto Scaling) y un segundo canal de notificaciones en tiempo real (WebSocket) que demuestra el patrón fan-out de SNS en acción.

```
Flujo completo con todos los servicios:

Usuario ──► Route 53 ──► ALB ──► ECS (Auto Scaling 1-4 tasks)
                                      │
                                      │ SNS PublishAsync
                                      ▼
                               SNS Topic: task-events-topic
                                      │
                    ┌─────────────────┴──────────────────┐
                    ▼                                     ▼
             SQS: task-email-queue              SQS: task-ws-queue
                    │                                     │
                    ▼                                     ▼
          Lambda: TaskNotifierLambda          Lambda: TaskWsNotifierLambda
          (Email via SES)                     (WebSocket via API Gateway)
                    │                                     │
                    └──────────────┬──────────────────────┘
                                   │
                            X-Ray traces todo este flujo
                                   │
                            CloudWatch Dashboard
                            (ALB + ECS + RDS + Lambda + SQS)
```

---

# PARTE 1: Auto Scaling — ECS basado en CPU

## ¿Qué Vamos a Construir?

Auto Scaling ajusta automáticamente el número de tasks ECS según la carga. Cuando la CPU sube, lanza más tasks. Cuando baja, los reduce. Esto es transparente para el usuario y no requiere cambios en el código.

```
Carga normal:    [Task 1]                    → 1 task corriendo
Carga alta:      [Task 1] [Task 2] [Task 3]  → escala a 3 tasks automáticamente
Carga baja:      [Task 1]                    → reduce a 1 task (min configurado)
```

## Paso 1.1: Registrar el ECS Service como Scalable Target

Application Auto Scaling necesita "conocer" qué recurso va a escalar antes de crear políticas sobre él.

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/gestion-proyectos-cluster/gestion-proyectos-service \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 1 \
  --max-capacity 4 \
  --region us-east-2
```

**Parámetros explicados:**

| Parámetro | Valor | Significado |
|---|---|---|
| `min-capacity` | 1 | Siempre habrá al menos 1 task corriendo |
| `max-capacity` | 4 | Máximo 4 tasks simultáneos (controla costos) |
| `scalable-dimension` | ecs:service:DesiredCount | Qué ajustar: el número deseado de tasks |

## Paso 1.2: Crear Política de Scale-Out (escalar hacia arriba)

Esta política lanza tasks adicionales cuando la CPU promedio supera el 70% durante 2 minutos consecutivos.

```bash
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/gestion-proyectos-cluster/gestion-proyectos-service \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name gestion-proyectos-scale-out \
  --policy-type StepScaling \
  --step-scaling-policy-configuration '{
    "AdjustmentType": "ChangeInCapacity",
    "Cooldown": 120,
    "StepAdjustments": [
      {
        "MetricIntervalLowerBound": 0,
        "MetricIntervalUpperBound": 20,
        "ScalingAdjustment": 1
      },
      {
        "MetricIntervalLowerBound": 20,
        "ScalingAdjustment": 2
      }
    ]
  }' \
  --region us-east-2
```

**Lógica de los escalones:**
- CPU entre 70-90% → agrega **1 task**
- CPU mayor a 90% → agrega **2 tasks** (situación crítica, respuesta más agresiva)

## Paso 1.3: Crear la Alarma CloudWatch que dispara Scale-Out

La política del paso anterior por sí sola no se ejecuta. Necesita una alarma de CloudWatch que la active.

```bash
# Obtener el ARN de la política de scale-out
SCALE_OUT_ARN=$(aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --query "ScalingPolicies[?PolicyName=='gestion-proyectos-scale-out'].PolicyARN" \
  --output text \
  --region us-east-2)

# Crear alarma que dispara el scale-out
aws cloudwatch put-metric-alarm \
  --alarm-name ecs-high-cpu-scale-out \
  --alarm-description "Escalar ECS cuando CPU > 70% por 2 minutos" \
  --metric-name CPUUtilization \
  --namespace AWS/ECS \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 70 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --dimensions \
    Name=ClusterName,Value=gestion-proyectos-cluster \
    Name=ServiceName,Value=gestion-proyectos-service \
  --alarm-actions $SCALE_OUT_ARN \
  --region us-east-2
```

## Paso 1.4: Crear Política de Scale-In (escalar hacia abajo)

Cuando la CPU baja de 30%, reduce tasks para ahorrar costos. El cooldown de 300 segundos evita que reduzca demasiado rápido.

```bash
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/gestion-proyectos-cluster/gestion-proyectos-service \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name gestion-proyectos-scale-in \
  --policy-type StepScaling \
  --step-scaling-policy-configuration '{
    "AdjustmentType": "ChangeInCapacity",
    "Cooldown": 300,
    "StepAdjustments": [
      {
        "MetricIntervalUpperBound": 0,
        "ScalingAdjustment": -1
      }
    ]
  }' \
  --region us-east-2
```

```bash
# Obtener ARN de la política scale-in
SCALE_IN_ARN=$(aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --query "ScalingPolicies[?PolicyName=='gestion-proyectos-scale-in'].PolicyARN" \
  --output text \
  --region us-east-2)

# Crear alarma que dispara el scale-in
aws cloudwatch put-metric-alarm \
  --alarm-name ecs-low-cpu-scale-in \
  --alarm-description "Reducir ECS cuando CPU < 30% por 5 minutos" \
  --metric-name CPUUtilization \
  --namespace AWS/ECS \
  --statistic Average \
  --period 60 \
  --evaluation-periods 5 \
  --threshold 30 \
  --comparison-operator LessThanThreshold \
  --dimensions \
    Name=ClusterName,Value=gestion-proyectos-cluster \
    Name=ServiceName,Value=gestion-proyectos-service \
  --alarm-actions $SCALE_IN_ARN \
  --region us-east-2
```

> **¿Por qué 5 periodos para scale-in y 2 para scale-out?** Para escalar hacia arriba queremos respuesta rápida (la app está bajo presión). Para escalar hacia abajo queremos ser conservadores y asegurarnos de que la carga realmente bajó antes de eliminar tasks.

## Paso 1.5: Verificar la configuración

```bash
# Ver el scalable target registrado
aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs \
  --region us-east-2

# Ver las políticas activas
aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --region us-east-2

# Ver las alarmas de Auto Scaling
aws cloudwatch describe-alarms \
  --alarm-names ecs-high-cpu-scale-out ecs-low-cpu-scale-in \
  --region us-east-2
```

## Paso 1.6: Probar el Auto Scaling

```bash
# Simular carga alta: forzar la alarma de scale-out manualmente
aws cloudwatch set-alarm-state \
  --alarm-name ecs-high-cpu-scale-out \
  --state-value ALARM \
  --state-reason "Prueba manual de Auto Scaling" \
  --region us-east-2

# Verificar que ECS aumentó el desired count
aws ecs describe-services \
  --cluster gestion-proyectos-cluster \
  --services gestion-proyectos-service \
  --query "services[0].{Deseados:desiredCount,Corriendo:runningCount,Pendientes:pendingCount}" \
  --region us-east-2

# Restaurar estado normal (importante: hacerlo después de la prueba)
aws cloudwatch set-alarm-state \
  --alarm-name ecs-high-cpu-scale-out \
  --state-value OK \
  --state-reason "Fin de prueba manual" \
  --region us-east-2
```

---

# PARTE 2: Segunda Lambda — Notificaciones WebSocket en Tiempo Real

## ¿Qué Vamos a Construir?

Una segunda Lambda suscrita al mismo SNS Topic que recibe los eventos de tareas y los envía a los usuarios conectados vía WebSocket. Esto demuestra el patrón **fan-out** en acción: un evento publicado en SNS llega simultáneamente a dos Lambdas completamente independientes.

```
SNS Topic: task-events-topic
        │
        ├──► SQS: task-email-queue ──► Lambda: TaskNotifierLambda (email)  [ya existe]
        │
        └──► SQS: task-ws-queue   ──► Lambda: TaskWsNotifierLambda (websocket) [NUEVO]
```

> **Nota:** Para que esto funcione necesitas tener un WebSocket API Gateway con una tabla DynamoDB de conexiones activas. Si tu proyecto no tiene WebSocket aún, la Lambda igual es válida como demostración — puede loggear el intento y manejar el caso de "no hay conexiones activas" gracefully.

## Paso 2.1: Crear la SQS Queue para WebSocket

```bash
# DLQ primero
aws sqs create-queue \
  --queue-name task-ws-dlq \
  --region us-east-2 \
  --attributes '{"MessageRetentionPeriod": "1209600"}'

# Cola principal
aws sqs create-queue \
  --queue-name task-ws-queue \
  --region us-east-2 \
  --attributes '{
    "VisibilityTimeout": "30",
    "MessageRetentionPeriod": "300",
    "RedrivePolicy": "{\"deadLetterTargetArn\":\"arn:aws:sqs:us-east-2:<ACCOUNT_ID>:task-ws-dlq\",\"maxReceiveCount\":\"2\"}"
  }'
```

> **`MessageRetentionPeriod: 300` (5 minutos)** — Las notificaciones WebSocket tienen muy poco valor después de unos minutos. Un usuario desconectado no necesita ver actualizaciones de hace 10 minutos cuando reconecte; obtendrá el estado actual del API REST. Por eso la retención es mucho menor que la cola de email.

**Agregar política para que SNS pueda escribir:**

```bash
cat > ws-sqs-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSNSPublish",
      "Effect": "Allow",
      "Principal": { "Service": "sns.amazonaws.com" },
      "Action": "sqs:SendMessage",
      "Resource": "arn:aws:sqs:us-east-2:<ACCOUNT_ID>:task-ws-queue",
      "Condition": {
        "ArnEquals": {
          "aws:SourceArn": "arn:aws:sns:us-east-2:<ACCOUNT_ID>:task-events-topic"
        }
      }
    }
  ]
}
EOF

aws sqs set-queue-attributes \
  --queue-url https://sqs.us-east-2.amazonaws.com/<ACCOUNT_ID>/task-ws-queue \
  --attributes "{\"Policy\": $(cat ws-sqs-policy.json | jq -c tostring)}" \
  --region us-east-2
```

## Paso 2.2: Suscribir la nueva cola a SNS

```bash
aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-2:<ACCOUNT_ID>:task-events-topic \
  --protocol sqs \
  --notification-endpoint arn:aws:sqs:us-east-2:<ACCOUNT_ID>:task-ws-queue \
  --region us-east-2

# Verificar que ahora hay 2 suscripciones
aws sns list-subscriptions-by-topic \
  --topic-arn arn:aws:sns:us-east-2:<ACCOUNT_ID>:task-events-topic
```

## Paso 2.3: IAM Role para la Lambda WebSocket

```bash
# Crear role
aws iam create-role \
  --role-name TaskWsNotifierLambdaRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }'

aws iam attach-role-policy \
  --role-name TaskWsNotifierLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# Política personalizada: SQS + DynamoDB + API Gateway WebSocket + X-Ray
cat > ws-lambda-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SQSConsumer",
      "Effect": "Allow",
      "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"],
      "Resource": "arn:aws:sqs:us-east-2:<ACCOUNT_ID>:task-ws-queue"
    },
    {
      "Sid": "DynamoDBConnections",
      "Effect": "Allow",
      "Action": ["dynamodb:Scan", "dynamodb:GetItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:us-east-2:<ACCOUNT_ID>:table/ws-connections"
    },
    {
      "Sid": "WebSocketBroadcast",
      "Effect": "Allow",
      "Action": "execute-api:ManageConnections",
      "Resource": "arn:aws:execute-api:us-east-2:<ACCOUNT_ID>:*/@connections/*"
    },
    {
      "Sid": "XRayTracing",
      "Effect": "Allow",
      "Action": ["xray:PutTraceSegments", "xray:PutTelemetryRecords"],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name TaskWsNotifierLambdaPolicy \
  --policy-document file://ws-lambda-policy.json

aws iam attach-role-policy \
  --role-name TaskWsNotifierLambdaRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/TaskWsNotifierLambdaPolicy
```

## Paso 2.4: Código de la Lambda WebSocket

### Estructura del proyecto

```
TaskWsNotifierLambda/
├── src/
│   └── TaskWsNotifierLambda/
│       ├── Function.cs
│       ├── TaskWsNotifierLambda.csproj
│       └── Models/
│           ├── TaskNotificationEvent.cs
│           └── WsConnection.cs
└── aws-lambda-tools-defaults.json
```

### TaskWsNotifierLambda.csproj

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <GenerateRuntimeConfigurationFiles>true</GenerateRuntimeConfigurationFiles>
    <AWSProjectType>Lambda</AWSProjectType>
    <CopyLocalLockFileAssemblies>true</CopyLocalLockFileAssemblies>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Amazon.Lambda.Core"                        Version="2.2.0" />
    <PackageReference Include="Amazon.Lambda.SQSEvents"                   Version="5.0.0" />
    <PackageReference Include="Amazon.Lambda.Serialization.SystemTextJson" Version="2.4.0" />
    <PackageReference Include="AWSSDK.DynamoDBv2"                         Version="3.7.300" />
    <PackageReference Include="AWSSDK.ApiGatewayManagementApi"            Version="3.7.300" />
    <PackageReference Include="AWSXRayRecorder.Core"                      Version="2.14.0" />
    <PackageReference Include="AWSXRayRecorder.Handlers.AwsSdk"           Version="2.14.0" />
  </ItemGroup>
</Project>
```

### Models/WsConnection.cs

```csharp
namespace TaskWsNotifierLambda.Models;

public class WsConnection
{
    public string ConnectionId { get; set; } = "";
    public string UserId       { get; set; } = "";
    public long   Ttl          { get; set; }
}
```

### Models/TaskNotificationEvent.cs

```csharp
namespace TaskWsNotifierLambda.Models;

// Mismo modelo que en TaskNotifierLambda — debe coincidir con el payload de SNS
public class TaskNotificationEvent
{
    public string  EventType         { get; set; } = "";
    public string  TaskId            { get; set; } = "";
    public string  TaskTitle         { get; set; } = "";
    public string  ProjectName       { get; set; } = "";
    public string  AssignedUserEmail { get; set; } = "";
    public string? NewStatus         { get; set; }
    public string? OldStatus         { get; set; }
}
```

### Function.cs

```csharp
using System.Net;
using System.Text;
using System.Text.Json;
using Amazon.ApiGatewayManagementApi;
using Amazon.ApiGatewayManagementApi.Model;
using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using Amazon.Lambda.Core;
using Amazon.Lambda.SQSEvents;
using Amazon.XRay.Recorder.Core;
using Amazon.XRay.Recorder.Handlers.AwsSdk;
using TaskWsNotifierLambda.Models;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace TaskWsNotifierLambda;

public class Function
{
    private readonly IAmazonDynamoDB _dynamoDb;
    private readonly string _connectionsTable;
    private readonly string _wsEndpoint;

    public Function()
    {
        // Registrar X-Ray para que tracee automáticamente todas las llamadas al SDK de AWS
        AWSSDKHandler.RegisterXRayForAllServices();

        _dynamoDb         = new AmazonDynamoDBClient();
        _connectionsTable = Environment.GetEnvironmentVariable("CONNECTIONS_TABLE") ?? "ws-connections";
        _wsEndpoint       = Environment.GetEnvironmentVariable("WS_ENDPOINT")
                            ?? throw new Exception("WS_ENDPOINT no configurado");
    }

    public async Task<SQSBatchResponse> FunctionHandler(SQSEvent sqsEvent, ILambdaContext context)
    {
        var batchResponse = new SQSBatchResponse
        {
            BatchItemFailures = new List<SQSBatchResponse.BatchItemFailure>()
        };

        foreach (var message in sqsEvent.Records)
        {
            try
            {
                // Abrir subsegmento X-Ray por cada mensaje procesado
                AWSXRayRecorder.Instance.BeginSubsegment("ProcessSQSMessage");

                var snsWrapper   = JsonSerializer.Deserialize<SnsMessageWrapper>(message.Body)!;
                var notification = JsonSerializer.Deserialize<TaskNotificationEvent>(snsWrapper.Message)!;

                context.Logger.LogInformation(
                    $"[WsNotifier] Procesando evento {notification.EventType} para tarea {notification.TaskId}");

                // Obtener todas las conexiones WebSocket activas
                var connections = await GetActiveConnectionsAsync();
                context.Logger.LogInformation($"[WsNotifier] Conexiones activas: {connections.Count}");

                if (connections.Count == 0)
                {
                    context.Logger.LogInformation("[WsNotifier] No hay conexiones activas. Mensaje descartado.");
                    AWSXRayRecorder.Instance.EndSubsegment();
                    continue;
                }

                // Construir el payload que recibirá el cliente WebSocket
                var wsPayload = JsonSerializer.Serialize(new
                {
                    eventType   = notification.EventType,
                    taskId      = notification.TaskId,
                    taskTitle   = notification.TaskTitle,
                    projectName = notification.ProjectName,
                    newStatus   = notification.NewStatus,
                    oldStatus   = notification.OldStatus,
                    timestamp   = DateTime.UtcNow.ToString("O")
                });

                // Broadcast a todas las conexiones activas
                await BroadcastAsync(connections, wsPayload, context);

                AWSXRayRecorder.Instance.EndSubsegment();
            }
            catch (Exception ex)
            {
                context.Logger.LogError(
                    $"[WsNotifier] Error procesando mensaje {message.MessageId}: {ex.Message}");

                batchResponse.BatchItemFailures.Add(new SQSBatchResponse.BatchItemFailure
                {
                    ItemIdentifier = message.MessageId
                });
            }
        }

        return batchResponse;
    }

    private async Task<List<WsConnection>> GetActiveConnectionsAsync()
    {
        // Scan de la tabla de conexiones (para producción con muchos usuarios,
        // usar Query con un índice GSI por projectId o userId)
        var request = new ScanRequest
        {
            TableName = _connectionsTable,
            // Filtrar conexiones cuyo TTL no ha expirado
            FilterExpression = "#ttl > :now",
            ExpressionAttributeNames  = new Dictionary<string, string>
            {
                ["#ttl"] = "ttl"
            },
            ExpressionAttributeValues = new Dictionary<string, AttributeValue>
            {
                [":now"] = new AttributeValue { N = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString() }
            }
        };

        var response = await _dynamoDb.ScanAsync(request);

        return response.Items.Select(item => new WsConnection
        {
            ConnectionId = item["connectionId"].S,
            UserId       = item.ContainsKey("userId") ? item["userId"].S : "",
            Ttl          = long.Parse(item["ttl"].N)
        }).ToList();
    }

    private async Task BroadcastAsync(List<WsConnection> connections, string payload, ILambdaContext context)
    {
        // El endpoint de API Gateway WebSocket Management
        var apiClient = new AmazonApiGatewayManagementApiClient(new AmazonApiGatewayManagementApiConfig
        {
            ServiceURL = _wsEndpoint
        });

        var payloadBytes = Encoding.UTF8.GetBytes(payload);
        var staleConnections = new List<string>();

        foreach (var conn in connections)
        {
            try
            {
                await apiClient.PostToConnectionAsync(new PostToConnectionRequest
                {
                    ConnectionId = conn.ConnectionId,
                    Data         = new MemoryStream(payloadBytes)
                });

                context.Logger.LogInformation($"[WsNotifier] Mensaje enviado a {conn.ConnectionId}");
            }
            catch (GoneException)
            {
                // La conexión expiró o el cliente se desconectó — marcar para limpiar
                context.Logger.LogInformation(
                    $"[WsNotifier] Conexión {conn.ConnectionId} ya no existe. Limpiando...");
                staleConnections.Add(conn.ConnectionId);
            }
            catch (Exception ex)
            {
                context.Logger.LogError(
                    $"[WsNotifier] Error enviando a {conn.ConnectionId}: {ex.Message}");
            }
        }

        // Limpiar conexiones inactivas de DynamoDB
        foreach (var connectionId in staleConnections)
        {
            await _dynamoDb.DeleteItemAsync(_connectionsTable,
                new Dictionary<string, AttributeValue>
                {
                    ["connectionId"] = new AttributeValue { S = connectionId }
                });
        }
    }
}

public class SnsMessageWrapper
{
    public string Type      { get; set; } = "";
    public string MessageId { get; set; } = "";
    public string Message   { get; set; } = "";
    public string Subject   { get; set; } = "";
}
```

### aws-lambda-tools-defaults.json

```json
{
  "profile": "",
  "region": "us-east-2",
  "configuration": "Release",
  "framework": "net8.0",
  "function-runtime": "dotnet8",
  "function-memory-size": 256,
  "function-timeout": 30,
  "function-handler": "TaskWsNotifierLambda::TaskWsNotifierLambda.Function::FunctionHandler",
  "environment-variables": "CONNECTIONS_TABLE=ws-connections;WS_ENDPOINT=https://XXXX.execute-api.us-east-2.amazonaws.com/prod"
}
```

## Paso 2.5: Deploy y Event Source Mapping

```bash
cd TaskWsNotifierLambda/src/TaskWsNotifierLambda

dotnet lambda deploy-function TaskWsNotifierLambda \
  --region us-east-2 \
  --function-role arn:aws:iam::<ACCOUNT_ID>:role/TaskWsNotifierLambdaRole \
  --environment-variables "CONNECTIONS_TABLE=ws-connections;WS_ENDPOINT=https://XXXX.execute-api.us-east-2.amazonaws.com/prod"

# Conectar Lambda con la cola SQS
aws lambda create-event-source-mapping \
  --function-name TaskWsNotifierLambda \
  --event-source-arn arn:aws:sqs:us-east-2:<ACCOUNT_ID>:task-ws-queue \
  --batch-size 10 \
  --function-response-types ReportBatchItemFailures \
  --region us-east-2
```

> **`batch-size: 10`** para WebSocket vs `batch-size: 5` para email — los mensajes WebSocket son livianos y queremos procesarlos en grupos más grandes para mayor eficiencia.

---

# PARTE 3: X-Ray — Tracing End-to-End

## ¿Qué es X-Ray y por qué importa?

X-Ray genera un **mapa visual del flujo completo** de cada request: desde la API Gateway → ECS → SNS → SQS → Lambda → SES/DynamoDB. También muestra el tiempo que tardó cada paso, qué falló y dónde ocurrió la latencia.

Sin X-Ray: "Lambda tardó mucho" → ¿en DynamoDB? ¿en SES? ¿en el mensaje de SQS?
Con X-Ray: Ves exactamente cada subsegmento con su tiempo individual.

## Paso 3.1: Habilitar X-Ray en ambas Lambdas

```bash
# Habilitar tracing en TaskNotifierLambda
aws lambda update-function-configuration \
  --function-name TaskNotifierLambda \
  --tracing-config Mode=Active \
  --region us-east-2

# Habilitar tracing en TaskWsNotifierLambda
aws lambda update-function-configuration \
  --function-name TaskWsNotifierLambda \
  --tracing-config Mode=Active \
  --region us-east-2
```

**`Mode=Active`** → X-Ray tracee TODAS las invocaciones. La alternativa `PassThrough` solo tracearía si la solicitud ya viene con un trace header (útil en producción para no pagar por el 100% del tráfico).

## Paso 3.2: Agregar paquetes X-Ray a TaskNotifierLambda

La `TaskWsNotifierLambda` ya incluye X-Ray en su `.csproj`. Ahora agrégalo a `TaskNotifierLambda`:

```bash
cd TaskNotifierLambda/src/TaskNotifierLambda

dotnet add package AWSXRayRecorder.Core
dotnet add package AWSXRayRecorder.Handlers.AwsSdk
```

Actualiza `Function.cs` del TaskNotifierLambda — agrega en el constructor:

```csharp
// Function.cs de TaskNotifierLambda — agregar en el constructor
using Amazon.XRay.Recorder.Core;
using Amazon.XRay.Recorder.Handlers.AwsSdk;

public Function()
{
    // Una línea — registra X-Ray para TODAS las llamadas al SDK de AWS (SES, SQS, etc.)
    AWSSDKHandler.RegisterXRayForAllServices();

    _sesClient = new AmazonSimpleEmailServiceClient();
}
```

Y agrega subsegmentos personalizados alrededor de la lógica de negocio:

```csharp
// En el método FunctionHandler, envuelve el procesamiento:
foreach (var message in sqsEvent.Records)
{
    try
    {
        AWSXRayRecorder.Instance.BeginSubsegment("ProcessTaskNotification");

        var snsWrapper   = JsonSerializer.Deserialize<SnsMessageWrapper>(message.Body)!;
        var notification = JsonSerializer.Deserialize<TaskNotificationEvent>(snsWrapper.Message)!;

        // Agregar anotaciones visibles en la consola de X-Ray
        AWSXRayRecorder.Instance.AddAnnotation("EventType", notification.EventType);
        AWSXRayRecorder.Instance.AddAnnotation("TaskId",    notification.TaskId);

        await SendEmailAsync(notification, context);

        AWSXRayRecorder.Instance.EndSubsegment();
    }
    catch (Exception ex)
    {
        AWSXRayRecorder.Instance.AddException(ex);
        AWSXRayRecorder.Instance.EndSubsegment();
        // ... resto del catch
    }
}
```

Redeploya:
```bash
dotnet lambda deploy-function TaskNotifierLambda --region us-east-2
```

## Paso 3.3: Agregar permisos X-Ray al role de TaskNotifierLambda

```bash
cat > xray-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["xray:PutTraceSegments", "xray:PutTelemetryRecords"],
    "Resource": "*"
  }]
}
EOF

aws iam create-policy \
  --policy-name XRayWritePolicy \
  --policy-document file://xray-policy.json

aws iam attach-role-policy \
  --role-name TaskNotifierLambdaRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/XRayWritePolicy
```

## Paso 3.4: Ver los traces en la consola

```bash
# Ver traces recientes de los últimos 10 minutos
aws xray get-trace-summaries \
  --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --region us-east-2

# Ver un trace específico con todo el detalle
aws xray batch-get-traces \
  --trace-ids <TRACE_ID> \
  --region us-east-2
```

**Consola visual (mucho mejor que CLI):**
1. AWS Console → X-Ray → Traces
2. Verás cada invocación de Lambda con su mapa de subsegmentos
3. CloudWatch → ServiceMap → muestra el grafo completo del sistema

---

# PARTE 4: CloudWatch Dashboard — Panel Unificado

## ¿Qué Vamos a Construir?

Un Dashboard con 12 widgets organizados en filas que muestran el estado de todo el stack en una sola pantalla:

```
┌─────────────────────────────────────────────────────────────────────┐
│  FILA 1: ECS Fargate                                                │
│  [CPU %] [Memoria %] [Tasks corriendo] [Requests ALB]              │
├─────────────────────────────────────────────────────────────────────┤
│  FILA 2: Application Load Balancer                                  │
│  [Latencia P99] [Errores 5xx] [Errores 4xx] [Healthy Hosts]        │
├─────────────────────────────────────────────────────────────────────┤
│  FILA 3: Lambda + SQS                                               │
│  [Invocaciones Lambdas] [Errores Lambda] [Msgs en SQS] [DLQ msgs]  │
├─────────────────────────────────────────────────────────────────────┤
│  FILA 4: RDS Aurora                                                 │
│  [CPU DB] [Conexiones DB] [Latencia escritura] [Latencia lectura]   │
└─────────────────────────────────────────────────────────────────────┘
```

## Paso 4.1: Obtener los IDs necesarios

Antes de crear el dashboard necesitas algunos IDs:

```bash
# ARN del ALB (para las dimensiones de CloudWatch)
aws elbv2 describe-load-balancers \
  --names gestion-proyectos-alb \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text \
  --region us-east-2
# El sufijo del ARN es lo que CloudWatch usa:
# app/gestion-proyectos-alb/XXXXXXXXXXXXXXXX

# ARN del Target Group
aws elbv2 describe-target-groups \
  --names gestion-proyectos-tg \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text \
  --region us-east-2
# targetgroup/gestion-proyectos-tg/XXXXXXXXXXXXXXXX

# Identificador del cluster RDS
aws rds describe-db-clusters \
  --query "DBClusters[0].DBClusterIdentifier" \
  --output text \
  --region us-east-2
```

## Paso 4.2: Crear el Dashboard

Crea el archivo `dashboard.json` — reemplaza los valores marcados con `<>`:

```bash
cat > dashboard.json << 'DASHBOARD_EOF'
{
  "widgets": [
    {
      "type": "text",
      "x": 0, "y": 0, "width": 24, "height": 1,
      "properties": {
        "markdown": "# 🚀 Gestion Proyectos — Dashboard de Operaciones\n**Stack:** ECS Fargate + ALB + RDS Aurora + Lambda + SNS/SQS | **Región:** us-east-2"
      }
    },
    {
      "type": "text",
      "x": 0, "y": 1, "width": 24, "height": 1,
      "properties": { "markdown": "## ⚙️ ECS Fargate — Compute" }
    },
    {
      "type": "metric",
      "x": 0, "y": 2, "width": 6, "height": 6,
      "properties": {
        "title": "CPU Utilization (%)",
        "metrics": [[
          "AWS/ECS", "CPUUtilization",
          "ClusterName", "gestion-proyectos-cluster",
          "ServiceName", "gestion-proyectos-service"
        ]],
        "view": "timeSeries",
        "stat": "Average",
        "period": 60,
        "annotations": {
          "horizontal": [
            { "label": "Scale-Out", "value": 70, "color": "#ff7f0e" },
            { "label": "Scale-In",  "value": 30, "color": "#2ca02c" }
          ]
        },
        "region": "us-east-2",
        "yAxis": { "left": { "min": 0, "max": 100 } }
      }
    },
    {
      "type": "metric",
      "x": 6, "y": 2, "width": 6, "height": 6,
      "properties": {
        "title": "Memory Utilization (%)",
        "metrics": [[
          "AWS/ECS", "MemoryUtilization",
          "ClusterName", "gestion-proyectos-cluster",
          "ServiceName", "gestion-proyectos-service"
        ]],
        "view": "timeSeries",
        "stat": "Average",
        "period": 60,
        "region": "us-east-2",
        "yAxis": { "left": { "min": 0, "max": 100 } }
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 2, "width": 6, "height": 6,
      "properties": {
        "title": "Tasks Corriendo",
        "metrics": [[
          "ECS/ContainerInsights", "RunningTaskCount",
          "ClusterName", "gestion-proyectos-cluster",
          "ServiceName", "gestion-proyectos-service"
        ]],
        "view": "timeSeries",
        "stat": "Average",
        "period": 60,
        "region": "us-east-2"
      }
    },
    {
      "type": "alarm",
      "x": 18, "y": 2, "width": 6, "height": 6,
      "properties": {
        "title": "Estado Alarmas ECS",
        "alarms": [
          "arn:aws:cloudwatch:us-east-2:<ACCOUNT_ID>:alarm:ecs-high-cpu-scale-out",
          "arn:aws:cloudwatch:us-east-2:<ACCOUNT_ID>:alarm:ecs-low-cpu-scale-in",
          "arn:aws:cloudwatch:us-east-2:<ACCOUNT_ID>:alarm:ALBUnhealthyHosts"
        ]
      }
    },
    {
      "type": "text",
      "x": 0, "y": 8, "width": 24, "height": 1,
      "properties": { "markdown": "## ⚖️ Application Load Balancer — Tráfico" }
    },
    {
      "type": "metric",
      "x": 0, "y": 9, "width": 6, "height": 6,
      "properties": {
        "title": "Latencia P99 (ms)",
        "metrics": [[
          "AWS/ApplicationELB", "TargetResponseTime",
          "LoadBalancer", "app/gestion-proyectos-alb/<ALB_SUFFIX>"
        ]],
        "view": "timeSeries",
        "stat": "p99",
        "period": 60,
        "region": "us-east-2"
      }
    },
    {
      "type": "metric",
      "x": 6, "y": 9, "width": 6, "height": 6,
      "properties": {
        "title": "Errores 5xx (por minuto)",
        "metrics": [[
          "AWS/ApplicationELB", "HTTPCode_Target_5XX_Count",
          "LoadBalancer", "app/gestion-proyectos-alb/<ALB_SUFFIX>"
        ]],
        "view": "timeSeries",
        "stat": "Sum",
        "period": 60,
        "region": "us-east-2",
        "annotations": {
          "horizontal": [{ "label": "Alerta", "value": 5, "color": "#d62728" }]
        }
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 9, "width": 6, "height": 6,
      "properties": {
        "title": "Requests Totales (por minuto)",
        "metrics": [[
          "AWS/ApplicationELB", "RequestCount",
          "LoadBalancer", "app/gestion-proyectos-alb/<ALB_SUFFIX>"
        ]],
        "view": "timeSeries",
        "stat": "Sum",
        "period": 60,
        "region": "us-east-2"
      }
    },
    {
      "type": "metric",
      "x": 18, "y": 9, "width": 6, "height": 6,
      "properties": {
        "title": "Healthy Hosts en Target Group",
        "metrics": [
          ["AWS/ApplicationELB", "HealthyHostCount",
           "TargetGroup", "targetgroup/gestion-proyectos-tg/<TG_SUFFIX>",
           "LoadBalancer", "app/gestion-proyectos-alb/<ALB_SUFFIX>"],
          ["AWS/ApplicationELB", "UnHealthyHostCount",
           "TargetGroup", "targetgroup/gestion-proyectos-tg/<TG_SUFFIX>",
           "LoadBalancer", "app/gestion-proyectos-alb/<ALB_SUFFIX>"]
        ],
        "view": "timeSeries",
        "stat": "Average",
        "period": 60,
        "region": "us-east-2"
      }
    },
    {
      "type": "text",
      "x": 0, "y": 15, "width": 24, "height": 1,
      "properties": { "markdown": "## ⚡ Lambda + Mensajería (SNS / SQS)" }
    },
    {
      "type": "metric",
      "x": 0, "y": 16, "width": 6, "height": 6,
      "properties": {
        "title": "Invocaciones Lambda",
        "metrics": [
          ["AWS/Lambda", "Invocations", "FunctionName", "TaskNotifierLambda"],
          ["AWS/Lambda", "Invocations", "FunctionName", "TaskWsNotifierLambda"]
        ],
        "view": "timeSeries",
        "stat": "Sum",
        "period": 60,
        "region": "us-east-2"
      }
    },
    {
      "type": "metric",
      "x": 6, "y": 16, "width": 6, "height": 6,
      "properties": {
        "title": "Errores Lambda",
        "metrics": [
          ["AWS/Lambda", "Errors", "FunctionName", "TaskNotifierLambda"],
          ["AWS/Lambda", "Errors", "FunctionName", "TaskWsNotifierLambda"]
        ],
        "view": "timeSeries",
        "stat": "Sum",
        "period": 60,
        "region": "us-east-2"
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 16, "width": 6, "height": 6,
      "properties": {
        "title": "Mensajes en SQS (en vuelo)",
        "metrics": [
          ["AWS/SQS", "ApproximateNumberOfMessagesNotVisible",
           "QueueName", "task-email-queue"],
          ["AWS/SQS", "ApproximateNumberOfMessagesNotVisible",
           "QueueName", "task-ws-queue"]
        ],
        "view": "timeSeries",
        "stat": "Average",
        "period": 60,
        "region": "us-east-2"
      }
    },
    {
      "type": "metric",
      "x": 18, "y": 16, "width": 6, "height": 6,
      "properties": {
        "title": "🚨 Mensajes en DLQ (errores)",
        "metrics": [
          ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
           "QueueName", "task-email-dlq"],
          ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
           "QueueName", "task-ws-dlq"]
        ],
        "view": "timeSeries",
        "stat": "Sum",
        "period": 60,
        "region": "us-east-2",
        "annotations": {
          "horizontal": [{ "label": "Alerta", "value": 1, "color": "#d62728" }]
        }
      }
    },
    {
      "type": "text",
      "x": 0, "y": 22, "width": 24, "height": 1,
      "properties": { "markdown": "## 🗄️ RDS Aurora — Base de Datos" }
    },
    {
      "type": "metric",
      "x": 0, "y": 23, "width": 6, "height": 6,
      "properties": {
        "title": "CPU RDS (%)",
        "metrics": [[
          "AWS/RDS", "CPUUtilization",
          "DBClusterIdentifier", "<RDS_CLUSTER_ID>"
        ]],
        "view": "timeSeries",
        "stat": "Average",
        "period": 60,
        "region": "us-east-2",
        "yAxis": { "left": { "min": 0, "max": 100 } }
      }
    },
    {
      "type": "metric",
      "x": 6, "y": 23, "width": 6, "height": 6,
      "properties": {
        "title": "Conexiones Activas DB",
        "metrics": [[
          "AWS/RDS", "DatabaseConnections",
          "DBClusterIdentifier", "<RDS_CLUSTER_ID>"
        ]],
        "view": "timeSeries",
        "stat": "Average",
        "period": 60,
        "region": "us-east-2"
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 23, "width": 6, "height": 6,
      "properties": {
        "title": "Latencia Escritura DB (ms)",
        "metrics": [[
          "AWS/RDS", "WriteLatency",
          "DBClusterIdentifier", "<RDS_CLUSTER_ID>"
        ]],
        "view": "timeSeries",
        "stat": "Average",
        "period": 60,
        "region": "us-east-2"
      }
    },
    {
      "type": "metric",
      "x": 18, "y": 23, "width": 6, "height": 6,
      "properties": {
        "title": "Latencia Lectura DB (ms)",
        "metrics": [[
          "AWS/RDS", "ReadLatency",
          "DBClusterIdentifier", "<RDS_CLUSTER_ID>"
        ]],
        "view": "timeSeries",
        "stat": "Average",
        "period": 60,
        "region": "us-east-2"
      }
    }
  ]
}
DASHBOARD_EOF

# Crear el Dashboard en CloudWatch
aws cloudwatch put-dashboard \
  --dashboard-name "GestionProyectos-Dashboard" \
  --dashboard-body file://dashboard.json \
  --region us-east-2

echo "Dashboard creado: https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards:name=GestionProyectos-Dashboard"
```

## Paso 4.3: Habilitar Container Insights (para la métrica RunningTaskCount)

El widget de "Tasks Corriendo" usa Container Insights, que no viene activado por defecto:

```bash
aws ecs update-cluster-settings \
  --cluster gestion-proyectos-cluster \
  --settings name=containerInsights,value=enabled \
  --region us-east-2
```

> **Costo de Container Insights:** ~$0.50 por task por mes. Para un portfolio con 1-2 tasks es mínimo.

## Paso 4.4: Configurar período de retención de logs

Por defecto, CloudWatch guarda logs indefinidamente. Para controlar costos:

```bash
# Lambda email
aws logs put-retention-policy \
  --log-group-name /aws/lambda/TaskNotifierLambda \
  --retention-in-days 7 \
  --region us-east-2

# Lambda WebSocket
aws logs put-retention-policy \
  --log-group-name /aws/lambda/TaskWsNotifierLambda \
  --retention-in-days 7 \
  --region us-east-2

# ECS
aws logs put-retention-policy \
  --log-group-name /ecs/gestion-proyectos \
  --retention-in-days 14 \
  --region us-east-2
```

---

# 🏗️ Arquitectura Final del Proyecto

Al completar todas las guías, tu proyecto tiene:

```
                              INTERNET
                                 │
                          Route 53 DNS
                    api.tudominio.com (ALIAS)
                    app.tudominio.com (ALIAS)
                         │              │
                         │              └──► CloudFront → S3 (Angular)
                         │
                    ALB :443 (HTTPS)
                    ALB :80  (→ redirect HTTPS)
                         │
                         │  Health Check /health cada 30s
                         ▼
               ┌─────────────────────────┐
               │  ECS Fargate Service    │
               │  Auto Scaling: 1-4 tasks│
               │  [Task .NET 8]          │◄── GitHub Actions CI/CD
               └──────────┬──────────────┘
                          │
               ┌──────────┴──────────┐
               │                     │
               ▼                     ▼
        RDS Aurora              SNS Topic
        PostgreSQL           task-events-topic
        (subnet privada)          │
                        ┌─────────┴──────────┐
                        ▼                    ▼
               SQS: task-email-queue    SQS: task-ws-queue
               (retención: 1 día)       (retención: 5 min)
                        │                    │
                        ▼                    ▼
               Lambda: TaskNotifier   Lambda: TaskWsNotifier
               (.NET 8, X-Ray)        (.NET 8, X-Ray)
                        │                    │
                        ▼                    ▼
                  SES (email)         API Gateway WS
                        │                    │
               DLQ: task-email-dlq   DLQ: task-ws-dlq
               
               CloudWatch Dashboard (métricas de todo lo anterior)
               X-Ray Service Map (traces end-to-end)
```

**Servicios AWS utilizados en el proyecto completo:**

| Servicio | Uso |
|---|---|
| **ECS Fargate** | Runtime del backend .NET 8 en contenedores |
| **ECR** | Registro de imágenes Docker |
| **Application Load Balancer** | Entrada HTTPS, health checks, routing |
| **Auto Scaling** | Escalado dinámico basado en CPU (1-4 tasks) |
| **Route 53** | DNS — dominios personalizados |
| **ACM** | Certificados SSL gratuitos |
| **RDS Aurora** | Base de datos PostgreSQL gestionada |
| **S3** | Hosting del frontend Angular |
| **CloudFront** | CDN para el frontend |
| **SNS** | Pub/Sub — distribuye eventos de tareas |
| **SQS** | Colas de mensajes con DLQ para resiliencia |
| **Lambda** | Procesamiento asíncrono (email + WebSocket) |
| **SES** | Envío de emails transaccionales |
| **API Gateway WS** | Canal WebSocket en tiempo real |
| **DynamoDB** | Tabla de conexiones WebSocket activas |
| **Secrets Manager** | Variables sensibles (connection strings, JWT) |
| **CloudWatch** | Logs, métricas, alarmas, dashboard |
| **X-Ray** | Tracing distribuido end-to-end |
| **IAM** | Roles y políticas de acceso |

---

# 💰 Costos Estimados

Costos adicionales de esta guía (sobre lo que ya tenías):

| Servicio | Uso estimado | Costo/mes |
|---|---|---|
| **Auto Scaling** | Políticas y alarmas | $0.00 (gratis) |
| **Lambda WsNotifier** | 10,000 invocaciones | $0.00 (free tier) |
| **SQS task-ws-queue** | 10,000 mensajes | $0.00 (free tier) |
| **X-Ray** | 100,000 traces | $0.00 (primer millón gratis) |
| **CloudWatch Dashboard** | 1 dashboard | $3.00 |
| **Container Insights** | 1-2 tasks | $0.50-1.00 |
| **CloudWatch Logs** | Retención 7-14 días | ~$0.50 |
| **Total adicional** | | **~$4-5 USD/mes** |

---

## ✅ Checklist Final

### Auto Scaling
- [ ] Scalable target registrado (min: 1, max: 4)
- [ ] Política scale-out creada (CPU > 70% → +1 o +2 tasks)
- [ ] Política scale-in creada (CPU < 30% → -1 task)
- [ ] Alarma scale-out configurada (2 periodos de 60s)
- [ ] Alarma scale-in configurada (5 periodos de 60s)
- [ ] Prueba manual con `set-alarm-state` exitosa

### Lambda WebSocket
- [ ] SQS `task-ws-queue` y `task-ws-dlq` creadas
- [ ] Segunda suscripción en SNS Topic creada
- [ ] IAM Role `TaskWsNotifierLambdaRole` con permisos SQS + DynamoDB + execute-api
- [ ] `TaskWsNotifierLambda` deployana con variables de entorno
- [ ] Event Source Mapping conectado (batch-size: 10)

### X-Ray
- [ ] Tracing `Active` habilitado en ambas Lambdas
- [ ] Paquetes X-Ray agregados al `.csproj` de ambas Lambdas
- [ ] `AWSSDKHandler.RegisterXRayForAllServices()` en el constructor
- [ ] Subsegmentos personalizados con `BeginSubsegment` / `EndSubsegment`
- [ ] Permisos `xray:PutTraceSegments` en ambos roles IAM
- [ ] Traces visibles en CloudWatch → X-Ray → Traces

### CloudWatch Dashboard
- [ ] Container Insights habilitado en el cluster ECS
- [ ] Dashboard `GestionProyectos-Dashboard` creado
- [ ] Los 4 sufijos (`<ALB_SUFFIX>`, `<TG_SUFFIX>`, `<ACCOUNT_ID>`, `<RDS_CLUSTER_ID>`) reemplazados
- [ ] Retención de logs configurada (7 días Lambda, 14 días ECS)
- [ ] Dashboard visible en la consola con métricas reales

---

**¡Stack completo! Tienes un sistema cloud-native con observabilidad total, escalado automático y dos canales de notificación en tiempo real. 🚀**

---

*Proyecto: gestion-proyectos*
*Región: us-east-2*
*Última actualización: Febrero 2026*
