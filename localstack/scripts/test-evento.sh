#!/usr/bin/env bash
# LOC-01 · Publica un evento de prueba en EventBridge y verifica que llegue
# a la cola SQS local. Este es el criterio "listo" de la tarea.
#
# Se puede correr desde el host (Linux/macOS/WSL) o dentro del contenedor.
# Si `awslocal` no existe en el host, el script se re-ejecuta dentro del
# contenedor, así no hace falta instalar AWS CLI ni Python.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if ! command -v awslocal >/dev/null 2>&1; then
  exec docker compose -f "$ROOT/docker-compose.yml" exec -T localstack \
    bash /opt/nubeduca/scripts/test-evento.sh
fi

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

QUEUE="nubeduca-local-cursos-eventos"
EVENT_TYPE="lms.courses.enrollment.created.v1"
ENROLLMENT_ID="enr_01JCY7SYF5X0ZHRJ7KQSVX4BP0"
FIXTURE="$HERE/../eventos/enrollment-created.json"

echo "Publicando $EVENT_TYPE en el bus lms..."
PUT_OUT="$(awslocal events put-events --entries "file://$(cd "$(dirname "$FIXTURE")" && pwd)/$(basename "$FIXTURE")" --output json)"
if ! printf '%s' "$PUT_OUT" | grep -q '"FailedEntryCount": 0'; then
  printf '%s\n' "$PUT_OUT"
  echo "EventBridge rechazó el evento." >&2
  exit 1
fi

QUEUE_URL="$(awslocal sqs get-queue-url --queue-name "$QUEUE" --query QueueUrl --output text)"

echo "Esperando el evento en $QUEUE..."
ROW=""
for _ in 1 2 3 4 5 6; do
  ROW="$(awslocal sqs receive-message --queue-url "$QUEUE_URL" --wait-time-seconds 5 --max-number-of-messages 1 --query 'Messages[0].[Body,ReceiptHandle]' --output text 2>/dev/null || true)"
  if [ -n "$ROW" ] && [ "$ROW" != "None" ]; then
    break
  fi
  ROW=""
done

BODY="$(printf '%s' "$ROW" | cut -f1)"
RECEIPT="$(printf '%s' "$ROW" | cut -f2)"

if [ -z "$BODY" ]; then
  echo "El evento no llegó a $QUEUE en 30 segundos." >&2
  exit 1
fi

if ! printf '%s' "$BODY" | grep -q "$EVENT_TYPE"; then
  echo "detail-type inesperado: $BODY" >&2
  exit 1
fi
if ! printf '%s' "$BODY" | grep -q "$ENROLLMENT_ID"; then
  echo "enrollmentId inesperado: $BODY" >&2
  exit 1
fi

if [ -n "$RECEIPT" ]; then
  awslocal sqs delete-message --queue-url "$QUEUE_URL" --receipt-handle "$RECEIPT" >/dev/null
fi

echo ""
echo "OK: el evento llegó a la cola SQS local."
echo "  detail-type : $EVENT_TYPE"
echo "  enrollmentId: $ENROLLMENT_ID"
echo "  queue       : $QUEUE"
echo ""
echo "Evento recibido:"
printf '%s\n' "$BODY"
