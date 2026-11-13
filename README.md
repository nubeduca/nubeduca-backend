# nubeduca-infra

Infraestructura compartida de Nubeduca (LMS SaaS multi-institución).

Un solo lugar para lo que **no** es código de un microservicio: entorno local, stacks base, bus de eventos y autenticación. Cualquier dev clona este repo para tener el mismo entorno que el resto.

## Contenido

| Carpeta | Qué es | Estado |
|---|---|---|
| [`localstack/`](localstack/) | Entorno local con LocalStack (EventBridge, SQS, SNS, S3 y DynamoDB) | ✅ listo (LOC-01) |
| [`aws-learner-lab.md`](aws-learner-lab.md) | Cómo desplegar a AWS (Learner Lab): credenciales, 3 stages y LabRole | ✅ PLT-01 |

Más adelante, según el roadmap del proyecto: stacks de AWS (`base/`, `bus/`, `auth/`).

## Empezar

```bash
git clone git@github.com:nubeduca/nubeduca-infra.git
cd nubeduca-infra/localstack
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

- Los scripts `.sh` corren dentro de contenedores Linux: se fuerzan a **LF** con `.gitattributes` (Windows incluido).
- Un recurso nuevo se agrega en `localstack/init/01-recursos.sh`, que es idempotente.
- Nada de credenciales reales en el repo: LocalStack usa `test` / `test`.
