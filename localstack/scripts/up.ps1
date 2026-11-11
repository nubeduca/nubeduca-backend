#requires -Version 5.1
# LOC-01 · Levanta LocalStack y deja los recursos base creados.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\up.ps1

$ErrorActionPreference = "Stop"

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Endpoint = "http://localhost:4566"
$Region = "us-east-1"
$Root = Split-Path -Parent $PSScriptRoot

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

try {
  $env:AWS_ACCESS_KEY_ID = "test"
  $env:AWS_SECRET_ACCESS_KEY = "test"
  $env:AWS_SESSION_TOKEN = $null
  $env:AWS_DEFAULT_REGION = $Region
  $env:AWS_PAGER = ""

  Push-Location $Root
  try {
    Write-Host "Levantando LocalStack (puede tardar la primera vez)..."
    docker compose up -d --wait
    if ($LASTEXITCODE -ne 0) {
      throw "docker compose up -d --wait falló. Verifica que Docker Desktop esté abierto."
    }

    Write-Host "Aplicando recursos base (idempotente)..."
    docker compose exec -T localstack bash /etc/localstack/init/ready.d/01-recursos.sh
    if ($LASTEXITCODE -ne 0) {
      throw "No se pudieron crear los recursos base."
    }

    Write-Host ""
    Write-Host "LocalStack listo en $Endpoint"
    Write-Host "Colas SQS:"
    aws --endpoint-url $Endpoint --region $Region sqs list-queues --output text
    Write-Host ""
    Write-Host "Siguiente paso:"
    Write-Host "  .\scripts\test-evento.ps1   # prueba EventBridge -> SQS"
    Write-Host "  .\scripts\smoke.ps1         # prueba S3, DynamoDB, SQS, SNS y EventBridge"
  } finally {
    Pop-Location
  }
} finally {
  Restore-Env
}
