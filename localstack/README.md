# LOC-01 · Entorno local con LocalStack

Emula **EventBridge, SQS, SNS, S3 y DynamoDB** en Docker para desarrollar sin depender de AWS ni gastar crédito del Learner Lab.

- No hay que crear nada a mano: al arrancar, LocalStack ejecuta `init/01-recursos.sh` y deja el bus, las colas, el topic, el bucket y la tabla listos.
- Todo vive en `http://localhost:4566`. **No usa credenciales reales**: el SDK/CLI debe apuntar al endpoint con credenciales falsas.

## Levantar todo (un comando)

```bash
docker compose up -d --wait
```

Eso es todo: el contenedor queda *healthy* y los recursos creados. Requiere Docker Desktop (o Docker Engine + Compose v2) corriendo.

En Windows también hay un wrapper que además imprime el resumen y corrige las variables de entorno solo para su ejecución:

```powershell
.\scripts\up.ps1
```

## Verificar los dos criterios de aceptación

**1) El evento de prueba llega a una cola SQS local** (`EventBridge → SQS`):

```powershell
.\scripts\test-evento.ps1        # Windows
```

```bash
./scripts/test-evento.sh         # Linux / macOS / WSL
```

**2) Los cinco servicios responden** (S3, DynamoDB, SQS, SNS y EventBridge):

```powershell
.\scripts\smoke.ps1              # Windows
```

```bash
./scripts/smoke.sh               # Linux / macOS / WSL
```

## Qué queda creado

| Servicio | Recurso | Detalle |
|---|---|---|
| EventBridge | bus `lms` | bus de dominio separado del `default` |
| EventBridge | regla `nubeduca-local-enrollment-created` | `source = lms.courses`, `detail-type = lms.courses.enrollment.created.v1` |
| SQS | `nubeduca-local-cursos-eventos` | destino de la regla; DLQ con `maxReceiveCount = 5` |
| SQS | `nubeduca-local-cursos-eventos-dlq` | mensajes que fallan 5 veces |
| SNS | `nubeduca-local-notificaciones` | suscrito a la cola `nubeduca-local-notificaciones` (raw delivery). ms-notificaciones publica aquí sus emails: se ven en esa cola |
| SQS | `nubeduca-local-notificaciones` | consumidor de ejemplo del topic SNS |
| S3 | `nubeduca-local-materiales` | material de cursos / archivos |
| DynamoDB | `local-t_demo` | PK `tenant_id` + SK `sk`, modo `PAY_PER_REQUEST` |
| DynamoDB | `local-t_notificaciones` | ENG-01 · tabla de ms-notificaciones (PK `tenant_id` + SK `sk`) |
| EventBridge | regla `nubeduca-local-notificaciones` | ENG-01 · eventos que consume ms-notificaciones → `nubeduca-local-notificaciones-eventos` |
| SQS | `nubeduca-local-notificaciones-eventos` | ENG-01 · DLQ `nubeduca-local-notificaciones-eventos-dlq` con `maxReceiveCount = 5` |
| SNS | `local-notas.fifo` | ENG-01 · tópico FIFO de `grade.posted`, suscrito a `nubeduca-local-notificaciones-notas.fifo` (raw) |
| SQS | `nubeduca-local-notificaciones-notas.fifo` | ENG-01 · DLQ `nubeduca-local-notificaciones-notas-dlq.fifo` |

El script es **idempotente**: se puede correr las veces que haga falta (lo hace `up.ps1` después de arrancar).

## Apuntar el SDK / la CLI a LocalStack

```bash
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
```

```powershell
$env:AWS_ENDPOINT_URL="http://localhost:4566"; $env:AWS_ACCESS_KEY_ID="test"
$env:AWS_SECRET_ACCESS_KEY="test"; $env:AWS_DEFAULT_REGION="us-east-1"
```

En Python (boto3) y Node (AWS SDK v3) se usa `endpoint_url` / `endpoint` con los mismos valores.

## Publicar un evento a mano

```bash
# desde la carpeta localstack/
aws events put-events --entries file://eventos/enrollment-created.json
aws sqs receive-message --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/nubeduca-local-cursos-eventos --wait-time-seconds 5
```

## Bajar y limpiar

```bash
docker compose down -v
```

```powershell
.\scripts\down.ps1
```

`-v` borra el estado local (no hay persistencia: al volver a levantar, todo se recrea).

## Agregar recursos para tu microservicio

1. Edita `init/01-recursos.sh` (crea tabla, cola, regla, topic…).
2. Si es una cola que recibe de EventBridge o SNS, **aplícale la política** con `set_queue_policy`; sin eso el mensaje se descarta.
3. Corre `docker compose exec localstack bash /etc/localstack/init/ready.d/01-recursos.sh` o `.\scripts\up.ps1`.
4. Si agregas un servicio de LocalStack (p. ej. `lambda`), añádelo a `SERVICES` en `docker-compose.yml`.

## Estructura

```
localstack/
├── docker-compose.yml          # el "un comando"
├── init/01-recursos.sh         # crea todos los recursos (idempotente)
├── eventos/enrollment-created.json   # evento de prueba del catálogo v1
└── scripts/
    ├── up.ps1 / up.sh
    ├── test-evento.ps1 / test-evento.sh
    ├── smoke.ps1 / smoke.sh
    └── down.ps1 / down.sh
```

## Troubleshooting

| Síntoma | Causa / solución |
|---|---|
| `failed to connect to the docker API` | Docker Desktop no está abierto. |
| `docker compose up` falla en `--wait` | El healthcheck espera SQS; revisa `docker compose logs localstack`. |
| El evento no llega a la cola | Falta la política de la cola (`set_queue_policy`) o la regla está en otro bus. |
| `InvalidClientTokenId` / `Unable to locate credentials` | Faltan las credenciales falsas (`test` / `test`) y `AWS_DEFAULT_REGION`. |
| El CLI pega a AWS real | Falta `AWS_ENDPOINT_URL=http://localhost:4566` (o `--endpoint-url`). |
| Los recursos desaparecieron | `docker compose down -v` los borra a propósito; vuelve a levantar. |
