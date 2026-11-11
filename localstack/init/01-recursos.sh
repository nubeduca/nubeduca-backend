#!/bin/bash
# LOC-01 · Crea los recursos base de Nubeduca en LocalStack.
# Lo ejecuta LocalStack al quedar listo (init/ready.d) y también scripts/up.*
# para garantizar el estado. Es idempotente: se puede correr varias veces.

set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"

BUCKET="nubeduca-local-materiales"
TABLE="local-t_demo"
BUS="lms"
RULE="nubeduca-local-enrollment-created"
QUEUE="nubeduca-local-cursos-eventos"
DLQ="nubeduca-local-cursos-eventos-dlq"
TOPIC="nubeduca-local-notificaciones"
NOTIF_QUEUE="nubeduca-local-notificaciones"

log() { printf '[loc-01] %s\n' "$*"; }

# Aplica una política de cola que permite a un servicio (EventBridge o SNS)
# enviar mensajes. Sin esta política, AWS real rechaza la entrega.
set_queue_policy() {
  local queue_url="$1"
  local queue_arn="$2"
  local service="$3"
  local source_arn="$4"
  local policy escaped

  policy=$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"$service"},"Action":"sqs:SendMessage","Resource":"$queue_arn","Condition":{"ArnEquals":{"aws:SourceArn":"$source_arn"}}}]}
EOF
)

  escaped=$(printf '%s' "$policy" | sed 's/\\/\\\\/g; s/"/\\"/g')
  cat > /tmp/queue-policy.json <<EOF
{"QueueUrl":"$queue_url","Attributes":{"Policy":"$escaped"}}
EOF
  awslocal sqs set-queue-attributes --cli-input-json file:///tmp/queue-policy.json >/dev/null
}

log "S3: bucket $BUCKET"
awslocal s3api create-bucket --bucket "$BUCKET" >/dev/null 2>&1 || true

log "DynamoDB: tabla $TABLE (tenant_id / sk)"
awslocal dynamodb create-table \
  --table-name "$TABLE" \
  --attribute-definitions AttributeName=tenant_id,AttributeType=S AttributeName=sk,AttributeType=S \
  --key-schema AttributeName=tenant_id,KeyType=HASH AttributeName=sk,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST >/dev/null 2>&1 || true

log "SQS: colas $QUEUE y $DLQ"
awslocal sqs create-queue --queue-name "$DLQ" >/dev/null
DLQ_URL=$(awslocal sqs get-queue-url --queue-name "$DLQ" --query QueueUrl --output text)
DLQ_ARN=$(awslocal sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

awslocal sqs create-queue --queue-name "$QUEUE" >/dev/null
QUEUE_URL=$(awslocal sqs get-queue-url --queue-name "$QUEUE" --query QueueUrl --output text)
QUEUE_ARN=$(awslocal sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

awslocal sqs set-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"5\\\"}\"}" >/dev/null

log "SNS: topic $TOPIC -> cola $NOTIF_QUEUE"
TOPIC_ARN=$(awslocal sns create-topic --name "$TOPIC" --query TopicArn --output text)

awslocal sqs create-queue --queue-name "$NOTIF_QUEUE" >/dev/null
NOTIF_URL=$(awslocal sqs get-queue-url --queue-name "$NOTIF_QUEUE" --query QueueUrl --output text)
NOTIF_ARN=$(awslocal sqs get-queue-attributes --queue-url "$NOTIF_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

awslocal sns subscribe \
  --topic-arn "$TOPIC_ARN" \
  --protocol sqs \
  --notification-endpoint "$NOTIF_ARN" \
  --attributes RawMessageDelivery=true >/dev/null

log "EventBridge: bus $BUS y regla $RULE -> $QUEUE"
awslocal events create-event-bus --name "$BUS" >/dev/null 2>&1 || true
RULE_ARN=$(awslocal events put-rule \
  --name "$RULE" \
  --event-bus-name "$BUS" \
  --event-pattern '{"source":["lms.courses"],"detail-type":["lms.courses.enrollment.created.v1"]}' \
  --query RuleArn --output text)

awslocal events put-targets \
  --rule "$RULE" \
  --event-bus-name "$BUS" \
  --targets "Id=1,Arn=$QUEUE_ARN" >/dev/null

log "Permisos EventBridge -> SQS"
set_queue_policy "$QUEUE_URL" "$QUEUE_ARN" "events.amazonaws.com" "$RULE_ARN"

log "Permisos SNS -> SQS"
set_queue_policy "$NOTIF_URL" "$NOTIF_ARN" "sns.amazonaws.com" "$TOPIC_ARN"

log "Listo. Recursos disponibles:"
log "  S3          $BUCKET"
log "  DynamoDB    $TABLE"
log "  SQS         $QUEUE (DLQ: $DLQ)"
log "  SNS         $TOPIC -> $NOTIF_QUEUE"
log "  EventBridge $BUS / $RULE -> $QUEUE"
