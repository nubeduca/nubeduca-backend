# REL-02 · Salida a producción con el curso piloto

Runbook de [REL-02](https://github.com/nubeduca/nubeduca-backlog/issues/33) (Dev 1 @cruz-eng y Dev 5 @AIexander-lx).

**Listo cuando:** un curso real opera en producción (gate de Fase 1).

## 1. Antes de empezar (todo debe estar en verde)

| # | Condición | Cómo se comprueba | Tarea |
|---|---|---|---|
| 1 | Staging del equipo desplegado con alarmas en verde | `scripts/verificar_alarmas.sh staging` | [REL-01](https://github.com/nubeduca/nubeduca-backlog/issues/28) |
| 2 | El E2E del piloto pasa en ese staging | `python qa/piloto.py --stage staging` → `38/38 pasos OK` | [QA-01](https://github.com/nubeduca/nubeduca-backlog/issues/31) |
| 3 | **Las rutas de los 6 microservicios tienen el authorizer de Cognito** | `grep -n "authorizer:" serverless.yml` en cada `nubeduca-ms-*` (ver §2) | REL-01 · AUTH-01 |
| 4 | El E2E pasa con login real | `python qa/piloto.py --stage staging --auth cognito --password ...` | QA-01 |
| 5 | Outbox con EventBridge Pipes en los 6 microservicios | `params.default.outbox: pipe` en cada `serverless.yml` | [ADR-008](https://github.com/nubeduca/nubeduca-backlog/issues/35) |
| 6 | Se sabe en qué cuenta vive prod y quién tiene sus credenciales | `scripts/cuenta.sh` con el `.env` de esa cuenta | REL-01 (D2) |

Si falta una, no se sale a producción.

## 2. Por qué prod necesita el authorizer (y qué hace `desplegar.sh prod`)

Todos los microservicios tienen `authMode: mock` por defecto. En ese modo, `lib/auth.py` acepta cualquier `Bearer mock.<tenant>.<ROL>.<userId>`: **cualquiera puede armarse un token de ADMIN de cualquier institución**. En producción eso no puede pasar.

El otro modo, `authMode: cognito`, lee los claims que deja el authorizer de API Gateway (`requestContext.authorizer.claims`). Si la ruta **no tiene** el authorizer, no hay claims y todo responde 401.

Por eso `scripts/desplegar.sh prod` hace dos cosas con cada `nubeduca-ms-*`:

1. Si su `serverless.yml` no tiene ningún `authorizer:` activo, **no lo despliega** y lo marca como FALLIDO:
   ```text
   ms-cursos: sin authorizer de Cognito en serverless.yml -> no se despliega en prod
   ```
2. Si lo tiene, lo despliega con `--param="authMode=cognito"`.

En `dev` y `staging` no cambia nada.

### Cómo agregar el authorizer en un microservicio

En cada ruta protegida (todas menos `/health`), con el User Pool que exporta `infra/auth`:

```yaml
functions:
  cursos:
    handler: api/cursos.lambda_handler
    events:
      - http:
          path: /courses
          method: get
          cors: true
          authorizer:
            type: COGNITO_USER_POOLS
            arn: ${cf:nubeduca-infra-auth-${sls:stage}.UserPoolArn}
```

El frontend tiene que mandar el **ID token** (no el access token), porque solo ese trae `custom:tenant_id` y `custom:role`.

## 3. Despliegue

```bash
cd nubeduca-backend && git pull
cp .env.example .env              # credenciales de la cuenta de prod
scripts/cuenta.sh                 # confirma la cuenta y el rol antes de crear nada
scripts/desplegar.sh prod         # infra -> 6 microservicios (con Cognito) -> frontend -> /health
scripts/verificar_alarmas.sh prod
```

- El frontend de prod sale con `VITE_AUTH_MODE=cognito`: `desplegar.sh prod` le pasa `--param="authMode=cognito"` a `infra/frontend`.
- **No** usar `--con-seed` en prod: el seed escribe 30.000 registros de prueba por servicio.
- En prod la tabla de auditoría de notas tiene protección contra borrado (`DeletionProtectionEnabled`). `serverless remove --stage prod` falla a propósito.

## 4. El curso piloto en producción

Con datos reales y no con los del script de QA (que crea usuarios y cursos de prueba):

| # | Paso | Quién |
|---|---|---|
| 1 | Crear en el User Pool de prod las cuentas reales: un ADMIN, el docente y los alumnos del piloto (`custom:tenant_id` y `custom:role`) | Dev 1 |
| 2 | El ADMIN entra y abre y activa el periodo real | ADMIN de la institución |
| 3 | El docente entra, crea el curso, lo publica y matricula a los alumnos (CSV) | docente |
| 4 | El docente publica el primer módulo con material y la primera tarea | docente |
| 5 | Un alumno entra, ve el módulo, descarga el material y entrega la tarea | alumno |
| 6 | El docente califica y publica la nota; el alumno la ve y le llega el aviso | docente, alumno |

**Evidencia para cerrar REL-02:** capturas del curso en el frontend de prod, `verificar_alarmas.sh prod` en verde y el historial de auditoría de la nota (`GET /grades/{gradeId}/history`).

## 5. Si algo sale mal

| Problema | Qué hacer |
|---|---|
| Un microservicio falla al desplegar | Lo dice el resumen de `desplegar.sh`; corregir y `scripts/desplegar.sh prod --solo <ms>` |
| Los eventos no llegan al bus | Volver al relay en ese servicio: `serverless deploy --stage prod --param="authMode=cognito" --param="outbox=lambda"` |
| Una versión nueva rompe algo | Volver al commit anterior de `main` de ese servicio y `desplegar.sh prod --solo <ms>` |
| Todo responde 401 | Revisar que el frontend mande el ID token y que el authorizer apunte al User Pool de prod |
| Una alarma de DLQ en rojo | Ver los logs de la Lambda del consumidor en CloudWatch; los mensajes quedan en la DLQ 14 días |

## 6. Límites del Learner Lab

- Las credenciales del lab caducan (unas 4 horas): hay que renovarlas en el `.env` antes de desplegar.
- No se pueden crear roles: todo usa `LabRole`.
- X-Ray tiene límites en el lab (#34): la evidencia de trazas es CloudWatch Logs.
- SES puede no enviar correos fuera del sandbox: el aviso queda guardado aunque el correo falle.
