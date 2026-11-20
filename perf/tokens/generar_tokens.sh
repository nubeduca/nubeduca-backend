#!/usr/bin/env bash
# PERF-01: saca los ID tokens de Cognito de los usuarios demo para k6 (authMode=cognito).
# Con authMode=mock no hace falta: k6 arma los tokens mock solo.
#
# Uso (desde la raíz de nubeduca-backend):
#   export DEMO_PASSWORD='...'        # comillas simples por el "!"
#   perf/tokens/generar_tokens.sh dev
#
# Los ID tokens caducan en 1 hora: vuelve a correrlo antes de cada prueba.
# Salida: perf/tokens/tokens.json (está en .gitignore, no se sube).
set -euo pipefail

STAGE="${1:-dev}"
: "${DEMO_PASSWORD:?Define DEMO_PASSWORD con la contraseña de los usuarios demo}"
SALIDA="$(dirname "$0")/tokens.json"

CLIENT_ID=$(aws cloudformation list-exports \
  --query "Exports[?Name=='nubeduca-${STAGE}-user-pool-client-id'].Value" --output text)
if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" = "None" ]; then
  echo "No encuentro el export nubeduca-${STAGE}-user-pool-client-id. ¿Está desplegado infra/auth en ${STAGE}?" >&2
  exit 1
fi

token() {
  local t
  t=$(aws cognito-idp initiate-auth --client-id "$CLIENT_ID" --auth-flow USER_PASSWORD_AUTH \
    --auth-parameters "{\"USERNAME\":\"$1\",\"PASSWORD\":\"$DEMO_PASSWORD\"}" \
    --query AuthenticationResult.IdToken --output text)
  if [ -z "$t" ] || [ "$t" = "None" ]; then
    echo "No obtuve token para $1 (¿existe el usuario? corre scripts/crear_usuarios_demo.sh)" >&2
    exit 1
  fi
  echo "$t"
}

cat > "$SALIDA" <<EOF
{
  "utec": {
    "TEACHER": "$(token docente.demo@utec.edu.pe)",
    "STUDENT": "$(token alumno.demo@utec.edu.pe)"
  },
  "upc": {
    "TEACHER": "$(token docente.demo@upc.edu.pe)",
    "STUDENT": "$(token alumno.demo@upc.edu.pe)"
  }
}
EOF

echo "Tokens guardados en $SALIDA (válidos 1 hora)"
