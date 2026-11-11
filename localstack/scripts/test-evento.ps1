#requires -Version 5.1
# LOC-01 · Publica un evento de prueba en EventBridge y verifica que llegue
# a la cola SQS local. Este es el criterio "listo" de la tarea.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-evento.ps1

$ErrorActionPreference = "Stop"

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Endpoint = "http://localhost:4566"
$Region = "us-east-1"
$Queue = "nubeduca-local-cursos-eventos"
$EventType = "lms.courses.enrollment.created.v1"
$EnrollmentId = "enr_01JCY7SYF5X0ZHRJ7KQSVX4BP0"

$Fixture = (Resolve-Path (Join-Path $PSScriptRoot "..\eventos\enrollment-created.json")).Path
$FixtureUri = "file://" + ($Fixture -replace '\\', '/')

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

try {
  $env:AWS_ACCESS_KEY_ID = "test"
  $env:AWS_SECRET_ACCESS_KEY = "test"
  $env:AWS_SESSION_TOKEN = $null
  $env:AWS_DEFAULT_REGION = $Region
  $env:AWS_PAGER = ""

  Write-Host "Publicando $EventType en el bus lms..."
  $put = Invoke-Aws events put-events --endpoint-url $Endpoint --region $Region --entries $FixtureUri --output json | ConvertFrom-Json
  if ($put.FailedEntryCount -ne 0) {
    $put | ConvertTo-Json -Depth 10 | Write-Host
    throw "EventBridge rechazó el evento (FailedEntryCount=$($put.FailedEntryCount))."
  }

  $queueUrl = Invoke-Aws sqs get-queue-url --endpoint-url $Endpoint --region $Region --queue-name $Queue --query QueueUrl --output text

  Write-Host "Esperando el evento en $Queue..."
  $message = $null
  for ($i = 0; $i -lt 6 -and $null -eq $message; $i++) {
    $resp = Invoke-Aws sqs receive-message --endpoint-url $Endpoint --region $Region --queue-url $queueUrl --wait-time-seconds 5 --max-number-of-messages 1 --output json | ConvertFrom-Json
    if ($resp.Messages) {
      $message = $resp.Messages[0]
    }
  }

  if ($null -eq $message) {
    throw "El evento no llegó a $Queue en 30 segundos."
  }

  $body = $message.Body | ConvertFrom-Json
  if ($body.'detail-type' -ne $EventType) {
    throw "detail-type inesperado: $($body.'detail-type')"
  }
  if ($body.detail.data.enrollmentId -ne $EnrollmentId) {
    throw "enrollmentId inesperado: $($body.detail.data.enrollmentId)"
  }

  Invoke-Aws sqs delete-message --endpoint-url $Endpoint --region $Region --queue-url $queueUrl --receipt-handle $message.ReceiptHandle | Out-Null

  Write-Host ""
  Write-Host "OK: el evento llegó a la cola SQS local."
  Write-Host "  detail-type : $($body.'detail-type')"
  Write-Host "  enrollmentId: $($body.detail.data.enrollmentId)"
  Write-Host "  queue       : $Queue"
  Write-Host ""
  Write-Host "Evento recibido:"
  $body | ConvertTo-Json -Depth 12
} finally {
  Restore-Env
}
