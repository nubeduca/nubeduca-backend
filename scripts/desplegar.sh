#!/usr/bin/env bash
# Despliega Nubeduca completo en la cuenta del .env (PLT-06, decisión D2).
#
#   scripts/desplegar.sh <stage> [opciones]
#   scripts/desplegar.sh staging                       # todo
#   scripts/desplegar.sh staging --con-seed            # y carga los 30.000 registros por servicio
#   scripts/desplegar.sh dev --solo usuarios,cursos    # solo esos microservicios (sin infra ni frontend)
#   NUBEDUCA_SIMULAR=1 scripts/desplegar.sh staging    # muestra los pasos sin tocar AWS
#
# Orden: infra/base -> infra/bus -> infra/auth (si existe) -> cada nubeduca-ms-* -> frontend.
# Los microservicios se clonan (o actualizan desde main) en NUBEDUCA_SERVICIOS_DIR.
# Un microservicio sin serverless.yml queda como PENDIENTE y no frena el resto.
# Termina con una prueba de humo (GET /health de cada API) y un resumen.
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MICROSERVICIOS=(usuarios cursos contenidos evaluaciones calificaciones notificaciones)
ORG_GIT="https://github.com/nubeduca"
SIMULAR="${NUBEDUCA_SIMULAR:-0}"

uso() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

STAGE="${1:-}"
case "$STAGE" in dev | staging | prod) shift ;; *) uso ;; esac
CON_SEED=0
SIN_FRONTEND=0
SOLO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --con-seed) CON_SEED=1 ;;
    --sin-frontend) SIN_FRONTEND=1 ;;
    --solo) SOLO="${2:-}"; shift ;;
    *) uso ;;
  esac
  shift
done

# shellcheck source=SCRIPTDIR/cuenta.sh
source "$RAIZ/scripts/cuenta.sh"
if [ "$SIMULAR" = "1" ]; then
  echo "SIMULACIÓN: no se toca AWS ni se clona nada."
else
  cargar_cuenta || exit 1
  for herramienta in serverless git python3 curl; do
    command -v "$herramienta" > /dev/null || { echo "Falta $herramienta en este equipo." >&2; exit 1; }
  done
fi
SERVICIOS_DIR="${NUBEDUCA_SERVICIOS_DIR:-$RAIZ/../servicios}"

DESPLEGADOS=()
PENDIENTES=()
FALLIDOS=()

paso() { printf '\n== %s\n' "$*"; }

correr() {  # correr <carpeta> <comando...>
  local carpeta="$1"; shift
  if [ "$SIMULAR" = "1" ]; then
    echo "  [$carpeta] $*"
    return 0
  fi
  (cd "$carpeta" && "$@")
}

desplegar_carpeta() {  # desplegar_carpeta <nombre> <carpeta>
  local nombre="$1" carpeta="$2"
  if [ "$SIMULAR" = "1" ] && [ ! -d "$carpeta" ]; then
    echo "  [$carpeta] (se clonaría) serverless deploy --stage $STAGE"
    DESPLEGADOS+=("$nombre")
    return 0
  fi
  if [ ! -f "$carpeta/serverless.yml" ]; then
    echo "  $nombre: sin serverless.yml -> PENDIENTE"
    PENDIENTES+=("$nombre")
    return 0
  fi
  if correr "$carpeta" serverless deploy --stage "$STAGE"; then
    DESPLEGADOS+=("$nombre")
  else
    echo "  $nombre: FALLÓ el despliegue" >&2
    FALLIDOS+=("$nombre")
  fi
}

traer_repo() {  # traer_repo <ms> -> imprime la carpeta
  local repo="nubeduca-ms-$1" destino="$SERVICIOS_DIR/nubeduca-ms-$1"
  if [ "$SIMULAR" = "1" ]; then
    echo "$destino"
    return 0
  fi
  mkdir -p "$SERVICIOS_DIR"
  if [ -d "$destino/.git" ]; then
    git -C "$destino" fetch -q origin main && git -C "$destino" checkout -q main \
      && git -C "$destino" merge -q --ff-only origin/main >&2
  else
    git clone -q "$ORG_GIT/$repo.git" "$destino" >&2
  fi
  echo "$destino"
}

sembrar() {  # sembrar <ms> <carpeta>
  local ms="$1" carpeta="$2" script=""
  for candidato in scripts/poblar_datos.py poblar_datos.py; do
    [ -f "$carpeta/$candidato" ] && script="$candidato" && break
  done
  if [ -z "$script" ] && [ "$SIMULAR" != "1" ]; then
    echo "  $ms: sin poblar_datos.py, no hay seed"
    return 0
  fi
  correr "$carpeta" python3 "${script:-scripts/poblar_datos.py}" --stage "$STAGE" \
    || { echo "  $ms: FALLÓ el seed" >&2; FALLIDOS+=("seed-$ms"); }
}

# --- Infraestructura -------------------------------------------------------------
if [ -z "$SOLO" ]; then
  for parte in base bus auth; do
    paso "infra/$parte"
    if [ -d "$RAIZ/infra/$parte" ]; then
      desplegar_carpeta "infra/$parte" "$RAIZ/infra/$parte"
    else
      echo "  infra/$parte: no existe todavía -> PENDIENTE"
      PENDIENTES+=("infra/$parte")
    fi
  done
fi

# --- Microservicios --------------------------------------------------------------
LISTA=("${MICROSERVICIOS[@]}")
if [ -n "$SOLO" ]; then
  IFS=',' read -r -a LISTA <<< "$SOLO"
fi
for ms in "${LISTA[@]}"; do
  paso "nubeduca-ms-$ms"
  if ! carpeta="$(traer_repo "$ms")"; then
    echo "  ms-$ms: no se pudo clonar" >&2
    FALLIDOS+=("ms-$ms")
    continue
  fi
  antes=${#DESPLEGADOS[@]}
  desplegar_carpeta "ms-$ms" "$carpeta"
  if [ "$CON_SEED" = "1" ] && [ ${#DESPLEGADOS[@]} -gt "$antes" ]; then
    sembrar "$ms" "$carpeta"
  fi
done

# --- Frontend --------------------------------------------------------------------
if [ -z "$SOLO" ] && [ "$SIN_FRONTEND" = "0" ]; then
  paso "frontend (Amplify)"
  if [ "$SIMULAR" = "1" ]; then
    echo "  [infra/frontend] desplegar.sh $STAGE"
    DESPLEGADOS+=("frontend")
  elif "$RAIZ/infra/frontend/desplegar.sh" "$STAGE"; then
    DESPLEGADOS+=("frontend")
  else
    FALLIDOS+=("frontend")
  fi
fi

# --- Prueba de humo --------------------------------------------------------------
paso "Prueba de humo: GET /health"
for ms in "${LISTA[@]}"; do
  [[ " ${DESPLEGADOS[*]-} " == *" ms-$ms "* ]] || continue
  if [ "$SIMULAR" = "1" ]; then
    echo "  ms-$ms: (simulado)"
    continue
  fi
  url="$(aws ssm get-parameter --name "/nubeduca/$STAGE/api/$ms/url" --query Parameter.Value --output text 2>/dev/null)"
  if [ -z "$url" ] || [ "$url" = "None" ]; then
    echo "  ms-$ms: no publicó su URL en /nubeduca/$STAGE/api/$ms/url"
    continue
  fi
  codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url/health")"
  echo "  ms-$ms: $codigo  $url/health"
  [ "$codigo" = "200" ] || FALLIDOS+=("health-$ms")
done

# --- Resumen ---------------------------------------------------------------------
paso "Resumen ($STAGE)"
echo "  Desplegados: ${DESPLEGADOS[*]:-ninguno}"
echo "  Pendientes:  ${PENDIENTES[*]:-ninguno}"
echo "  Fallidos:    ${FALLIDOS[*]:-ninguno}"
[ ${#FALLIDOS[@]} -eq 0 ]
