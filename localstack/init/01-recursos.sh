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

# --- ENG-01 · ms-notificaciones ------------------------------------------------
# Tabla, regla del bus lms con su cola + DLQ, y tópico FIFO de notas con su cola FIFO.
# El email sale por el topic $TOPIC (ya suscrito a la cola $NOTIF_QUEUE para verlo).
NTF_TABLE="local-t_notificaciones"
NTF_RULE="nubeduca-local-notificaciones"
NTF_QUEUE="nubeduca-local-notificaciones-eventos"
NTF_DLQ="nubeduca-local-notificaciones-eventos-dlq"
NOTAS_TOPIC="local-notas.fifo"
NOTAS_QUEUE="nubeduca-local-notificaciones-notas.fifo"
NOTAS_DLQ="nubeduca-local-notificaciones-notas-dlq.fifo"

queue_arn() {
  awslocal sqs get-queue-attributes --queue-url "$1" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text
}

set_redrive() {
  awslocal sqs set-queue-attributes \
    --queue-url "$1" \
    --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$2\\\",\\\"maxReceiveCount\\\":\\\"5\\\"}\"}" >/dev/null
}

log "ENG-01: tabla $NTF_TABLE (tenant_id / sk)"
awslocal dynamodb create-table \
  --table-name "$NTF_TABLE" \
  --attribute-definitions AttributeName=tenant_id,AttributeType=S AttributeName=sk,AttributeType=S \
  --key-schema AttributeName=tenant_id,KeyType=HASH AttributeName=sk,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST >/dev/null 2>&1 || true

log "ENG-01: cola $NTF_QUEUE (DLQ $NTF_DLQ) y regla $NTF_RULE en el bus $BUS"
awslocal sqs create-queue --queue-name "$NTF_DLQ" >/dev/null
NTF_DLQ_URL=$(awslocal sqs get-queue-url --queue-name "$NTF_DLQ" --query QueueUrl --output text)
awslocal sqs create-queue --queue-name "$NTF_QUEUE" >/dev/null
NTF_QUEUE_URL=$(awslocal sqs get-queue-url --queue-name "$NTF_QUEUE" --query QueueUrl --output text)
NTF_QUEUE_ARN=$(queue_arn "$NTF_QUEUE_URL")
set_redrive "$NTF_QUEUE_URL" "$(queue_arn "$NTF_DLQ_URL")"

NTF_RULE_ARN=$(awslocal events put-rule \
  --name "$NTF_RULE" \
  --event-bus-name "$BUS" \
  --event-pattern '{"source":["lms.users","lms.courses","lms.content","lms.assessment"],"detail-type":["lms.users.user.provisioned.v1","lms.courses.enrollment.created.v1","lms.courses.enrollment.dropped.v1","lms.courses.course.published.v1","lms.courses.announcement.published.v1","lms.content.module.published.v1","lms.assessment.assignment.published.v1","lms.assessment.submission.submitted.v1"]}' \
  --query RuleArn --output text)
awslocal events put-targets --rule "$NTF_RULE" --event-bus-name "$BUS" \
  --targets "Id=1,Arn=$NTF_QUEUE_ARN" >/dev/null
set_queue_policy "$NTF_QUEUE_URL" "$NTF_QUEUE_ARN" "events.amazonaws.com" "$NTF_RULE_ARN"

log "ENG-01: tópico FIFO $NOTAS_TOPIC -> cola $NOTAS_QUEUE (DLQ $NOTAS_DLQ)"
NOTAS_TOPIC_ARN=$(awslocal sns create-topic --name "$NOTAS_TOPIC" \
  --attributes FifoTopic=true,ContentBasedDeduplication=false --query TopicArn --output text)
awslocal sqs create-queue --queue-name "$NOTAS_DLQ" --attributes FifoQueue=true >/dev/null
NOTAS_DLQ_URL=$(awslocal sqs get-queue-url --queue-name "$NOTAS_DLQ" --query QueueUrl --output text)
awslocal sqs create-queue --queue-name "$NOTAS_QUEUE" --attributes FifoQueue=true >/dev/null
NOTAS_QUEUE_URL=$(awslocal sqs get-queue-url --queue-name "$NOTAS_QUEUE" --query QueueUrl --output text)
NOTAS_QUEUE_ARN=$(queue_arn "$NOTAS_QUEUE_URL")
set_redrive "$NOTAS_QUEUE_URL" "$(queue_arn "$NOTAS_DLQ_URL")"
if ! awslocal sns list-subscriptions-by-topic --topic-arn "$NOTAS_TOPIC_ARN" \
  --query 'Subscriptions[].Endpoint' --output text | grep -q "$NOTAS_QUEUE_ARN"; then
  awslocal sns subscribe --topic-arn "$NOTAS_TOPIC_ARN" --protocol sqs \
    --notification-endpoint "$NOTAS_QUEUE_ARN" --attributes RawMessageDelivery=true >/dev/null
fi
set_queue_policy "$NOTAS_QUEUE_URL" "$NOTAS_QUEUE_ARN" "sns.amazonaws.com" "$NOTAS_TOPIC_ARN"

log "Listo. Recursos disponibles:"
log "  S3          $BUCKET"
log "  DynamoDB    $TABLE"
log "  SQS         $QUEUE (DLQ: $DLQ)"
log "  SNS         $TOPIC -> $NOTIF_QUEUE"
log "  EventBridge $BUS / $RULE -> $QUEUE"
log "  ENG-01      $NTF_TABLE · $NTF_RULE -> $NTF_QUEUE · $NOTAS_TOPIC -> $NOTAS_QUEUE"
