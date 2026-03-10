# 🚀 AWS Lambda - Guía Completa para Sistema de Gestión de Proyectos

## 📋 Tabla de Contenidos

1. [Introducción y Arquitectura](#introducción)
2. [Lambda 1: Procesamiento de Imágenes de Perfil](#lambda-1-procesamiento-de-imágenes)
3. [Lambda 2: Notificaciones de Tareas por Email](#lambda-2-notificaciones-email)
4. [Lambda 3: Limpieza Automática de Proyectos](#lambda-3-limpieza-automática)
5. [Deployment y Testing](#deployment-y-testing)
6. [Monitoreo y Troubleshooting](#monitoreo)

---

## 🎯 Introducción

### ¿Qué Vamos a Construir?

Tres funciones Lambda que extenderán tu aplicación:

| Lambda | Trigger | Propósito | Runtime |
|--------|---------|-----------|---------|
| **ImageProcessor** | S3 Upload | Redimensionar y optimizar imágenes de perfil | .NET 8 |
| **TaskNotifier** | EventBridge | Notificar por email asignaciones de tareas | .NET 8 |
| **ProjectCleaner** | CloudWatch Schedule | Archivar/eliminar proyectos viejos | .NET 8 |

### Arquitectura de Integración

```
┌─────────────────────────────────────────────────────────────┐
│                    TU APLICACIÓN ACTUAL                      │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  Frontend (S3)  →  Backend (ECS)  →  Database (RDS)         │
│                         ↓                                     │
│                    S3 (uploads)                              │
│                                                               │
└───────────────────────┬─────────────────────────────────────┘
                        │
        ┌───────────────┴────────────────┐
        │                                 │
        ↓                                 ↓
┌───────────────┐              ┌──────────────────┐
│  Lambda 1     │              │  Lambda 2        │
│  Image        │              │  Email           │
│  Processor    │              │  Notifications   │
└───────────────┘              └──────────────────┘
        ↓                                 ↓
   S3 Thumbnail                        SES Email
        
                ┌──────────────────┐
                │  Lambda 3        │
                │  Project         │
                │  Cleaner         │
                └──────────────────┘
                         ↓
                    RDS Query
```

---

## 🖼️ Lambda 1: Procesamiento de Imágenes de Perfil

### Objetivo

Cuando un usuario sube una imagen de perfil a S3, automáticamente:
1. Crear thumbnail (150x150)
2. Crear versión optimizada (500x500)
3. Aplicar compresión JPEG
4. Guardar en carpetas separadas

### Estructura del Proyecto

```bash
ImageProcessorLambda/
├── src/
│   └── ImageProcessorLambda/
│       ├── Function.cs              # Handler principal
│       ├── ImageProcessorLambda.csproj
│       ├── Models/
│       │   └── S3EventModels.cs
│       └── Services/
│           └── ImageService.cs
├── test/
│   └── ImageProcessorLambda.Tests/
└── aws-lambda-tools-defaults.json
```

### Paso 1: Crear el Proyecto Lambda

```bash
# Navegar a tu directorio de desarrollo
cd ~/projects

# Crear solución Lambda
dotnet new lambda.EmptyFunction -n ImageProcessorLambda -o ImageProcessorLambda/src/ImageProcessorLambda

cd ImageProcessorLambda/src/ImageProcessorLambda

# Instalar paquetes necesarios
dotnet add package AWSSDK.S3
dotnet add package Amazon.Lambda.S3Events
dotnet add package SixLabors.ImageSharp --version 3.1.0
dotnet add package Amazon.Lambda.Serialization.SystemTextJson
```

### Paso 2: ImageProcessorLambda.csproj

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <GenerateRuntimeConfigurationFiles>true</GenerateRuntimeConfigurationFiles>
    <AWSProjectType>Lambda</AWSProjectType>
    <CopyLocalLockFileAssemblies>true</CopyLocalLockFileAssemblies>
    <PublishReadyToRun>true</PublishReadyToRun>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Amazon.Lambda.Core" Version="2.2.0" />
    <PackageReference Include="Amazon.Lambda.S3Events" Version="3.1.0" />
    <PackageReference Include="Amazon.Lambda.Serialization.SystemTextJson" Version="2.4.0" />
    <PackageReference Include="AWSSDK.S3" Version="3.7.307" />
    <PackageReference Include="SixLabors.ImageSharp" Version="3.1.0" />
  </ItemGroup>
</Project>
```

### Paso 3: Services/ImageService.cs

```csharp
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Processing;
using SixLabors.ImageSharp.Formats.Jpeg;

namespace ImageProcessorLambda.Services
{
    public class ImageService
    {
        public async Task<MemoryStream> ResizeImageAsync(
            Stream inputStream, 
            int width, 
            int height,
            int quality = 85)
        {
            using var image = await Image.LoadAsync(inputStream);
            
            // Redimensionar manteniendo aspect ratio
            image.Mutate(x => x.Resize(new ResizeOptions
            {
                Size = new Size(width, height),
                Mode = ResizeMode.Max // Mantiene proporción
            }));

            var outputStream = new MemoryStream();
            
            // Comprimir como JPEG con calidad especificada
            var encoder = new JpegEncoder { Quality = quality };
            await image.SaveAsJpegAsync(outputStream, encoder);
            
            outputStream.Position = 0;
            return outputStream;
        }

        public async Task<MemoryStream> CreateThumbnailAsync(
            Stream inputStream,
            int size = 150)
        {
            using var image = await Image.LoadAsync(inputStream);
            
            // Crop al centro para thumbnail cuadrado
            image.Mutate(x => x
                .Resize(new ResizeOptions
                {
                    Size = new Size(size, size),
                    Mode = ResizeMode.Crop
                })
            );

            var outputStream = new MemoryStream();
            var encoder = new JpegEncoder { Quality = 90 };
            await image.SaveAsJpegAsync(outputStream, encoder);
            
            outputStream.Position = 0;
            return outputStream;
        }
    }
}
```

### Paso 4: Function.cs (Handler Principal)

```csharp
using Amazon.Lambda.Core;
using Amazon.Lambda.S3Events;
using Amazon.S3;
using Amazon.S3.Model;
using ImageProcessorLambda.Services;

// Assembly attribute to enable the Lambda function's JSON input to be converted into a .NET class.
[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace ImageProcessorLambda;

public class Function
{
    private readonly IAmazonS3 _s3Client;
    private readonly ImageService _imageService;

    // Constructor sin parámetros para Lambda (usa cliente default)
    public Function()
    {
        _s3Client = new AmazonS3Client();
        _imageService = new ImageService();
    }

    // Constructor para testing (permite inyección de dependencias)
    public Function(IAmazonS3 s3Client, ImageService imageService)
    {
        _s3Client = s3Client;
        _imageService = imageService;
    }

    public async Task FunctionHandler(S3Event s3Event, ILambdaContext context)
    {
        foreach (var record in s3Event.Records)
        {
            try
            {
                var bucket = record.S3.Bucket.Name;
                var key = record.S3.Object.Key;

                context.Logger.LogInformation($"Processing: {bucket}/{key}");

                // Solo procesar archivos en la carpeta profile-images
                if (!key.StartsWith("profile-images/"))
                {
                    context.Logger.LogInformation($"Skipping file not in profile-images/: {key}");
                    continue;
                }

                // Evitar procesamiento recursivo de thumbnails/optimized
                if (key.Contains("/thumbnails/") || key.Contains("/optimized/"))
                {
                    context.Logger.LogInformation($"Skipping already processed image: {key}");
                    continue;
                }

                // Descargar imagen original
                var getObjectResponse = await _s3Client.GetObjectAsync(bucket, key);
                
                // Crear thumbnail (150x150)
                using var thumbnailStream = await _imageService.CreateThumbnailAsync(
                    getObjectResponse.ResponseStream, 
                    150
                );
                
                var thumbnailKey = key.Replace("profile-images/", "profile-images/thumbnails/");
                await UploadToS3Async(bucket, thumbnailKey, thumbnailStream, "image/jpeg");
                context.Logger.LogInformation($"Thumbnail created: {thumbnailKey}");

                // Descargar de nuevo para versión optimizada (S3 stream solo se puede leer una vez)
                getObjectResponse = await _s3Client.GetObjectAsync(bucket, key);
                
                // Crear versión optimizada (500x500, quality 85)
                using var optimizedStream = await _imageService.ResizeImageAsync(
                    getObjectResponse.ResponseStream,
                    500,
                    500,
                    85
                );
                
                var optimizedKey = key.Replace("profile-images/", "profile-images/optimized/");
                await UploadToS3Async(bucket, optimizedKey, optimizedStream, "image/jpeg");
                context.Logger.LogInformation($"Optimized version created: {optimizedKey}");

                context.Logger.LogInformation($"Successfully processed: {key}");
            }
            catch (Exception ex)
            {
                context.Logger.LogError($"Error processing {record.S3.Object.Key}: {ex.Message}");
                throw; // Re-throw para que Lambda marque como fallido
            }
        }
    }

    private async Task UploadToS3Async(string bucket, string key, Stream stream, string contentType)
    {
        var putRequest = new PutObjectRequest
        {
            BucketName = bucket,
            Key = key,
            InputStream = stream,
            ContentType = contentType,
            CannedACL = S3CannedACL.Private
        };

        await _s3Client.PutObjectAsync(putRequest);
    }
}
```

### Paso 5: Configuración de Lambda (aws-lambda-tools-defaults.json)

```json
{
  "Information": [
    "This file provides default values for the deployment wizard inside Visual Studio and the AWS Lambda commands added to the .NET Core CLI.",
    "To learn more about the Lambda commands with the .NET Core CLI execute the following command at the command line in the project root directory.",
    "dotnet lambda help",
    "All the command line options for the Lambda command can be specified in this file."
  ],
  "profile": "default",
  "region": "us-east-1",
  "configuration": "Release",
  "function-architecture": "x86_64",
  "function-runtime": "dotnet8",
  "function-memory-size": 512,
  "function-timeout": 60,
  "function-handler": "ImageProcessorLambda::ImageProcessorLambda.Function::FunctionHandler"
}
```

### Paso 6: Deploy de Lambda

```bash
# Instalar herramientas Lambda si no las tienes
dotnet tool install -g Amazon.Lambda.Tools

# Deploy desde el directorio del proyecto
cd ~/projects/ImageProcessorLambda/src/ImageProcessorLambda

# Crear función Lambda
dotnet lambda deploy-function ImageProcessorLambda \
    --function-role <TU_LAMBDA_EXECUTION_ROLE_ARN> \
    --region us-east-1

# O usar el wizard interactivo
dotnet lambda deploy-function
```

**IMPORTANTE: Necesitarás crear un IAM Role antes. Ver sección "IAM Roles" más abajo.**

### Paso 7: Configurar S3 Trigger

Desde AWS Console:

1. **S3 Console** → Tu bucket → **Properties** → **Event notifications**
2. **Create event notification**:
   - **Name**: `ProcessProfileImages`
   - **Event types**: `PUT` (All object create events)
   - **Prefix**: `profile-images/`
   - **Suffix**: `.jpg, .jpeg, .png` (puedes configurar múltiples)
   - **Destination**: Lambda function
   - **Lambda function**: `ImageProcessorLambda`

O via AWS CLI:

```bash
# Permitir que S3 invoque tu Lambda
aws lambda add-permission \
    --function-name ImageProcessorLambda \
    --statement-id S3InvokePermission \
    --action lambda:InvokeFunction \
    --principal s3.amazonaws.com \
    --source-arn arn:aws:s3:::TU-BUCKET-NAME

# Configurar notificación en S3
aws s3api put-bucket-notification-configuration \
    --bucket TU-BUCKET-NAME \
    --notification-configuration file://s3-notification.json
```

**s3-notification.json:**

```json
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "ProcessProfileImages",
      "LambdaFunctionArn": "arn:aws:lambda:us-east-1:ACCOUNT_ID:function:ImageProcessorLambda",
      "Events": ["s3:ObjectCreated:Put"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {
              "Name": "prefix",
              "Value": "profile-images/"
            }
          ]
        }
      }
    }
  ]
}
```

### Testing de Lambda 1

**Opción 1: Upload manual via Console**

1. Sube una imagen a `s3://TU-BUCKET/profile-images/test.jpg`
2. Verifica que se crearon:
   - `s3://TU-BUCKET/profile-images/thumbnails/test.jpg`
   - `s3://TU-BUCKET/profile-images/optimized/test.jpg`

**Opción 2: Test con evento simulado**

```bash
# Crear test event
cat > test-event.json << EOF
{
  "Records": [
    {
      "s3": {
        "bucket": {
          "name": "TU-BUCKET-NAME"
        },
        "object": {
          "key": "profile-images/test-image.jpg"
        }
      }
    }
  ]
}
EOF

# Invocar Lambda
aws lambda invoke \
    --function-name ImageProcessorLambda \
    --payload file://test-event.json \
    --cli-binary-format raw-in-base64-out \
    response.json

cat response.json
```

---

## 📧 Lambda 2: Notificaciones de Tareas por Email

### Objetivo

Enviar emails automáticos cuando:
- Se asigna una tarea a un usuario
- Se cambia el estado de una tarea
- Una tarea está próxima a vencer

### Arquitectura de Integración

```
Backend (ECS)  →  EventBridge  →  Lambda  →  SES  →  Email
```

### Paso 1: Setup de Amazon SES

**IMPORTANTE**: Primero debes configurar SES.

```bash
# 1. Verificar email del remitente
aws ses verify-email-identity --email-address noreply@tudominio.com

# 2. Verificar emails de destinatarios (SANDBOX mode)
# En producción, debes salir del sandbox
aws ses verify-email-identity --email-address usuario@ejemplo.com

# 3. Revisar status
aws ses get-identity-verification-attributes \
    --identities noreply@tudominio.com
```

**Salir del Sandbox (Producción):**
1. AWS Console → SES → Account dashboard
2. Request production access
3. Completa el formulario explicando tu caso de uso

### Paso 2: Crear Proyecto Lambda

```bash
cd ~/projects
dotnet new lambda.EmptyFunction -n TaskNotifierLambda -o TaskNotifierLambda/src/TaskNotifierLambda

cd TaskNotifierLambda/src/TaskNotifierLambda

# Instalar paquetes
dotnet add package AWSSDK.SimpleEmail
dotnet add package Amazon.Lambda.Core
dotnet add package Amazon.Lambda.Serialization.SystemTextJson
```

### Paso 3: TaskNotifierLambda.csproj

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <GenerateRuntimeConfigurationFiles>true</GenerateRuntimeConfigurationFiles>
    <AWSProjectType>Lambda</AWSProjectType>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Amazon.Lambda.Core" Version="2.2.0" />
    <PackageReference Include="Amazon.Lambda.Serialization.SystemTextJson" Version="2.4.0" />
    <PackageReference Include="AWSSDK.SimpleEmail" Version="3.7.400" />
  </ItemGroup>
</Project>
```

### Paso 4: Models/TaskNotificationEvent.cs

```csharp
namespace TaskNotifierLambda.Models
{
    public class TaskNotificationEvent
    {
        public string EventType { get; set; } = string.Empty; // "TaskAssigned", "TaskStatusChanged", "TaskDueSoon"
        public string TaskId { get; set; } = string.Empty;
        public string TaskTitle { get; set; } = string.Empty;
        public string? TaskDescription { get; set; }
        public string ProjectName { get; set; } = string.Empty;
        public string AssignedUserEmail { get; set; } = string.Empty;
        public string AssignedUserName { get; set; } = string.Empty;
        public string? AssignerName { get; set; }
        public string? OldStatus { get; set; }
        public string? NewStatus { get; set; }
        public DateTime? DueDate { get; set; }
    }
}
```

### Paso 5: Services/EmailService.cs

```csharp
using Amazon.SimpleEmail;
using Amazon.SimpleEmail.Model;
using TaskNotifierLambda.Models;

namespace TaskNotifierLambda.Services
{
    public class EmailService
    {
        private readonly IAmazonSimpleEmailService _sesClient;
        private readonly string _senderEmail;

        public EmailService(IAmazonSimpleEmailService sesClient, string senderEmail)
        {
            _sesClient = sesClient;
            _senderEmail = senderEmail;
        }

        public async Task SendTaskAssignedEmailAsync(TaskNotificationEvent evt)
        {
            var subject = $"Nueva tarea asignada: {evt.TaskTitle}";
            var htmlBody = GenerateTaskAssignedHtml(evt);

            await SendEmailAsync(evt.AssignedUserEmail, subject, htmlBody);
        }

        public async Task SendTaskStatusChangedEmailAsync(TaskNotificationEvent evt)
        {
            var subject = $"Cambio de estado en tarea: {evt.TaskTitle}";
            var htmlBody = GenerateStatusChangedHtml(evt);

            await SendEmailAsync(evt.AssignedUserEmail, subject, htmlBody);
        }

        public async Task SendTaskDueSoonEmailAsync(TaskNotificationEvent evt)
        {
            var subject = $"⚠️ Tarea próxima a vencer: {evt.TaskTitle}";
            var htmlBody = GenerateTaskDueSoonHtml(evt);

            await SendEmailAsync(evt.AssignedUserEmail, subject, htmlBody);
        }

        private async Task SendEmailAsync(string recipientEmail, string subject, string htmlBody)
        {
            var sendRequest = new SendEmailRequest
            {
                Source = _senderEmail,
                Destination = new Destination
                {
                    ToAddresses = new List<string> { recipientEmail }
                },
                Message = new Message
                {
                    Subject = new Content(subject),
                    Body = new Body
                    {
                        Html = new Content
                        {
                            Charset = "UTF-8",
                            Data = htmlBody
                        }
                    }
                }
            };

            await _sesClient.SendEmailAsync(sendRequest);
        }

        private string GenerateTaskAssignedHtml(TaskNotificationEvent evt)
        {
            return $@"
<!DOCTYPE html>
<html>
<head>
    <style>
        body {{ font-family: Arial, sans-serif; line-height: 1.6; color: #333; }}
        .container {{ max-width: 600px; margin: 0 auto; padding: 20px; }}
        .header {{ background-color: #4CAF50; color: white; padding: 20px; text-align: center; }}
        .content {{ background-color: #f9f9f9; padding: 20px; margin-top: 20px; }}
        .task-details {{ background-color: white; padding: 15px; margin: 15px 0; border-left: 4px solid #4CAF50; }}
        .footer {{ text-align: center; margin-top: 20px; font-size: 12px; color: #666; }}
        .button {{ background-color: #4CAF50; color: white; padding: 10px 20px; text-decoration: none; display: inline-block; margin: 15px 0; }}
    </style>
</head>
<body>
    <div class='container'>
        <div class='header'>
            <h2>Nueva Tarea Asignada</h2>
        </div>
        <div class='content'>
            <p>Hola {evt.AssignedUserName},</p>
            <p><strong>{evt.AssignerName}</strong> te ha asignado una nueva tarea en el proyecto <strong>{evt.ProjectName}</strong>.</p>
            
            <div class='task-details'>
                <h3>{evt.TaskTitle}</h3>
                {(string.IsNullOrEmpty(evt.TaskDescription) ? "" : $"<p>{evt.TaskDescription}</p>")}
                {(evt.DueDate.HasValue ? $"<p><strong>Fecha límite:</strong> {evt.DueDate.Value:dd/MM/yyyy}</p>" : "")}
            </div>
            
            <p>Accede a la plataforma para ver más detalles y comenzar a trabajar en esta tarea.</p>
            <a href='https://tuapp.com/tasks/{evt.TaskId}' class='button'>Ver Tarea</a>
        </div>
        <div class='footer'>
            <p>Este es un mensaje automático del Sistema de Gestión de Proyectos.</p>
        </div>
    </div>
</body>
</html>";
        }

        private string GenerateStatusChangedHtml(TaskNotificationEvent evt)
        {
            return $@"
<!DOCTYPE html>
<html>
<head>
    <style>
        body {{ font-family: Arial, sans-serif; line-height: 1.6; color: #333; }}
        .container {{ max-width: 600px; margin: 0 auto; padding: 20px; }}
        .header {{ background-color: #2196F3; color: white; padding: 20px; text-align: center; }}
        .content {{ background-color: #f9f9f9; padding: 20px; margin-top: 20px; }}
        .status-change {{ background-color: white; padding: 15px; margin: 15px 0; border-left: 4px solid #2196F3; }}
    </style>
</head>
<body>
    <div class='container'>
        <div class='header'>
            <h2>Cambio de Estado en Tarea</h2>
        </div>
        <div class='content'>
            <p>Hola {evt.AssignedUserName},</p>
            <p>El estado de tu tarea <strong>{evt.TaskTitle}</strong> ha cambiado.</p>
            
            <div class='status-change'>
                <p><strong>Estado anterior:</strong> {evt.OldStatus}</p>
                <p><strong>Nuevo estado:</strong> {evt.NewStatus}</p>
            </div>
            
            <p>Proyecto: <strong>{evt.ProjectName}</strong></p>
        </div>
    </div>
</body>
</html>";
        }

        private string GenerateTaskDueSoonHtml(TaskNotificationEvent evt)
        {
            var daysRemaining = (evt.DueDate!.Value - DateTime.UtcNow).Days;
            
            return $@"
<!DOCTYPE html>
<html>
<head>
    <style>
        body {{ font-family: Arial, sans-serif; line-height: 1.6; color: #333; }}
        .container {{ max-width: 600px; margin: 0 auto; padding: 20px; }}
        .header {{ background-color: #FF9800; color: white; padding: 20px; text-align: center; }}
        .warning {{ background-color: #fff3cd; padding: 15px; margin: 15px 0; border-left: 4px solid #FF9800; }}
    </style>
</head>
<body>
    <div class='container'>
        <div class='header'>
            <h2>⚠️ Tarea Próxima a Vencer</h2>
        </div>
        <div class='content'>
            <p>Hola {evt.AssignedUserName},</p>
            
            <div class='warning'>
                <h3>{evt.TaskTitle}</h3>
                <p><strong>Proyecto:</strong> {evt.ProjectName}</p>
                <p><strong>Vence en:</strong> {daysRemaining} día(s) ({evt.DueDate.Value:dd/MM/yyyy})</p>
            </div>
            
            <p>Por favor, revisa el progreso de esta tarea y actualiza su estado si es necesario.</p>
        </div>
    </div>
</body>
</html>";
        }
    }
}
```

### Paso 6: Function.cs

```csharp
using Amazon.Lambda.Core;
using Amazon.SimpleEmail;
using TaskNotifierLambda.Models;
using TaskNotifierLambda.Services;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace TaskNotifierLambda;

public class Function
{
    private readonly EmailService _emailService;

    public Function()
    {
        var sesClient = new AmazonSimpleEmailServiceClient();
        var senderEmail = Environment.GetEnvironmentVariable("SENDER_EMAIL") 
            ?? "noreply@tudominio.com";
        
        _emailService = new EmailService(sesClient, senderEmail);
    }

    public async Task FunctionHandler(TaskNotificationEvent evt, ILambdaContext context)
    {
        context.Logger.LogInformation($"Processing notification event: {evt.EventType} for task {evt.TaskId}");

        try
        {
            switch (evt.EventType)
            {
                case "TaskAssigned":
                    await _emailService.SendTaskAssignedEmailAsync(evt);
                    context.Logger.LogInformation($"Task assigned email sent to {evt.AssignedUserEmail}");
                    break;

                case "TaskStatusChanged":
                    await _emailService.SendTaskStatusChangedEmailAsync(evt);
                    context.Logger.LogInformation($"Status changed email sent to {evt.AssignedUserEmail}");
                    break;

                case "TaskDueSoon":
                    await _emailService.SendTaskDueSoonEmailAsync(evt);
                    context.Logger.LogInformation($"Due soon email sent to {evt.AssignedUserEmail}");
                    break;

                default:
                    context.Logger.LogWarning($"Unknown event type: {evt.EventType}");
                    break;
            }
        }
        catch (Exception ex)
        {
            context.Logger.LogError($"Error sending email: {ex.Message}");
            throw;
        }
    }
}
```

### Paso 7: Deploy Lambda 2

```bash
cd ~/projects/TaskNotifierLambda/src/TaskNotifierLambda

dotnet lambda deploy-function TaskNotifierLambda \
    --function-role <TU_LAMBDA_EXECUTION_ROLE_ARN> \
    --region us-east-1 \
    --environment-variables SENDER_EMAIL=noreply@tudominio.com
```

### Paso 8: Integración con tu Backend (ECS)

Agrega un método en tu `TaskService.cs` para invocar Lambda:

```csharp
// En TaskService.cs

using Amazon.Lambda;
using Amazon.Lambda.Model;
using System.Text.Json;

public class TaskService : ITaskService
{
    private readonly IAmazonLambda _lambdaClient;
    
    public TaskService(
        ITaskRepository taskRepository,
        // ... otros parámetros
        IAmazonLambda lambdaClient)
    {
        _lambdaClient = lambdaClient;
        // ...
    }

    public async Task<TaskDto> CreateTaskAsync(Guid projectId, CreateTaskDto dto)
    {
        // ... tu lógica existente de crear tarea
        
        var task = _mapper.Map<EntityTask>(dto);
        task.ProjectId = projectId;
        await _taskRepository.AddAsync(task);
        await _taskRepository.SaveChangesAsync();

        // NUEVO: Enviar notificación si se asignó a alguien
        if (!string.IsNullOrEmpty(dto.AssignedToId))
        {
            await SendTaskAssignedNotificationAsync(task, projectId);
        }

        return _mapper.Map<TaskDto>(task);
    }

    private async Task SendTaskAssignedNotificationAsync(EntityTask task, Guid projectId)
    {
        try
        {
            // Obtener datos necesarios
            var project = await _projectRepository.GetByIdAsync(projectId);
            var assignedUser = await _userManager.FindByIdAsync(task.AssignedToId!);
            var currentUser = await _userManager.FindByIdAsync(_userContextAccessor.GetCurrentUserId());

            var notificationEvent = new
            {
                EventType = "TaskAssigned",
                TaskId = task.Id.ToString(),
                TaskTitle = task.Title,
                TaskDescription = task.Description,
                ProjectName = project!.Name,
                AssignedUserEmail = assignedUser!.Email,
                AssignedUserName = assignedUser.UserName,
                AssignerName = currentUser!.UserName,
                DueDate = task.DueDate
            };

            var payload = JsonSerializer.Serialize(notificationEvent);

            var invokeRequest = new InvokeRequest
            {
                FunctionName = "TaskNotifierLambda",
                InvocationType = InvocationType.Event, // Async
                Payload = payload
            };

            await _lambdaClient.InvokeAsync(invokeRequest);
        }
        catch (Exception ex)
        {
            // Log error pero no fallar la operación principal
            Console.WriteLine($"Error sending notification: {ex.Message}");
        }
    }
}
```

**Registrar en Program.cs:**

```csharp
// En Program.cs
builder.Services.AddAWSService<IAmazonLambda>();
```

### Testing de Lambda 2

**Test directo con evento:**

```bash
cat > test-notification.json << EOF
{
  "EventType": "TaskAssigned",
  "TaskId": "123e4567-e89b-12d3-a456-426614174000",
  "TaskTitle": "Implementar Login",
  "TaskDescription": "Crear pantalla de login con validaciones",
  "ProjectName": "Sistema de Gestión",
  "AssignedUserEmail": "tu-email@ejemplo.com",
  "AssignedUserName": "Juan Pérez",
  "AssignerName": "María López",
  "DueDate": "2024-03-15T00:00:00Z"
}
EOF

aws lambda invoke \
    --function-name TaskNotifierLambda \
    --payload file://test-notification.json \
    --cli-binary-format raw-in-base64-out \
    response.json
```

---

## 🧹 Lambda 3: Limpieza Automática de Proyectos

### Objetivo

Ejecutar automáticamente cada domingo a medianoche:
- Archivar proyectos completados hace más de 90 días
- Eliminar proyectos archivados hace más de 365 días
- Enviar reporte por email

### Paso 1: Crear Proyecto

```bash
cd ~/projects
dotnet new lambda.EmptyFunction -n ProjectCleanerLambda -o ProjectCleanerLambda/src/ProjectCleanerLambda

cd ProjectCleanerLambda/src/ProjectCleanerLambda

dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL
dotnet add package Microsoft.EntityFrameworkCore
dotnet add package AWSSDK.SimpleEmail
```

### Paso 2: Models/CleanupResult.cs

```csharp
namespace ProjectCleanerLambda.Models
{
    public class CleanupResult
    {
        public int ProjectsArchived { get; set; }
        public int ProjectsDeleted { get; set; }
        public List<string> ArchivedProjectNames { get; set; } = new();
        public List<string> DeletedProjectNames { get; set; } = new();
        public DateTime ExecutionTime { get; set; } = DateTime.UtcNow;
    }
}
```

### Paso 3: Function.cs

```csharp
using Amazon.Lambda.Core;
using Amazon.SimpleEmail;
using Amazon.SimpleEmail.Model;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using ProjectCleanerLambda.Models;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace ProjectCleanerLambda;

public class Function
{
    private readonly string _connectionString;
    private readonly IAmazonSimpleEmailService _sesClient;
    private readonly string _reportEmail;

    public Function()
    {
        _connectionString = Environment.GetEnvironmentVariable("DATABASE_CONNECTION_STRING")
            ?? throw new InvalidOperationException("DATABASE_CONNECTION_STRING not set");
        
        _reportEmail = Environment.GetEnvironmentVariable("REPORT_EMAIL")
            ?? throw new InvalidOperationException("REPORT_EMAIL not set");
        
        _sesClient = new AmazonSimpleEmailServiceClient();
    }

    public async Task<CleanupResult> FunctionHandler(ILambdaContext context)
    {
        context.Logger.LogInformation("Starting project cleanup job");

        var result = new CleanupResult();

        using var connection = new NpgsqlConnection(_connectionString);
        await connection.OpenAsync();

        // 1. Archivar proyectos completados hace más de 90 días
        var archiveQuery = @"
            UPDATE ""Projects""
            SET ""Status"" = 'Archived'
            WHERE ""Status"" = 'Completed'
            AND ""CreationDate"" < @ArchiveDate
            RETURNING ""Name"";
        ";

        var archiveDate = DateTime.UtcNow.AddDays(-90);

        using (var cmd = new NpgsqlCommand(archiveQuery, connection))
        {
            cmd.Parameters.AddWithValue("ArchiveDate", archiveDate);
            
            using var reader = await cmd.ExecuteReaderAsync();
            while (await reader.ReadAsync())
            {
                result.ArchivedProjectNames.Add(reader.GetString(0));
                result.ProjectsArchived++;
            }
        }

        context.Logger.LogInformation($"Archived {result.ProjectsArchived} projects");

        // 2. Eliminar proyectos archivados hace más de 365 días
        var deleteQuery = @"
            DELETE FROM ""Projects""
            WHERE ""Status"" = 'Archived'
            AND ""CreationDate"" < @DeleteDate
            RETURNING ""Name"";
        ";

        var deleteDate = DateTime.UtcNow.AddDays(-365);

        using (var cmd = new NpgsqlCommand(deleteQuery, connection))
        {
            cmd.Parameters.AddWithValue("DeleteDate", deleteDate);
            
            using var reader = await cmd.ExecuteReaderAsync();
            while (await reader.ReadAsync())
            {
                result.DeletedProjectNames.Add(reader.GetString(0));
                result.ProjectsDeleted++;
            }
        }

        context.Logger.LogInformation($"Deleted {result.ProjectsDeleted} projects");

        // 3. Enviar reporte por email
        await SendReportEmailAsync(result);

        context.Logger.LogInformation("Cleanup job completed successfully");

        return result;
    }

    private async Task SendReportEmailAsync(CleanupResult result)
    {
        var subject = $"Reporte de Limpieza de Proyectos - {result.ExecutionTime:dd/MM/yyyy}";
        
        var htmlBody = $@"
<!DOCTYPE html>
<html>
<head>
    <style>
        body {{ font-family: Arial, sans-serif; line-height: 1.6; color: #333; }}
        .container {{ max-width: 800px; margin: 0 auto; padding: 20px; }}
        .header {{ background-color: #607D8B; color: white; padding: 20px; text-align: center; }}
        .summary {{ background-color: #f9f9f9; padding: 20px; margin: 20px 0; }}
        .stat-box {{ display: inline-block; margin: 10px 20px; text-align: center; }}
        .stat-number {{ font-size: 36px; font-weight: bold; color: #607D8B; }}
        .stat-label {{ font-size: 14px; color: #666; }}
        ul {{ background-color: white; padding: 20px; }}
    </style>
</head>
<body>
    <div class='container'>
        <div class='header'>
            <h2>Reporte de Limpieza Automática de Proyectos</h2>
            <p>{result.ExecutionTime:dd/MM/yyyy HH:mm} UTC</p>
        </div>
        
        <div class='summary'>
            <div class='stat-box'>
                <div class='stat-number'>{result.ProjectsArchived}</div>
                <div class='stat-label'>Proyectos Archivados</div>
            </div>
            <div class='stat-box'>
                <div class='stat-number'>{result.ProjectsDeleted}</div>
                <div class='stat-label'>Proyectos Eliminados</div>
            </div>
        </div>

        {(result.ArchivedProjectNames.Any() ? $@"
        <h3>Proyectos Archivados:</h3>
        <ul>
            {string.Join("", result.ArchivedProjectNames.Select(name => $"<li>{name}</li>"))}
        </ul>
        " : "")}

        {(result.DeletedProjectNames.Any() ? $@"
        <h3>Proyectos Eliminados:</h3>
        <ul>
            {string.Join("", result.DeletedProjectNames.Select(name => $"<li>{name}</li>"))}
        </ul>
        " : "")}

        {(!result.ArchivedProjectNames.Any() && !result.DeletedProjectNames.Any() ? 
            "<p>No se realizaron cambios en esta ejecución.</p>" : "")}
    </div>
</body>
</html>";

        var sendRequest = new SendEmailRequest
        {
            Source = _reportEmail,
            Destination = new Destination
            {
                ToAddresses = new List<string> { _reportEmail }
            },
            Message = new Message
            {
                Subject = new Content(subject),
                Body = new Body
                {
                    Html = new Content
                    {
                        Charset = "UTF-8",
                        Data = htmlBody
                    }
                }
            }
        };

        await _sesClient.SendEmailAsync(sendRequest);
    }
}
```

### Paso 4: Deploy Lambda 3

```bash
cd ~/projects/ProjectCleanerLambda/src/ProjectCleanerLambda

dotnet lambda deploy-function ProjectCleanerLambda \
    --function-role <TU_LAMBDA_EXECUTION_ROLE_ARN> \
    --region us-east-1 \
    --function-memory-size 256 \
    --function-timeout 120 \
    --environment-variables \
        DATABASE_CONNECTION_STRING="Host=tu-rds-endpoint;Database=gestion_proyectos;Username=postgres;Password=xxx",REPORT_EMAIL=admin@tudominio.com
```

### Paso 5: Configurar Scheduled Event (EventBridge/CloudWatch)

**Opción 1: AWS Console**

1. **EventBridge Console** → **Rules** → **Create rule**
2. **Name**: `WeeklyProjectCleanup`
3. **Event bus**: default
4. **Rule type**: Schedule
5. **Schedule pattern**: Cron expression
   - Expresión: `0 0 ? * SUN *` (Domingos a medianoche UTC)
6. **Target**: Lambda function → `ProjectCleanerLambda`

**Opción 2: AWS CLI**

```bash
# Crear regla
aws events put-rule \
    --name WeeklyProjectCleanup \
    --schedule-expression "cron(0 0 ? * SUN *)" \
    --description "Run project cleanup every Sunday at midnight"

# Agregar permiso a Lambda
aws lambda add-permission \
    --function-name ProjectCleanerLambda \
    --statement-id EventBridgeInvoke \
    --action lambda:InvokeFunction \
    --principal events.amazonaws.com \
    --source-arn arn:aws:events:us-east-1:ACCOUNT_ID:rule/WeeklyProjectCleanup

# Agregar Lambda como target
aws events put-targets \
    --rule WeeklyProjectCleanup \
    --targets "Id"="1","Arn"="arn:aws:lambda:us-east-1:ACCOUNT_ID:function:ProjectCleanerLambda"
```

### Testing Lambda 3

**Test manual:**

```bash
aws lambda invoke \
    --function-name ProjectCleanerLambda \
    --cli-binary-format raw-in-base64-out \
    response.json

cat response.json
```

---

## 🔐 IAM Roles y Permisos

### Lambda Execution Role (Para las 3 Lambdas)

**Crear IAM Role:**

```bash
# Crear trust policy
cat > lambda-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Crear role
aws iam create-role \
    --role-name LambdaExecutionRole \
    --assume-role-policy-document file://lambda-trust-policy.json

# Adjuntar política de logs básica
aws iam attach-role-policy \
    --role-name LambdaExecutionRole \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

**Crear política personalizada:**

```bash
cat > lambda-permissions-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::TU-BUCKET-NAME/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ses:SendEmail",
        "ses:SendRawEmail"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "rds-data:ExecuteStatement",
        "rds-data:BatchExecuteStatement"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# Crear política
aws iam create-policy \
    --policy-name LambdaCustomPermissions \
    --policy-document file://lambda-permissions-policy.json

# Adjuntar a role
aws iam attach-role-policy \
    --role-name LambdaExecutionRole \
    --policy-arn arn:aws:iam::ACCOUNT_ID:policy/LambdaCustomPermissions
```

**Obtener ARN del Role:**

```bash
aws iam get-role --role-name LambdaExecutionRole --query 'Role.Arn' --output text
```

---

## 📊 Monitoreo y Troubleshooting

### CloudWatch Logs

**Ver logs de una Lambda:**

```bash
# Listar log groups
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/

# Obtener últimos logs
aws logs tail /aws/lambda/ImageProcessorLambda --follow

# Ver logs de fecha específica
aws logs filter-log-events \
    --log-group-name /aws/lambda/ImageProcessorLambda \
    --start-time $(date -d '1 hour ago' +%s)000
```

### Métricas en CloudWatch

**Métricas importantes:**

- **Invocations**: Número de ejecuciones
- **Duration**: Tiempo de ejecución
- **Errors**: Errores no manejados
- **Throttles**: Llamadas rechazadas por límites de concurrencia

**Ver métricas:**

```bash
aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name Invocations \
    --dimensions Name=FunctionName,Value=ImageProcessorLambda \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Sum
```

### Alarmas Recomendadas

```bash
# Alarma por errores en Lambda
aws cloudwatch put-metric-alarm \
    --alarm-name ImageProcessorErrors \
    --alarm-description "Alert when Lambda has errors" \
    --metric-name Errors \
    --namespace AWS/Lambda \
    --statistic Sum \
    --period 300 \
    --evaluation-periods 1 \
    --threshold 5 \
    --comparison-operator GreaterThanThreshold \
    --dimensions Name=FunctionName,Value=ImageProcessorLambda
```

### Troubleshooting Común

**Problema 1: Lambda timeout**

```bash
# Aumentar timeout
aws lambda update-function-configuration \
    --function-name ImageProcessorLambda \
    --timeout 120
```

**Problema 2: Out of memory**

```bash
# Aumentar memoria (también aumenta CPU)
aws lambda update-function-configuration \
    --function-name ImageProcessorLambda \
    --memory-size 1024
```

**Problema 3: Permisos insuficientes**

- Revisar CloudWatch Logs para ver el error exacto
- Verificar que el IAM Role tenga las políticas necesarias
- Verificar resource-based policies (S3 bucket policy, etc.)

---

## 💰 Costos Estimados

### Lambda Pricing (us-east-1)

**Requests:**
- $0.20 por millón de requests
- Primer millón gratis por mes

**Duration:**
- $0.0000166667 por GB-segundo
- 400,000 GB-segundos gratis por mes

**Estimación para tu caso:**

```
ImageProcessor:
- 1,000 uploads/mes × 512MB × 5 segundos = 2,500 GB-s
- Requests: 1,000
- Costo: ~$0.04/mes

TaskNotifier:
- 5,000 tasks/mes × 128MB × 2 segundos = 1,250 GB-s
- Requests: 5,000
- Costo: ~$0.03/mes

ProjectCleaner:
- 4 runs/mes × 256MB × 30 segundos = 30 GB-s
- Requests: 4
- Costo: ~$0.01/mes

TOTAL LAMBDA: ~$0.08/mes (prácticamente gratis)
```

**SES Pricing:**
- $0.10 por 1,000 emails enviados
- 62,000 emails gratis por mes (si envías desde EC2/Lambda)

---

## 📝 Próximos Pasos

Ahora que tienes las 3 Lambdas funcionando:

1. **Semana 4**: API Gateway + Lambda (crear APIs serverless)
2. **Optimizaciones**:
   - Lambda Layers para compartir dependencias
   - VPC configuration si necesitas acceso privado a RDS
   - Lambda@Edge para CDN processing
3. **Monitoreo avanzado**:
   - X-Ray tracing
   - Custom metrics
   - Dashboards en CloudWatch

---

## 🎯 Resumen

Has implementado:

✅ **Lambda 1**: Procesamiento automático de imágenes con S3 triggers  
✅ **Lambda 2**: Sistema de notificaciones por email vía SES  
✅ **Lambda 3**: Limpieza programada de proyectos vía EventBridge  
✅ **IAM Roles**: Permisos correctos para cada Lambda  
✅ **Monitoreo**: CloudWatch Logs y métricas configuradas  

**Arquitectura final:**

```
Frontend (S3) → Backend (ECS) → Database (RDS)
                     ↓
              Lambda Invocations
                     ↓
        ┌────────────┼────────────┐
        ↓            ↓            ↓
  ImageProcessor  TaskNotifier  ProjectCleaner
        ↓            ↓            ↓
   S3 Resize    SES Email    Scheduled Job
```

¡Felicidades! Ahora tienes un sistema completamente serverless para tareas asíncronas. 🚀
