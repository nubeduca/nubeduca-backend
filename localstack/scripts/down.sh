#!/usr/bin/env bash
# LOC-01 · Baja LocalStack y borra los datos locales.
# Uso: ./scripts/down.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

docker compose -f "$ROOT/docker-compose.yml" down -v --remove-orphans
echo "LocalStack detenido y datos locales eliminados."
