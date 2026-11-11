#!/usr/bin/env bash
# LOC-01 · Levanta LocalStack y deja los recursos base creados.
# Equivale a: docker compose up -d --wait
# Uso: ./scripts/up.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

echo "Levantando LocalStack (puede tardar la primera vez)..."
docker compose up -d --wait

echo "Aplicando recursos base (idempotente)..."
docker compose exec -T localstack bash /etc/localstack/init/ready.d/01-recursos.sh

echo ""
echo "LocalStack listo en http://localhost:4566"
echo "Siguiente paso:"
echo "  ./scripts/test-evento.sh   # prueba EventBridge -> SQS"
echo "  ./scripts/smoke.sh         # prueba S3, DynamoDB, SQS, SNS y EventBridge"
