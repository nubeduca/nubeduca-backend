#!/usr/bin/env bash
# Revisa que todas las alarmas de CloudWatch del proyecto esten en verde (OK).
# Criterio de REL-01: "todos los servicios en staging con alarmas en verde".
#
#   scripts/verificar_alarmas.sh <stage>
#   scripts/verificar_alarmas.sh staging
#
# Lee las credenciales del .env igual que desplegar.sh (scripts/cuenta.sh).
# Sale con codigo 0 si todas estan en OK; 1 si alguna esta en ALARM o INSUFFICIENT_DATA.
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STAGE="${1:-}"
case "$STAGE" in dev | staging | prod | ensayo) ;; *) echo "Uso: $0 <dev|staging|prod>"; exit 2 ;; esac

# shellcheck source=SCRIPTDIR/cuenta.sh
source "$RAIZ/scripts/cuenta.sh"
cargar_cuenta || exit 1

PREFIJO="nubeduca-${STAGE}-"
# Nombre y estado de cada alarma del proyecto en este stage.
LINEAS="$(MSYS_NO_PATHCONV=1 aws cloudwatch describe-alarms \
  --alarm-name-prefix "$PREFIJO" \
  --query 'MetricAlarms[].[AlarmName,StateValue]' \
  --output text | tr -d '\r')"

if [ -z "$LINEAS" ]; then
  echo "No hay alarmas con prefijo $PREFIJO. ¿Se desplegó algo en $STAGE?" >&2
  exit 1
fi

printf '\n%-48s %s\n' "ALARMA" "ESTADO"
FUERA=0
while IFS=$'\t' read -r nombre estado; do
  [ -n "$nombre" ] || continue
  printf '%-48s %s\n' "$nombre" "$estado"
  [ "$estado" = "OK" ] || FUERA=$((FUERA + 1))
done <<< "$LINEAS"

echo
if [ "$FUERA" -eq 0 ]; then
  echo "Todas en verde (OK) en $STAGE."
else
  echo "$FUERA alarma(s) NO están en verde en $STAGE." >&2
fi
[ "$FUERA" -eq 0 ]
