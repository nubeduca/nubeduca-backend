# nubeduca-backend

Infraestructura compartida de Nubeduca (LMS SaaS multi-tenant: `utec`, `upc` y `pucp`).

Desde el 13 nov. (decisión **D1**) este repo es **solo infraestructura**. Cada microservicio vive en su propio repo `nubeduca-ms-*`, creado desde [`nubeduca-plantilla-servicio`](https://github.com/nubeduca/nubeduca-plantilla-servicio). Aquí está lo que no es código de un microservicio: stacks compartidos, entorno local y scripts de despliegue.

## Contenido

| Carpeta o archivo | Qué es | Tarea | Estado |
|---|---|---|---|
| [`infra/base/`](infra/base/) | Bucket de despliegue y parámetros SSM `/nubeduca/<stage>/*` (nombre del bus, tenants) | PLT-03 | ✅ |
| [`infra/bus/`](infra/bus/) | Bus `lms-<stage>` de EventBridge, Archive y SNS FIFO de notas | PLT-04 | ✅ |
| `infra/auth/` | Cognito con `tenant_id` y rol en el token | AUTH-01 | ⏳ por hacer |
| [`infra/frontend/`](infra/frontend/) | Amplify Hosting de `nubeduca-frontend` como IaC, con variables `VITE_*` leídas de SSM | PLT-06 | ✅ |
| `infra/despliegue/` | VM `nubeduca-despliegue` (EC2 con `LabInstanceProfile`, sin puertos) | PLT-06 | 🟡 [PR #8](https://github.com/nubeduca/nubeduca-backend/pull/8) |
| [`scripts/cuenta.sh`](scripts/cuenta.sh) | Carga las credenciales del `.env` y verifica la cuenta antes de desplegar | PLT-06 | ✅ |
| `scripts/desplegar.sh` | Despliega todo en orden: base → bus → auth → 6 `ms-*` → frontend | PLT-06 | 🟡 [PR #8](https://github.com/nubeduca/nubeduca-backend/pull/8) |
| [`localstack/`](localstack/) | Entorno local (EventBridge, SQS, SNS, S3 y DynamoDB) | LOC-01 | ✅ |
| [`plantillas/`](plantillas/) | Consumidor de eventos (regla + cola + DLQ) y endpoint protegido | PLT-04, PLT-05 | ✅ |
| [`aws-learner-lab.md`](aws-learner-lab.md) | Guía de AWS: credenciales, stages, LabRole, CORS, `.env` y despliegue integrado | PLT-01, PLT-05, PLT-06 | ✅ |

Convención de ramas y PRs en [CONTRIBUTING.md](CONTRIBUTING.md).

## Desplegar en AWS

Las credenciales nunca van en el repo: cada dev usa un `.env` propio, que está en `.gitignore`.

```bash
cp .env.example .env      # credenciales del Learner Lab, NUBEDUCA_AWS_ACCOUNT_ID, GITHUB_TOKEN_AMPLIFY, SERVERLESS_ACCESS_KEY
scripts/cuenta.sh         # muestra la cuenta y el rol; se detiene si no es NUBEDUCA_AWS_ACCOUNT_ID
```

**Cuenta de integración (D2):** es el Learner Lab de Dev 3. Todo lo integrado se despliega desde la VM `nubeduca-despliegue` con:

```bash
scripts/desplegar.sh staging --con-seed
```

En la VM, `NUBEDUCA_CREDENCIALES=instancia` hace que se use el rol de la instancia y no claves. El paso a paso está en la sección 9 de [`aws-learner-lab.md`](aws-learner-lab.md).

**Un stack suelto, en tu propia cuenta:**

```bash
source scripts/cuenta.sh && cargar_cuenta
(cd infra/base && serverless deploy --stage dev)
(cd infra/bus && serverless deploy --stage dev)
infra/frontend/desplegar.sh dev           # Amplify: guarda el token en Secrets Manager, despliega y lanza el build
```

Ningún `serverless.yml` fija `org:`. Serverless v4 usa la org de `SERVERLESS_ACCESS_KEY` (la del equipo) o la de `serverless login`, así que el mismo IaC se despliega en cualquier cuenta.

## Entorno local

```bash
git clone https://github.com/nubeduca/nubeduca-backend.git
cd nubeduca-backend/localstack
docker compose up -d --wait
```

Todo queda en `http://localhost:4566` con credenciales falsas. No hace falta cuenta de AWS ni gastar crédito del Learner Lab.

Verificación rápida:

```powershell
.\scripts\test-evento.ps1    # un evento de EventBridge llega a una cola SQS
.\scripts\smoke.ps1          # S3, DynamoDB, SQS, SNS y EventBridge responden
```

```bash
./scripts/test-evento.sh
./scripts/smoke.sh
```

Detalle de recursos, variables de entorno y troubleshooting: [`localstack/README.md`](localstack/README.md).

## Reglas del repo

- `main` está protegida: todo entra por PR con 1 aprobación y la CI en verde (yamllint, ruff y pytest).
- Los scripts `.sh` corren en Linux: se fuerzan a **LF** con `.gitattributes`, también en Windows.
- Un recurso local nuevo se agrega en `localstack/init/01-recursos.sh`, que es idempotente.
- Nada de credenciales reales en el repo: LocalStack usa `test` / `test`, y en AWS se usa el `.env` de cada dev.
- `services/` es del diseño anterior (monorepo). Con D1 ya no se usa y lo retira el PR de seguimiento de PLT-02.
