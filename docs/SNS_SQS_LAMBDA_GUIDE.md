# 📨 Guía Completa: SNS + SQS + Lambda para Notificaciones de Tareas

## 📋 Índice

1. [Introducción y Arquitectura](#introducción)
2. [Paso 1: Configuración de IAM](#paso-1-iam)
3. [Paso 2: Crear el SNS Topic](#paso-2-sns)
4. [Paso 3: Crear las SQS Queues](#paso-3-sqs)
5. [Paso 4: Suscribir SQS a SNS](#paso-4-suscripción)
6. [Paso 5: Lambda — TaskNotifierLambda](#paso-5-lambda)
7. [Paso 6: Conectar Lambda con SQS](#paso-6-trigger)
8. [Paso 7: Migrar el Backend (.NET)](#paso-7-backend)
9. [Paso 8: Variables de Entorno en ECS](#paso-8-ecs)
10. [Monitoreo y Troubleshooting](#monitoreo)
11. [Costos Estimados](#costos)

---

## 🎯 Introducción

### ¿Qué Vamos a Construir?

Actualmente tu `TaskService.cs` invoca `TaskNotifierLambda` **directamente** con `IAmazonLambda`. Esto funciona, pero es un acoplamiento fuerte: si Lambda falla o tarda, impacta tu flujo. Vamos a reemplazarlo por un patrón **fan-out con SNS + SQS** que es más robusto, escalable y está alineado 100% con lo que pide la vacante.

### Arquitectura Antes vs Después

**Antes (acoplamiento directo):**
```
TaskService (.NET) ──── InvokeAsync ────► TaskNotifierLambda
```

**Después (desacoplado con SNS + SQS):**
```
TaskService (.NET)
        │
        │  PublishAsync (fire-and-forget)
        ▼
┌─────────────────────┐
│   SNS Topic         │
│  task-events-topic  │
└──────────┬──────────┘
           │  Fan-out (publica a TODAS las colas simultáneamente)
     ┌─────┴──────┐
     ▼             ▼
┌─────────┐   ┌─────────────┐
│   SQS   │   │   SQS       │
│  email  │   │  (futura)   │
│  Queue  │   │  WebSocket  │
└────┬────┘   └─────────────┘
     │
     │  Event Source Mapping (trigger automático)
     ▼
┌──────────────────────┐
│  TaskNotifierLambda  │
│  (.NET 8)            │
│  Envía email via SES │
└──────────────────────┘
         │
         ▼
    ┌─────────┐
    │  DLQ    │  ← mensajes que fallaron 3 veces
    └─────────┘
```

### ¿Por qué este patrón?

| Característica | Directo (antes) | SNS + SQS (después) |
|---|---|---|
| Si Lambda falla | El mensaje se pierde | Va a la DLQ para reintentos |
| Si agregas nueva funcionalidad | Modificas TaskService | Solo suscribes otra cola a SNS |
| Resiliencia | Baja | Alta |
| Escalabilidad | Manual | Automática |
| Nivel entrevista | Junior | Mid/Senior |

---

## 1️⃣ Paso 1: IAM — Permisos Necesarios

Necesitas dos roles: uno para ECS (tu backend) y uno para Lambda.

### Role para Lambda (si no lo tienes del LAMBDA_SETUP_GUIDE)

```bash
# Trust policy para Lambda
cat > lambda-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name TaskNotifierLambdaRole \
  --assume-role-policy-document file://lambda-trust-policy.json

# Política básica de Lambda (CloudWatch Logs)
aws iam attach-role-policy \
  --role-name TaskNotifierLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

### Política personalizada para Lambda (SQS + SES)

```bash
cat > lambda-custom-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SQSConsumer",
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ],
      "Resource": "arn:aws:sqs:us-east-2:<ACCOUNT_ID>:task-email-queue"
    },
    {
      "Sid": "SESEmail",
      "Effect": "Allow",
      "Action": [
        "ses:SendEmail",
        "ses:SendRawEmail"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name TaskNotifierLambdaPolicy \
  --policy-document file://lambda-custom-policy.json

aws iam attach-role-policy \
  --role-name TaskNotifierLambdaRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/TaskNotifierLambdaPolicy
```

### Política adicional para tu Task ECS (publicar en SNS)

Tu backend en ECS ya tiene un IAM Task Role. Agrégale permiso de SNS:

```bash
cat > ecs-sns-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SNSPublish",
      "Effect": "Allow",
      "Action": "sns:Publish",
      "Resource": "arn:aws:sns:us-east-2:<ACCOUNT_ID>:task-events-topic"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name ECSBackendSNSPolicy \
  --policy-document file://ecs-sns-policy.json

# Adjuntar al role existente de tu ECS Task (ajusta el nombre del role)
aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/ECSBackendSNSPolicy
```

> **⚠️ Reemplaza `<ACCOUNT_ID>`** en todos los comandos con tu AWS Account ID:
> ```bash
> aws sts get-caller-identity --query Account --output text
> ```

---

## 2️⃣ Paso 2: Crear el SNS Topic

SNS es el **distribuidor central**. Tu backend publica aquí y SNS reenvía a todas las colas suscritas.

```bash
# Crear el Topic
aws sns create-topic \
  --name task-events-topic \
  --region us-east-2

# Guardar el ARN que devuelve el comando:
# arn:aws:sns:us-east-2:<ACCOUNT_ID>:task-events-topic
```

**Verificar que se creó:**
```bash
aws sns list-topics --region us-east-2
```

**Agregar etiquetas (buena práctica):**
```bash
aws sns tag-resource \
  --resource-arn arn:aws:sns:us-east-2:<ACCOUNT_ID>:task-events-topic \
  --tags Key=Project,Value=gestion-proyectos Key=Environment,Value=develop
```

---

## 3️⃣ Paso 3: Crear las SQS Queues

Necesitas **dos colas**: la principal y la Dead Letter Queue (DLQ) para mensajes fallidos.

### 3.1 Crear la DLQ primero

```bash
# La DLQ se crea primero porque la cola principal la referencia
aws sqs create-queue \
  --queue-name task-email-dlq \
  --region us-east-2 \
  --attributes '{
    "MessageRetentionPeriod": "1209600"
  }'

# MessageRetentionPeriod = 14 días (en segundos) — tiempo para investigar mensajes fallidos

# Guardar el ARN de la DLQ:
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-2.amazonaws.com/<ACCOUNT_ID>/task-email-dlq \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' \
  --output text
# Output: arn:aws:sqs:us-east-2:<ACCOUNT_ID>:task-email-dlq
```

### 3.2 Crear la Cola Principal

```bash
aws sqs create-queue \
  --queue-name task-email-queue \
  --region us-east-2 \
  --attributes '{
    "VisibilityTimeout": "60",
    "MessageRetentionPeriod": "86400",
    "RedrivePolicy": "{\"deadLetterTargetArn\":\"arn:aws:sqs:us-east-2:<ACCOUNT_ID>:task-email-dlq\",\"maxReceiveCount\":\"3\"}"
  }'
```

**Explicación de atributos:**

| Atributo | Valor | ¿Por qué? |
|---|---|---|
| `VisibilityTimeout` | 60 segundos | Lambda tiene 60s para procesar antes de que otro intente el mensaje |
| `MessageRetentionPeriod` | 86400 (1 día) | Los mensajes no procesados esperan 1 día |
| `maxReceiveCount` | 3 | Si Lambda falla 3 veces, el mensaje va a la DLQ |

**Agregar política de acceso para SNS** (permite que SNS escriba en la cola):

```bash
cat > sqs-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSNSPublish",
      "Effect": "Allow",
      "Principal": { "Service": "sns.amazonaws.com" },
      "Action": "sqs:SendMessage",
      "Resource": "arn:aws:sqs:us-east-2:<ACCOUNT_ID>:task-email-queue",
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
  --queue-url https://sqs.us-east-2.amazonaws.com/<ACCOUNT_ID>/task-email-queue \
  --attributes "{\"Policy\": $(cat sqs-policy.json | tr -d '\n' | sed 's/"/\\"/g')}"
```

**Forma alternativa (más fácil) desde consola:**
- SQS → `task-email-queue` → Access policy → Edit
- Pegar el JSON de `sqs-policy.json` directamente

---

## 4️⃣ Paso 4: Suscribir SQS a SNS (Fan-out)

Este es el paso que conecta SNS con SQS. Cuando tu backend publique en SNS, el mensaje llegará automáticamente a SQS.

```bash
aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-2:<ACCOUNT_ID>:task-events-topic \
  --protocol sqs \
  --notification-endpoint arn:aws:sqs:us-east-2:<ACCOUNT_ID>:task-email-queue \
  --region us-east-2

# Output: { "SubscriptionArn": "arn:aws:sns:us-east-2:<ACCOUNT_ID>:task-events-topic:xxxx-xxxx" }
```

**Verificar la suscripción:**
```bash
aws sns list-subscriptions-by-topic \
  --topic-arn arn:aws:sns:us-east-2:<ACCOUNT_ID>:task-events-topic
```

### Filtrar qué mensajes llegan a la cola (Opcional pero útil)

Si en el futuro tienes múltiples tipos de eventos, puedes filtrar:

```bash
# Solo mensajes con EventType = "TaskAssigned" o "TaskStatusChanged"
aws sns set-subscription-attributes \
  --subscription-arn <SUBSCRIPTION_ARN> \
  --attribute-name FilterPolicy \
  --attribute-value '{"EventType": ["TaskAssigned", "TaskStatusChanged"]}'
```

---

## 5️⃣ Paso 5: Lambda — TaskNotifierLambda

Esta Lambda consume mensajes de SQS y envía emails con SES.

### Estructura del Proyecto

```
TaskNotifierLambda/
├── src/
│   └── TaskNotifierLambda/
│       ├── Function.cs                  # Handler principal
│       ├── TaskNotifierLambda.csproj
│       └── Models/
│           └── TaskNotificationEvent.cs # Modelo del mensaje
└── aws-lambda-tools-defaults.json
```

### Paso 5.1: Crear el proyecto

```bash
cd ~/projects

dotnet new lambda.EmptyFunction -n TaskNotifierLambda -o TaskNotifierLambda/src/TaskNotifierLambda

cd TaskNotifierLambda/src/TaskNotifierLambda

dotnet add package Amazon.Lambda.SQSEvents
dotnet add package AWSSDK.SimpleEmail
dotnet add package Amazon.Lambda.Serialization.SystemTextJson
```

### Paso 5.2: TaskNotifierLambda.csproj

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
    <PackageReference Include="AWSSDK.SimpleEmail"                        Version="3.7.300" />
  </ItemGroup>
</Project>
```

### Paso 5.3: Models/TaskNotificationEvent.cs

```csharp
namespace TaskNotifierLambda.Models;

/// <summary>
/// Modelo del payload que publica el backend en SNS.
/// Debe coincidir exactamente con el objeto anónimo en TaskService.cs.
/// </summary>
public class TaskNotificationEvent
{
    public string EventType          { get; set; } = "";  // "TaskAssigned" | "TaskStatusChanged"
    public string TaskId             { get; set; } = "";
    public string TaskTitle          { get; set; } = "";
    public string? TaskDescription   { get; set; }
    public string ProjectName        { get; set; } = "";
    public string AssignedUserEmail  { get; set; } = "";
    public string AssignedUserName   { get; set; } = "";
    public string? AssignerName      { get; set; }
    public string? OldStatus         { get; set; }
    public string? NewStatus         { get; set; }
    public DateTime? DueDate         { get; set; }
}
```

### Paso 5.4: Function.cs (Handler Principal)

```csharp
using System.Text.Json;
using Amazon.Lambda.Core;
using Amazon.Lambda.SQSEvents;
using Amazon.SimpleEmail;
using Amazon.SimpleEmail.Model;
using TaskNotifierLambda.Models;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace TaskNotifierLambda;

public class Function
{
    private readonly IAmazonSimpleEmailService _sesClient;
    
    // IMPORTANTE: leer de variable de entorno, no hardcodear
    private readonly string _fromEmail = Environment.GetEnvironmentVariable("SES_FROM_EMAIL")
                                         ?? throw new Exception("SES_FROM_EMAIL no configurado");

    public Function()
    {
        _sesClient = new AmazonSimpleEmailServiceClient();
    }

    // Constructor para testing
    public Function(IAmazonSimpleEmailService sesClient)
    {
        _sesClient = sesClient;
    }

    /// <summary>
    /// Handler principal. SQS puede enviar múltiples mensajes a la vez (batch).
    /// Procesamos cada uno individualmente para que los fallos no afecten al batch completo.
    /// </summary>
    public async Task<SQSBatchResponse> FunctionHandler(SQSEvent sqsEvent, ILambdaContext context)
    {
        // SQSBatchResponse permite reportar qué mensajes fallaron individualmente
        // Los mensajes fallidos se reencolan y eventualmente van a la DLQ
        var batchResponse = new SQSBatchResponse
        {
            BatchItemFailures = new List<SQSBatchResponse.BatchItemFailure>()
        };

        foreach (var message in sqsEvent.Records)
        {
            try
            {
                context.Logger.LogInformation(
                    $"[TaskNotifier] Procesando mensaje {message.MessageId}");

                // Los mensajes de SNS vienen envueltos en un sobre JSON
                var snsWrapper   = JsonSerializer.Deserialize<SnsMessageWrapper>(message.Body)!;
                var notification = JsonSerializer.Deserialize<TaskNotificationEvent>(snsWrapper.Message)!;

                await SendEmailAsync(notification, context);

                context.Logger.LogInformation(
                    $"[TaskNotifier] Email enviado para tarea {notification.TaskId} → {notification.AssignedUserEmail}");
            }
            catch (Exception ex)
            {
                // Marcar este mensaje como fallido — SQS lo reintentará
                context.Logger.LogError(
                    $"[TaskNotifier] Error procesando mensaje {message.MessageId}: {ex.Message}");

                batchResponse.BatchItemFailures.Add(new SQSBatchResponse.BatchItemFailure
                {
                    ItemIdentifier = message.MessageId
                });
            }
        }

        return batchResponse;
    }

    private async Task SendEmailAsync(TaskNotificationEvent notification, ILambdaContext context)
    {
        var subject = notification.EventType switch
        {
            "TaskAssigned"      => $"📋 Nueva tarea asignada: {notification.TaskTitle}",
            "TaskStatusChanged" => $"🔄 Actualización de tarea: {notification.TaskTitle}",
            _                   => $"Notificación: {notification.TaskTitle}"
        };

        var htmlBody = BuildEmailBody(notification);

        var request = new SendEmailRequest
        {
            Source = _fromEmail,
            Destination = new Destination
            {
                ToAddresses = new List<string> { notification.AssignedUserEmail }
            },
            Message = new Message
            {
                Subject = new Content(subject),
                Body = new Body
                {
                    Html = new Content
                    {
                        Charset = "UTF-8",
                        Data    = htmlBody
                    }
                }
            }
        };

        await _sesClient.SendEmailAsync(request);
    }

    private string BuildEmailBody(TaskNotificationEvent n)
    {
        var dueDateStr = n.DueDate.HasValue
            ? n.DueDate.Value.ToString("dd/MM/yyyy")
            : "Sin fecha límite";

        var statusSection = n.EventType == "TaskStatusChanged"
            ? $"<p><strong>Estado:</strong> {n.OldStatus} → <strong>{n.NewStatus}</strong></p>"
            : $"<p><strong>Estado inicial:</strong> {n.NewStatus}</p>";

        return $"""
            <!DOCTYPE html>
            <html>
            <body style="font-family: Arial, sans-serif; max-width: 600px; margin: auto; padding: 20px;">
              <h2 style="color: #2563EB;">Sistema de Gestión de Proyectos</h2>
              <hr/>
              <h3>{(n.EventType == "TaskAssigned" ? "Se te ha asignado una tarea" : "Una tarea fue actualizada")}</h3>
              <p>Hola <strong>{n.AssignedUserName}</strong>,</p>
              <p>{(n.EventType == "TaskAssigned"
                    ? $"{n.AssignerName ?? "Un administrador"} te asignó la siguiente tarea:"
                    : $"La tarea fue actualizada en el proyecto <strong>{n.ProjectName}</strong>:")}</p>
              <div style="background:#F3F4F6; padding:16px; border-radius:8px; margin:16px 0;">
                <p><strong>Tarea:</strong> {n.TaskTitle}</p>
                <p><strong>Proyecto:</strong> {n.ProjectName}</p>
                {statusSection}
                <p><strong>Fecha límite:</strong> {dueDateStr}</p>
                {(n.TaskDescription != null ? $"<p><strong>Descripción:</strong> {n.TaskDescription}</p>" : "")}
              </div>
              <p style="color:#6B7280; font-size:12px;">Este es un correo automático, no responder.</p>
            </body>
            </html>
            """;
    }
}

/// <summary>
/// SNS envuelve el mensaje original en este sobre JSON.
/// El campo "Message" contiene el payload real que publicó tu backend.
/// </summary>
public class SnsMessageWrapper
{
    public string Type      { get; set; } = "";
    public string MessageId { get; set; } = "";
    public string Message   { get; set; } = "";  // ← Aquí está tu TaskNotificationEvent serializado
    public string Subject   { get; set; } = "";
    public string Timestamp { get; set; } = "";
}
```

### Paso 5.5: aws-lambda-tools-defaults.json

```json
{
  "profile": "",
  "region": "us-east-2",
  "configuration": "Release",
  "framework": "net8.0",
  "function-runtime": "dotnet8",
  "function-memory-size": 256,
  "function-timeout": 30,
  "function-handler": "TaskNotifierLambda::TaskNotifierLambda.Function::FunctionHandler"
}
```

### Paso 5.6: Deploy de la Lambda

```bash
# Instalar herramienta de deploy de Lambda para .NET (una sola vez)
dotnet tool install -g Amazon.Lambda.Tools

# Build y deploy
cd TaskNotifierLambda/src/TaskNotifierLambda

dotnet lambda deploy-function TaskNotifierLambda \
  --region us-east-2 \
  --function-role arn:aws:iam::<ACCOUNT_ID>:role/TaskNotifierLambdaRole \
  --environment-variables "SES_FROM_EMAIL=notificaciones@tudominio.com"
```

> **⚠️ Requisito SES:** El email en `SES_FROM_EMAIL` debe estar verificado en Amazon SES.
> ```bash
> aws ses verify-email-identity --email-address notificaciones@tudominio.com --region us-east-2
> # Revisa tu bandeja de entrada y confirma el email de verificación
> ```

---

## 6️⃣ Paso 6: Conectar Lambda con SQS (Event Source Mapping)

Este paso hace que Lambda se dispare automáticamente cuando lleguen mensajes a SQS.

```bash
aws lambda create-event-source-mapping \
  --function-name TaskNotifierLambda \
  --event-source-arn arn:aws:sqs:us-east-2:<ACCOUNT_ID>:task-email-queue \
  --batch-size 5 \
  --region us-east-2 \
  --function-response-types ReportBatchItemFailures
```

**Parámetros importantes:**

| Parámetro | Valor | ¿Por qué? |
|---|---|---|
| `batch-size` | 5 | Lambda recibe hasta 5 mensajes por invocación |
| `ReportBatchItemFailures` | Activado | Permite que Lambda reporte mensajes fallidos individualmente sin rechazar todo el batch |

**Verificar que se creó:**
```bash
aws lambda list-event-source-mappings \
  --function-name TaskNotifierLambda \
  --region us-east-2
```

El estado debe pasar de `Creating` a `Enabled` en ~30 segundos.

---

## 7️⃣ Paso 7: Migrar el Backend (.NET)

Ahora modificamos `TaskService.cs` para publicar en SNS en lugar de invocar Lambda directamente.

### Paso 7.1: Instalar el paquete de SNS

```bash
cd tu-proyecto-backend/
dotnet add package AWSSDK.SimpleNotificationService
```

### Paso 7.2: Actualizar Program.cs

Agrega el cliente de SNS y elimina el de Lambda (ya no lo necesitas):

```csharp
// Program.cs — REEMPLAZAR esto:
builder.Services.AddAWSService<IAmazonLambda>();  // ← ELIMINAR

// POR esto:
builder.Services.AddAWSService<IAmazonSimpleNotificationService>();  // ← AGREGAR
```

Asegúrate de tener el using necesario:
```csharp
using Amazon.SimpleNotificationService;
```

### Paso 7.3: Actualizar TaskService.cs

Reemplaza la dependencia de `IAmazonLambda` por `IAmazonSimpleNotificationService` y actualiza `SendNotificationAsync`:

```csharp
// TaskService.cs — Cambios necesarios

// 1. ELIMINAR el using de Lambda:
// using Amazon.Lambda;
// using Amazon.Lambda.Model;

// 2. AGREGAR el using de SNS:
using Amazon.SimpleNotificationService;
using Amazon.SimpleNotificationService.Model;

public class TaskService : ITaskService
{
    private readonly ITaskRepository _taskRepository;
    private readonly IProjectService _projectService;
    private readonly IUserContextAccessor _userContextAccessor;
    private readonly IMapper _mapper;
    private readonly IAmazonSimpleNotificationService _snsClient;  // ← CAMBIO
    private readonly UserManager<ApplicationUser> _userManager;
    private readonly ApplicationDbContext _dbContext;
    
    // ← Leer el ARN desde configuración, no hardcodearlo
    private readonly string _snsTopicArn;

    public TaskService(
        ITaskRepository taskRepository,
        IProjectService projectService,
        IUserContextAccessor userContextAccessor,
        IMapper mapper,
        IAmazonSimpleNotificationService snsClient,        // ← CAMBIO
        UserManager<ApplicationUser> userManager,
        ApplicationDbContext dbContext,
        IConfiguration configuration)                      // ← AGREGAR
    {
        _taskRepository = taskRepository;
        _projectService = projectService;
        _userContextAccessor = userContextAccessor;
        _mapper = mapper;
        _snsClient = snsClient;                            // ← CAMBIO
        _userManager = userManager;
        _dbContext = dbContext;
        _snsTopicArn = configuration["AWS:SnsTopicArn"]
                       ?? throw new Exception("AWS:SnsTopicArn no configurado");
    }

    // ... (el resto de métodos permanece igual)

    /// <summary>
    /// NUEVA implementación: publica en SNS en lugar de invocar Lambda directamente.
    /// SNS distribuye el mensaje a todas las colas suscritas (SQS).
    /// Fire-and-forget: si SNS falla, solo se loggea.
    /// </summary>
    private async Task SendNotificationAsync(EntityTask task, string eventType, string? oldStatus)
    {
        try
        {
            var project      = await _dbContext.Projects.AsNoTracking()
                                    .FirstOrDefaultAsync(p => p.Id == task.ProjectId);
            var assignedUser = await _userManager.FindByIdAsync(task.AssignedToId!);

            if (project == null || assignedUser == null || string.IsNullOrWhiteSpace(assignedUser.Email))
            {
                Console.WriteLine($"[TaskService] Notificación omitida para tarea {task.Id}: datos incompletos.");
                return;
            }

            var currentUserId = _userContextAccessor.GetCurrentUserId();
            var currentUser   = await _userManager.FindByIdAsync(currentUserId);

            var payload = new
            {
                EventType         = eventType,
                TaskId            = task.Id.ToString(),
                TaskTitle         = task.Title,
                TaskDescription   = task.Description,
                ProjectName       = project.Name,
                AssignedUserEmail = assignedUser.Email,
                AssignedUserName  = assignedUser.UserName ?? assignedUser.Email,
                AssignerName      = currentUser?.UserName,
                OldStatus         = oldStatus,
                NewStatus         = task.Status,
                DueDate           = task.DueDate
            };

            // Publicar en SNS — SNS lo distribuye automáticamente a SQS
            var publishRequest = new PublishRequest
            {
                TopicArn          = _snsTopicArn,
                Message           = JsonSerializer.Serialize(payload),
                Subject           = $"TaskEvent:{eventType}",  // Útil para filtros en el futuro
                MessageAttributes = new Dictionary<string, MessageAttributeValue>
                {
                    // Atributo para filtros de suscripción (útil a futuro)
                    ["EventType"] = new MessageAttributeValue
                    {
                        DataType    = "String",
                        StringValue = eventType
                    }
                }
            };

            await _snsClient.PublishAsync(publishRequest);

            Console.WriteLine($"[TaskService] Evento '{eventType}' publicado en SNS para tarea {task.Id}");
        }
        catch (Exception ex)
        {
            // Intencional: un fallo en notificaciones NO revierte la transacción principal
            Console.WriteLine($"[TaskService] Error al publicar en SNS para tarea {task.Id}: {ex.GetType().Name}: {ex.Message}");
        }
    }
}
```

### Paso 7.4: Actualizar appsettings.json

```json
{
  "AWS": {
    "Region": "us-east-2",
    "SnsTopicArn": "arn:aws:sns:us-east-2:<ACCOUNT_ID>:task-events-topic"
  }
}
```

> En producción este valor viene de una variable de entorno en ECS (ver Paso 8), no del appsettings.

---

## 8️⃣ Paso 8: Variables de Entorno en ECS

Tu Task Definition de ECS necesita la variable `AWS__SnsTopicArn` (doble guión bajo = sección en .NET).

**Opción A: Desde AWS Secrets Manager (recomendado):**

```bash
aws secretsmanager create-secret \
  --name sns-topic-arn \
  --secret-string "arn:aws:sns:us-east-2:<ACCOUNT_ID>:task-events-topic"
```

Y en tu `task-definition.json` agrega:
```json
"secrets": [
  {
    "name": "AWS__SnsTopicArn",
    "valueFrom": "arn:aws:secretsmanager:us-east-2:<ACCOUNT_ID>:secret:sns-topic-arn"
  }
]
```

**Opción B: Variable de entorno directa (más simple para desarrollo):**

En `task-definition.json`:
```json
"environment": [
  {
    "name": "AWS__SnsTopicArn",
    "value": "arn:aws:sns:us-east-2:<ACCOUNT_ID>:task-events-topic"
  }
]
```

Luego re-registra la task definition y actualiza el servicio:
```bash
aws ecs register-task-definition --cli-input-json file://task-definition.json

aws ecs update-service \
  --cluster gestion-proyectos-cluster \
  --service gestion-proyectos-service \
  --force-new-deployment
```

---

## 📊 Monitoreo y Troubleshooting

### Ver logs de la Lambda

```bash
# Logs en tiempo real
aws logs tail /aws/lambda/TaskNotifierLambda --follow --region us-east-2

# Buscar errores específicos
aws logs filter-log-events \
  --log-group-name /aws/lambda/TaskNotifierLambda \
  --filter-pattern "Error" \
  --region us-east-2
```

### Ver mensajes en la DLQ (mensajes fallidos)

```bash
# Ver cuántos mensajes hay en la DLQ
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-2.amazonaws.com/<ACCOUNT_ID>/task-email-dlq \
  --attribute-names ApproximateNumberOfMessages \
  --region us-east-2

# Leer un mensaje de la DLQ para diagnóstico
aws sqs receive-message \
  --queue-url https://sqs.us-east-2.amazonaws.com/<ACCOUNT_ID>/task-email-dlq \
  --region us-east-2
```

### Prueba Manual del Flujo Completo

```bash
# 1. Publicar directamente en SNS (simula lo que haría tu backend)
aws sns publish \
  --topic-arn arn:aws:sns:us-east-2:<ACCOUNT_ID>:task-events-topic \
  --message '{"EventType":"TaskAssigned","TaskId":"test-001","TaskTitle":"Prueba manual","ProjectName":"Mi Proyecto","AssignedUserEmail":"tu@email.com","AssignedUserName":"Tú","NewStatus":"PENDING"}' \
  --subject "TaskEvent:TaskAssigned" \
  --region us-east-2

# 2. Verificar que llegó a SQS (debería procesarse en segundos)
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-2.amazonaws.com/<ACCOUNT_ID>/task-email-queue \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --region us-east-2

# 3. Revisar logs de Lambda para ver si procesó el mensaje
aws logs tail /aws/lambda/TaskNotifierLambda --follow --region us-east-2
```

### CloudWatch Alarm para la DLQ

```bash
# Alerta cuando la DLQ recibe mensajes (significa que hay errores)
aws cloudwatch put-metric-alarm \
  --alarm-name TaskNotifierDLQAlert \
  --alarm-description "Hay mensajes fallidos en la DLQ del notificador de tareas" \
  --metric-name ApproximateNumberOfMessagesVisible \
  --namespace AWS/SQS \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --dimensions Name=QueueName,Value=task-email-dlq \
  --region us-east-2
```

---

### Troubleshooting Común

**❌ Problema: Lambda no se ejecuta cuando llegan mensajes a SQS**

```bash
# Verificar que el Event Source Mapping está Enabled
aws lambda list-event-source-mappings \
  --function-name TaskNotifierLambda \
  --region us-east-2

# Si está Disabled, activarlo
aws lambda update-event-source-mapping \
  --uuid <UUID_DEL_MAPPING> \
  --enabled \
  --region us-east-2
```

**❌ Problema: Error "Email address is not verified" en SES**

SES en modo Sandbox solo puede enviar a emails verificados. Tienes dos opciones:
- Verificar el email destino: `aws ses verify-email-identity --email-address destino@email.com`
- Solicitar salida del Sandbox (para producción): SES → Account dashboard → Request production access

**❌ Problema: Lambda falla con "Access Denied" al SQS**

```bash
# Verificar permisos del role de Lambda
aws iam list-attached-role-policies --role-name TaskNotifierLambdaRole

# Verificar que el role tiene SQS permissions
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::<ACCOUNT_ID>:role/TaskNotifierLambdaRole \
  --action-names sqs:ReceiveMessage sqs:DeleteMessage \
  --resource-arns arn:aws:sqs:us-east-2:<ACCOUNT_ID>:task-email-queue
```

**❌ Problema: El backend falla con "Access Denied" al publicar en SNS**

Verifica que el ECS Task Role tiene la política `ECSBackendSNSPolicy` adjuntada:
```bash
aws iam list-attached-role-policies --role-name ecsTaskExecutionRole
```

---

## 💰 Costos Estimados

Para un proyecto de portafolio con bajo tráfico:

| Servicio | Uso estimado | Costo/mes |
|---|---|---|
| **SNS** | 10,000 publicaciones | $0.00 (primer millón gratis) |
| **SQS** | 10,000 mensajes | $0.00 (primer millón gratis) |
| **Lambda** | 10,000 invocaciones × 256MB × 2s | ~$0.00 (dentro de free tier) |
| **SES** | 1,000 emails | $0.10 |
| **CloudWatch Logs** | < 5GB | $0.00 (free tier) |
| **Total** | | **~$0.10/mes** |

---

## 🎯 Resumen de lo que Construiste

```
Backend .NET (ECS Fargate)
        │
        │  sns.PublishAsync()  [fire-and-forget]
        ▼
  SNS Topic: task-events-topic
        │
        │  Suscripción automática (fan-out)
        ▼
  SQS Queue: task-email-queue
        │  (con DLQ para mensajes fallidos)
        │
        │  Event Source Mapping (trigger automático)
        ▼
  Lambda: TaskNotifierLambda (.NET 8)
        │  - Deserializa el sobre SNS
        │  - Construye email HTML
        │  - Envía vía SES
        │  - Reporta fallos individuales (BatchItemFailures)
        ▼
  Amazon SES → Email al usuario asignado
```

**Archivos modificados en el backend:**
- `Program.cs` → cambio `IAmazonLambda` por `IAmazonSimpleNotificationService`
- `TaskService.cs` → `SendNotificationAsync` ahora publica en SNS
- `appsettings.json` → agrega `AWS:SnsTopicArn`
- `task-definition.json` → agrega variable `AWS__SnsTopicArn`

**Nuevos recursos AWS creados:**
- SNS Topic: `task-events-topic`
- SQS Queue: `task-email-queue`
- SQS DLQ: `task-email-dlq`
- Lambda: `TaskNotifierLambda`
- IAM Role: `TaskNotifierLambdaRole`
- CloudWatch Alarm: `TaskNotifierDLQAlert`

---

## 📚 Próximos Pasos

Una vez que tengas esto funcionando:

1. **Load Balancer:** Agregar ALB frente a ECS para dominio personalizado y HTTPS
2. **Route 53:** Dominio personalizado apuntando al ALB
3. **SES Producción:** Solicitar salida del Sandbox para enviar a cualquier email
4. **Segunda suscripción SNS:** Agregar otra SQS Queue + Lambda para notificaciones push o WebSocket
5. **X-Ray:** Habilitar tracing en Lambda para ver el flujo completo end-to-end

---

**¡Listo! Ahora tienes SNS, SQS y Lambda integrados profesionalmente en tu proyecto de gestión. 🚀**
