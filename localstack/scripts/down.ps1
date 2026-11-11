#requires -Version 5.1
# LOC-01 · Baja LocalStack y borra los datos locales.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\down.ps1

$ErrorActionPreference = "Stop"

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = Split-Path -Parent $PSScriptRoot

Push-Location $Root
try {
  docker compose down -v --remove-orphans
  if ($LASTEXITCODE -ne 0) {
    throw "docker compose down falló."
  }
  Write-Host "LocalStack detenido y datos locales eliminados."
} finally {
  Pop-Location
}
