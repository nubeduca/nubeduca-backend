# Desplegar en AWS (Learner Lab)

Cómo desplegar un microservicio con Serverless Framework a los 3 stages
(`dev` / `staging` / `prod`) en la cuenta de **AWS Academy Learner Lab**, usando el
`LabRole`. (Tareas PLT-01 y PLT-05.)

> Para desarrollo local sin tocar AWS ni gastar crédito, usa LocalStack (ver el [README](README.md)).

## 1. Herramientas (una sola vez)
- Node 18+ (trae `npm`)
- **AWS CLI v2** → `winget install -e --id Amazon.AWSCLI` (Windows)
- **Serverless Framework** → `npm install -g serverless`, luego `serverless login` (cuenta gratis)

## 2. Credenciales del Learner Lab (cada sesión)
Son **temporales** (caducan en ~3–4 h o al parar el lab), así que esto se repite cada vez:

1. Entra al Learner Lab → **Start Lab** (espera el círculo verde junto a "AWS").
2. **AWS Details → AWS CLI → Show** y copia el bloque (empieza con `[default]`).
3. Pégalo en `~/.aws/credentials` (Windows: `C:\Users\<usuario>\.aws\credentials`),
   reemplazando el bloque `[default]`.
4. Verifica: `aws sts get-caller-identity` → muestra la cuenta y el rol `voclabs`.

El **crédito restante** se ve arriba en el Learner Lab (p. ej. `$2.40 / $50 used`).

## 3. Fix de variables de entorno (IMPORTANTE)
Serverless Framework v4 **no** pasa bien el `aws_session_token` del perfil con las
credenciales temporales del Learner Lab (sale `security token invalid`). Antes de
cualquier `serverless deploy`, carga las credenciales como variables de entorno (Git Bash):

```bash
export AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
export AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
export AWS_SESSION_TOKEN=$(aws configure get aws_session_token)
export AWS_DEFAULT_REGION=us-east-1
```

El `aws` CLI sí lee bien el perfil; esto es solo para que serverless reciba el token.

## 4. Desplegar (y borrar)
```bash
serverless deploy --stage dev        # o staging, o prod
serverless remove --stage dev        # borra ese stage
```
Cada stage es una **copia independiente** dentro de la misma cuenta
(recursos con prefijo `dev-`, `staging-`, `prod-`).

## 5. Convención del equipo
- Runtime **Python 3.13** · IaC **Serverless Framework v4** · Región **us-east-1**.
- Rol de ejecución (el Learner Lab no deja crear roles):
  `arn:aws:iam::${aws:accountId}:role/LabRole`.
- Stages: `dev` (desarrollo), `staging` (integración / pre-demo), `prod` (demo final).

## 6. Cuenta compartida (POR CONFIRMAR con el equipo)
El desarrollo lo hace cada uno en **su propio** Learner Lab (su `dev`). Pero el sistema
integrado (bus EventBridge, Cognito, eventos entre servicios) debe vivir en **UNA sola
cuenta**. Falta decidir:

- ¿Cuál Learner Lab es la **cuenta oficial** de integración?
- El deploy integrado (REL-01 / REL-02) lo hacen Dev 1 + Dev 2 con el código de todos;
  los compañeros entregan su **repo**, no sus credenciales.

## 7. CORS para Amplify (PLT-05)
Para que el frontend en Amplify pueda llamar a un endpoint desde el navegador, cada
microservicio habilita **CORS** en su `httpApi`. Es una línea en el `serverless.yml`:

```yaml
provider:
  httpApi:
    cors: true
```

Con eso, API Gateway responde el preflight `OPTIONS` y agrega las cabeceras
`Access-Control-Allow-*`. Probado contra un endpoint de ejemplo:

```
OPTIONS /hello  -> 204 · access-control-allow-origin: * · access-control-allow-methods: GET,OPTIONS
GET     /hello  -> 200 · access-control-allow-origin: *
```

> `cors: true` permite cualquier origen (suficiente para el MVP). Cuando el frontend
> tenga su dominio fijo de Amplify, se puede restringir a ese origen.

## 8. Credenciales por `.env` y despliegue en cualquier cuenta
El IaC no tiene ninguna cuenta fija: todo usa `${aws:accountId}` y `LabRole`.
Cada dev pone **sus** credenciales en un `.env` (está en `.gitignore`) y los
scripts las cargan como variables de entorno, lo que además evita el problema
del token de la sección 3.

```bash
cp .env.example .env      # llena AWS_*, NUBEDUCA_AWS_ACCOUNT_ID y GITHUB_TOKEN_AMPLIFY
scripts/cuenta.sh         # muestra la cuenta y el rol; se detiene si no coincide
```

`scripts/cuenta.sh` ignora `AWS_PROFILE` y `~/.aws/credentials`, y no sigue si
la cuenta de las credenciales no es `NUBEDUCA_AWS_ACCOUNT_ID`. Así nadie
despliega por error en otra cuenta que tenga configurada en su terminal.

Frontend en Amplify (guarda el token en Secrets Manager, despliega y lanza el build):

```bash
infra/frontend/desplegar.sh dev
```

Para demostrar que funciona en cualquier cuenta, basta cambiar el `.env` por el
de otro Learner Lab y volver a correr el mismo comando: sale otra app de Amplify
con otra URL, sin tocar el código.
