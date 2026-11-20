#!/bin/bash
# Crea los usuarios de la demo en Cognito. Se puede ejecutar varias veces.
# Uso: ./scripts/crear_usuarios_demo.sh [stage]      (por defecto: dev)

STAGE=${1:-dev}
PASS=${DEMO_PASSWORD:-Nubeduca2026!}
POOL=$(aws cloudformation describe-stacks --stack-name "nubeduca-infra-auth-${STAGE}" \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)

crear() {
  aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$1" \
    --user-attributes Name=email,Value="$1" Name=email_verified,Value=true \
      Name=custom:tenant_id,Value="$2" Name=custom:role,Value="$3" \
    --message-action SUPPRESS >/dev/null 2>&1 || echo "  (ya existía: $1)"
  aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$1" \
    --password "$PASS" --permanent
  echo "OK  $1  tenant=$2  rol=$3"
}

crear docente.demo@utec.edu.pe utec TEACHER
crear alumno.demo@utec.edu.pe utec STUDENT
crear docente.demo@upc.edu.pe upc TEACHER
crear alumno.demo@upc.edu.pe upc STUDENT