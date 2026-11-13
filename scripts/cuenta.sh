#!/usr/bin/env bash
# Carga las credenciales de AWS desde .env y verifica la cuenta destino.
#
# Uso directo (solo verifica):   scripts/cuenta.sh
# Desde otro script:             source scripts/cuenta.sh && cargar_cuenta
#
# El archivo es <raíz del repo>/.env; otro archivo con NUBEDUCA_ENV_FILE=ruta.
# Ignora AWS_PROFILE y ~/.aws/credentials a propósito: así nunca se despliega
# por accidente en la cuenta que tenga configurada la terminal.

_NUBEDUCA_RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Lee solo líneas CLAVE=valor del .env, sin ejecutar su contenido.
_leer_env() {
  local archivo="$1" linea clave valor
  while IFS= read -r linea || [ -n "$linea" ]; do
    linea="${linea%$'\r'}"
    case "$linea" in '' | '#'*) continue ;; esac
    clave="${linea%%=*}"
    valor="${linea#*=}"
    [[ "$clave" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    # Quita comillas envolventes, si las hay.
    if [[ "$valor" =~ ^\"(.*)\"$ || "$valor" =~ ^\'(.*)\'$ ]]; then
      valor="${BASH_REMATCH[1]}"
    fi
    export "$clave=$valor"
  done < "$archivo"
}

cargar_cuenta() {
  local archivo="${NUBEDUCA_ENV_FILE:-$_NUBEDUCA_RAIZ/.env}"
  if [ ! -f "$archivo" ]; then
    echo "No existe $archivo. Copia .env.example a .env y llénalo." >&2
    return 1
  fi

  unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  _leer_env "$archivo"

  local falta=()
  for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION NUBEDUCA_AWS_ACCOUNT_ID; do
    [ -n "${!v:-}" ] || falta+=("$v")
  done
  if [ ${#falta[@]} -gt 0 ]; then
    echo "Faltan en $archivo: ${falta[*]}" >&2
    return 1
  fi
  [ -n "${AWS_SESSION_TOKEN:-}" ] || unset AWS_SESSION_TOKEN
  export AWS_DEFAULT_REGION="$AWS_REGION"

  local identidad cuenta arn
  if ! identidad="$(aws sts get-caller-identity --output text --query '[Account,Arn]' 2>&1)"; then
    echo "Las credenciales de $archivo no funcionan (¿caducó la sesión del lab?):" >&2
    echo "$identidad" >&2
    return 1
  fi
  cuenta="$(cut -f1 <<< "$identidad")"
  arn="$(cut -f2 <<< "$identidad")"
  if [ "$cuenta" != "$NUBEDUCA_AWS_ACCOUNT_ID" ]; then
    echo "Las credenciales son de la cuenta $cuenta, pero NUBEDUCA_AWS_ACCOUNT_ID=$NUBEDUCA_AWS_ACCOUNT_ID. No se despliega nada." >&2
    return 1
  fi
  echo "Cuenta $cuenta · $AWS_REGION · $arn"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  cargar_cuenta
fi
