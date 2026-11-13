#!/usr/bin/env bash
# Despliega el frontend (Amplify) en la cuenta del .env y lanza el primer build.
#
#   infra/frontend/desplegar.sh <stage> [opciones extra de serverless]
#   infra/frontend/desplegar.sh dev
#   infra/frontend/desplegar.sh dev --param="mocks=false"
#
# Pasos: verifica la cuenta, guarda el token de GitHub en Secrets Manager de
# ESA cuenta, corre serverless deploy, lanza el build de la rama y espera.
set -euo pipefail

STAGE="${1:?Uso: infra/frontend/desplegar.sh <stage> [opciones de serverless]}"
shift

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../../scripts/cuenta.sh
source "$AQUI/../../scripts/cuenta.sh"
cargar_cuenta

SECRETO="nubeduca/github-amplify-token"
if [ -z "${GITHUB_TOKEN_AMPLIFY:-}" ]; then
  echo "Falta GITHUB_TOKEN_AMPLIFY en el .env." >&2
  exit 1
fi

# El token va por archivo temporal (no en la línea de comandos, que ve `ps`).
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"
printf '%s' "$GITHUB_TOKEN_AMPLIFY" > "$TMP"
if aws secretsmanager describe-secret --secret-id "$SECRETO" > /dev/null 2>&1; then
  aws secretsmanager put-secret-value --secret-id "$SECRETO" --secret-string "file://$TMP" > /dev/null
  echo "Secreto $SECRETO actualizado."
else
  aws secretsmanager create-secret --name "$SECRETO" --secret-string "file://$TMP" \
    --description "Token de GitHub para que Amplify conecte nubeduca-frontend" > /dev/null
  echo "Secreto $SECRETO creado."
fi
rm -f "$TMP"

(cd "$AQUI" && serverless deploy --stage "$STAGE" "$@")

PILA="nubeduca-frontend-$STAGE"
salida() {
  aws cloudformation describe-stacks --stack-name "$PILA" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
APP_ID="$(salida AmplifyAppId)"
URL="$(salida FrontendUrl)"
RAMA="$(sed -E 's|https://([^.]+)\..*|\1|' <<< "$URL")"

JOB="$(aws amplify start-job --app-id "$APP_ID" --branch-name "$RAMA" --job-type RELEASE \
  --query 'jobSummary.jobId' --output text)"
echo "Build $JOB lanzado en Amplify (app $APP_ID, rama $RAMA). Esperando..."

while true; do
  ESTADO="$(aws amplify get-job --app-id "$APP_ID" --branch-name "$RAMA" --job-id "$JOB" \
    --query 'job.summary.status' --output text)"
  case "$ESTADO" in
    SUCCEED) echo "Listo: $URL"; break ;;
    FAILED | CANCELLED) echo "El build terminó en $ESTADO. Revisa la consola de Amplify." >&2; exit 1 ;;
    *) sleep 15 ;;
  esac
done
