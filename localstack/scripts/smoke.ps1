#requires -Version 5.1
# LOC-01 · Smoke test de los 5 servicios de LocalStack:
# S3, DynamoDB, SQS, SNS y EventBridge.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\smoke.ps1

$ErrorActionPreference = "Stop"

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Endpoint = "http://localhost:4566"
$Region = "us-east-1"
$Table = "local-t_demo"
$Topic = "nubeduca-local-notificaciones"
$NotifQueue = "nubeduca-local-notificaciones"

$prev = @{
  AWS_ACCESS_KEY_ID     = $env:AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY = $env:AWS_SECRET_ACCESS_KEY
  AWS_SESSION_TOKEN     = $env:AWS_SESSION_TOKEN
  AWS_DEFAULT_REGION    = $env:AWS_DEFAULT_REGION
  AWS_PAGER             = $env:AWS_PAGER
}

function Restore-Env {
  foreach ($k in $prev.Keys) {
    if ($null -eq $prev[$k]) {
      Remove-Item "env:$k" -ErrorAction SilentlyContinue
    } else {
      Set-Item "env:$k" $prev[$k]
    }
  }
}

function Invoke-Aws {
  & aws @args
  if ($LASTEXITCODE -ne 0) {
    throw "aws falló: $($args -join ' ')"
  }
}

# PowerShell 5.1 destroza el JSON al pasarlo como argumento a un .exe nativo.
# Se escribe a un archivo temporal y se pasa con file:// (soportado por AWS CLI).
$script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("nubeduca-smoke-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $script:TempDir | Out-Null

function Json-File([string]$name, [string]$json) {
  $path = Join-Path $script:TempDir $name
  [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
  return "file://" + ($path -replace '\\', '/')
}

try {
  $env:AWS_ACCESS_KEY_ID = "test"
  $env:AWS_SECRET_ACCESS_KEY = "test"
  $env:AWS_SESSION_TOKEN = $null
  $env:AWS_DEFAULT_REGION = $Region
  $env:AWS_PAGER = ""

  Write-Host "== S3 =="
  Invoke-Aws s3 ls --endpoint-url $Endpoint --region $Region
  Write-Host "  OK"

  Write-Host "== DynamoDB =="
  $itemUri = Json-File "item.json" '{"tenant_id":{"S":"utec"},"sk":{"S":"demo#1"},"mensaje":{"S":"hola localstack"}}'
  $keyUri = Json-File "key.json" '{"tenant_id":{"S":"utec"},"sk":{"S":"demo#1"}}'
  Invoke-Aws dynamodb put-item --endpoint-url $Endpoint --region $Region --table-name $Table --item $itemUri | Out-Null
  $item = Invoke-Aws dynamodb get-item --endpoint-url $Endpoint --region $Region --table-name $Table --key $keyUri --output json | ConvertFrom-Json
  if ($null -eq $item.Item) {
    throw "No se pudo leer el item de DynamoDB."
  }
  Write-Host "  OK: $($item.Item.mensaje.S)"

  Write-Host "== SQS =="
  Invoke-Aws sqs list-queues --endpoint-url $Endpoint --region $Region --output text
  Write-Host "  OK"

  Write-Host "== SNS =="
  Invoke-Aws sns list-topics --endpoint-url $Endpoint --region $Region --output text
  $topicArn = Invoke-Aws sns create-topic --endpoint-url $Endpoint --region $Region --name $Topic --query TopicArn --output text
  Invoke-Aws sns publish --endpoint-url $Endpoint --region $Region --topic-arn $topicArn --message (Json-File "sns.json" '{"tenant_id":"utec","mensaje":"ping sns"}') | Out-Null
  $notifUrl = Invoke-Aws sqs get-queue-url --endpoint-url $Endpoint --region $Region --queue-name $NotifQueue --query QueueUrl --output text
  $snsMessage = $null
  for ($i = 0; $i -lt 5 -and $null -eq $snsMessage; $i++) {
    $resp = Invoke-Aws sqs receive-message --endpoint-url $Endpoint --region $Region --queue-url $notifUrl --wait-time-seconds 5 --max-number-of-messages 1 --output json | ConvertFrom-Json
    if ($resp.Messages) {
      $snsMessage = $resp.Messages[0]
    }
  }
  if ($null -eq $snsMessage) {
    throw "El mensaje SNS no llegó a $NotifQueue."
  }
  $payload = $snsMessage.Body | ConvertFrom-Json
  if ($payload.mensaje -ne "ping sns") {
    throw "Payload SNS inesperado: $($snsMessage.Body)"
  }
  Invoke-Aws sqs delete-message --endpoint-url $Endpoint --region $Region --queue-url $notifUrl --receipt-handle $snsMessage.ReceiptHandle | Out-Null
  Write-Host "  OK: SNS -> SQS"

  Write-Host "== EventBridge =="
  Invoke-Aws events list-event-buses --endpoint-url $Endpoint --region $Region --output text
  Invoke-Aws events list-rules --endpoint-url $Endpoint --region $Region --event-bus-name lms --output text
  Write-Host "  OK"

  Write-Host ""
  Write-Host "Smoke test completo: S3, DynamoDB, SQS, SNS y EventBridge responden."
} finally {
  Restore-Env
  Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
