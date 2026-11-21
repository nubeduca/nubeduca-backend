# QA-01 · E2E del curso piloto

Prueba de punta a punta de [QA-01](https://github.com/nubeduca/nubeduca-backlog/issues/31). Recorre el flujo completo del curso piloto en un stage desplegado (staging), **con 2 tenants a la vez**, y comprueba que ningún tenant ve los datos del otro.

**Listo cuando:** el flujo del curso piloto pasa completo con 2 tenants → `qa/piloto.py` termina con `RESULTADO: N/N pasos OK` y código 0.

## Cómo correrlo

```bash
cd nubeduca-backend
source scripts/cuenta.sh && cargar_cuenta          # credenciales de la cuenta donde está el stage
pip install boto3

python qa/piloto.py --stage staging                                   # tokens mock (authMode=mock)
python qa/piloto.py --stage staging --auth cognito --password '...'   # login real (authMode=cognito)
python qa/piloto.py --stage staging --reporte qa-staging.json         # guarda la evidencia en JSON
```

- Las URLs de las APIs salen de SSM (`/nubeduca/<stage>/api/<ms>/url`), las mismas que usa la prueba de humo de `desplegar.sh`. Si falta una, el script lo dice y no corre.
- **mock:** cada corrida crea usuarios nuevos (`mock.<tenant>.<ROL>.<uuid>`), así que se puede repetir sin limpiar nada.
- **cognito:** usa los usuarios de `scripts/crear_usuarios_demo.sh <stage>` (`admin.demo`, `docente.demo` y `alumno.demo` de cada tenant) y su ID token.
- Los efectos que viajan por eventos (proyecciones, antivirus, notas y avisos) se esperan hasta 90 s cada uno.

## El guion

Los dos tenants (por defecto `utec` y `upc`) corren este flujo en paralelo:

| # | Paso | Quién | Servicios y eventos que prueba |
|---|---|---|---|
| 0 | `GET /health` de los 6 microservicios | — | despliegue (REL-01) |
| 1 | Perfil (`POST /users/me`) | admin, docente y alumno | ms-usuarios · `user.provisioned` |
| 2 | Abre un periodo y lo activa | admin | ms-usuarios · `term.started` → ms-cursos |
| 3 | Crea el curso en ese periodo | docente | ms-cursos · `course.created` → ms-contenidos |
| 4 | Se matricula como TEACHER y matricula al alumno | docente | ms-cursos · `enrollment.created` → contenidos, evaluaciones, calificaciones y notificaciones |
| 5 | Publica el curso; el alumno lo ve en `GET /courses` | docente, alumno | ms-cursos · `course.published` → aviso `COURSE_PUBLISHED` |
| 6 | Publica un anuncio | docente | ms-cursos · `announcement.published` → aviso `ANNOUNCEMENT` |
| 7 | Sube un PDF, arma un módulo (página y archivo), lo publica; el alumno lo ve y descarga el PDF | docente, alumno | ms-contenidos (CON-01, CON-02) · S3, antivirus, `file.scanned`, `module.published` → aviso `MODULE` |
| 8 | Crea y publica una tarea | docente | ms-evaluaciones (EVA-01) · `assignment.published` → columna en ms-calificaciones y aviso `ASSIGNMENT` |
| 9 | Intenta entregar un archivo EICAR (409) y entrega su informe en PDF | alumno | antivirus → `file.scanned` → ms-evaluaciones · `submission.submitted` → aviso `SUBMISSION_RECEIPT` |
| 10 | Califica la entrega (15/20); la nota queda en DRAFT y el alumno todavía no la ve | docente, alumno | `submission.graded` → ms-calificaciones (EVA-02) · `grade.changed` |
| 11 | Publica la nota; el alumno ve 15/20 | docente, alumno | `grade.posted` (bus y SNS FIFO) → aviso `GRADE` |
| 12 | Ajusta la nota a 17 con un motivo; el historial tiene `GRADED` y `MANUAL_OVERRIDE` | docente | `grade.changed` → auditoría inmutable (DAT-01) |
| 13 | El alumno tiene los 6 avisos del curso | alumno | ms-notificaciones (ENG-01) · `GET /notifications/me` |

**Aislamiento:** al final, el docente, el alumno y el admin de cada tenant piden el curso, los módulos, el archivo, la tarea, el libro de notas y el historial de la nota del **otro** tenant. Todos deben responder 403 o 404.

## Qué hacer si falla

Cada paso imprime el HTTP y el cuerpo de la respuesta que falló, y los siguientes pasos de ese tenant se saltan porque dependen de él. Pistas:

- **Un efecto por eventos no llega** (por ejemplo "la nota no apareció en el libro de notas"): revisa la DLQ y la alarma del consumidor (`scripts/verificar_alarmas.sh <stage>`) y los logs de su Lambda en CloudWatch.
- **409 en "Curso creado":** ms-cursos no recibió `term.started`; revisa la regla `nubeduca-<stage>-cursos`.
- **Avisos que faltan:** el aviso puede quedar `FAILED` si SES no puede enviar el correo en el Learner Lab. El script solo exige que el aviso exista, no que el correo salga.
