# Prueba de carga (PERF-01)

Scripts de [k6](https://k6.io), tokens de prueba y dashboard de CloudWatch. La corrida corta (`PERFIL=corto`) va contra `dev`. La prueba de estrés (`PERFIL=estres`) es PERF-02 y va contra `staging`.

```text
perf/
├── k6/carga_cursos.js          # escenario: listar cursos y ver el detalle, con utec/upc/pucp en 15/10/5
├── tokens/generar_tokens.sh    # ID tokens de Cognito de los usuarios demo (solo con authMode=cognito)
└── reportes/                   # salida de cada corrida (no se sube)
infra/observabilidad/           # dashboard nubeduca-<stage> en CloudWatch
```

## 1. Dashboard

```bash
cd infra/observabilidad && serverless deploy --stage dev && cd ../..
```

En CloudWatch → Dashboards → `nubeduca-dev`. Usa expresiones `SEARCH`, así que muestra todos los recursos `nubeduca` del stage (API Gateway, Lambda, DynamoDB, SQS, DLQ y reglas de EventBridge) sin listarlos a mano.

## 2. Instalar k6 (Cloud9, Ubuntu)

```bash
V=$(curl -s https://api.github.com/repos/grafana/k6/releases/latest | grep -oP '"tag_name": "\K[^"]+')
curl -sL "https://github.com/grafana/k6/releases/download/$V/k6-$V-linux-amd64.tar.gz" | tar xz -C /tmp
sudo mv "/tmp/k6-$V-linux-amd64/k6" /usr/local/bin/ && k6 version
```

## 3. Corrida corta contra dev

Con `ms-cursos` desplegado en `dev` (y su seed cargado):

```bash
mkdir -p perf/reportes
URL=$(aws ssm get-parameter --name /nubeduca/dev/api/cursos/url --query Parameter.Value --output text)
K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT=perf/reportes/reporte-corto.html \
  k6 run -e BASE_URL="$URL" perf/k6/carga_cursos.js
```

Con Cognito (`authMode=cognito` en el servicio):

```bash
export DEMO_PASSWORD='...'
perf/tokens/generar_tokens.sh dev
k6 run -e BASE_URL="$URL" -e AUTH_MODE=cognito -e TOKENS_FILE="$PWD/perf/tokens/tokens.json" perf/k6/carga_cursos.js
```

## Qué deja cada corrida

- En la consola: resumen con p95 y p99, tasa de errores y si se cumplieron las metas (`thresholds`).
- `perf/reportes/resumen-<perfil>-<fecha>.json`: el mismo resumen en JSON, para el informe.
- `perf/reportes/reporte-<perfil>.html`: gráficos de k6 (si se usa `K6_WEB_DASHBOARD_EXPORT`).
- El dashboard `nubeduca-<stage>` con lo que pasó del lado de AWS en ese rango de tiempo.

## Metas (provisionales)

| Métrica | Meta |
|---|---|
| Peticiones fallidas | < 1 % |
| p95 de `GET /courses` y `GET /courses/{courseId}` | < 1000 ms |
| DLQ | 0 mensajes |

Se ajustan a la sección 13 del documento de arquitectura.

## Límites del Learner Lab

- Presupuesto: cada cuenta tiene ~50 USD en total. El perfil `corto` (~700 peticiones) cuesta centavos. El perfil `estres` solo corre con `-e CONFIRMAR=si` y debe ir en la cuenta de integración (PERF-02), no en la de un dev.
- Mira el gasto en el panel del Learner Lab antes y después de cada corrida.
- Al terminar, borra lo que no uses: `serverless remove --stage dev` en el microservicio y en `infra/observabilidad`.
- Todo usa `LabRole`; no se crea ningún rol IAM.

- Concurrencia de Lambda de la cuenta: 1000 (`aws lambda get-account-settings`).
- Las credenciales caducan cada ~4 h y los ID tokens de Cognito cada 1 h: regenera ambos antes de una corrida larga.
- X-Ray no se puede leer con `voclabs` (#34); la evidencia es el dashboard y CloudWatch Logs.

## Pendiente

- Escenario de escritura (crear curso, matricular) para cargar también el bus y las colas. Requiere un periodo activo en ms-cursos.
