#!/usr/bin/env bash
# LOC-01 · Smoke test de los 5 servicios de LocalStack:
# S3, DynamoDB, SQS, SNS y EventBridge.
#
# Se puede correr desde el host (Linux/macOS/WSL) o dentro del contenedor.
# Si `awslocal` no existe en el host, el script se re-ejecuta dentro del
# contenedor, así no hace falta instalar AWS CLI ni Python.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if ! command -v awslocal >/dev/null 2>&1; then
  exec docker compose -f "$ROOT/docker-compose.yml" exec -T localstack \
    bash /opt/nubeduca/scripts/smoke.sh
fi

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

TABLE="local-t_demo"
TOPIC="nubeduca-local-notificaciones"
NOTIF_QUEUE="nubeduca-local-notificaciones"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s' '{"tenant_id":{"S":"utec"},"sk":{"S":"demo#1"},"mensaje":{"S":"hola localstack"}}' > "$TMP/item.json"
printf '%s' '{"tenant_id":{"S":"utec"},"sk":{"S":"demo#1"}}' > "$TMP/key.json"
printf '%s' '{"tenant_id":"utec","mensaje":"ping sns"}' > "$TMP/sns.json"

echo "== S3 =="
awslocal s3api list-buckets --query 'Buckets[].Name' --output text
echo "  OK"

echo "== DynamoDB =="
awslocal dynamodb put-item --table-name "$TABLE" --item "file://$TMP/item.json"
MENSAJE="$(awslocal dynamodb get-item --table-name "$TABLE" --key "file://$TMP/key.json" --query 'Item.mensaje.S' --output text)"
if [ -z "$MENSAJE" ] || [ "$MENSAJE" = "None" ]; then
  echo "No se pudo leer el item de DynamoDB." >&2
  exit 1
fi
echo "  OK: $MENSAJE"

echo "== SQS =="
awslocal sqs list-queues --output text
echo "  OK"

echo "== SNS =="
awslocal sns list-topics --output text
TOPIC_ARN="$(awslocal sns create-topic --name "$TOPIC" --query TopicArn --output text)"
awslocal sns publish --topic-arn "$TOPIC_ARN" --message "file://$TMP/sns.json" >/dev/null
NOTIF_URL="$(awslocal sqs get-queue-url --queue-name "$NOTIF_QUEUE" --query QueueUrl --output text)"
SNS_ROW=""
for _ in 1 2 3 4 5; do
  SNS_ROW="$(awslocal sqs receive-message --queue-url "$NOTIF_URL" --wait-time-seconds 5 --max-number-of-messages 1 --query 'Messages[0].[Body,ReceiptHandle]' --output text 2>/dev/null || true)"
  if [ -n "$SNS_ROW" ] && [ "$SNS_ROW" != "None" ]; then
    break
  fi
  SNS_ROW=""
done
if [ -z "$SNS_ROW" ]; then
  echo "El mensaje SNS no llegó a $NOTIF_QUEUE." >&2
  exit 1
fi
SNS_BODY="$(printf '%s' "$SNS_ROW" | cut -f1)"
SNS_RECEIPT="$(printf '%s' "$SNS_ROW" | cut -f2)"
if ! printf '%s' "$SNS_BODY" | grep -q 'ping sns'; then
  echo "Payload SNS inesperado: $SNS_BODY" >&2
  exit 1
fi
awslocal sqs delete-message --queue-url "$NOTIF_URL" --receipt-handle "$SNS_RECEIPT" >/dev/null
echo "  OK: SNS -> SQS"

echo "== EventBridge =="
awslocal events list-event-buses --output text
awslocal events list-rules --event-bus-name lms --output text
echo "  OK"

echo ""
echo "Smoke test completo: S3, DynamoDB, SQS, SNS y EventBridge responden."
