"""
QA-01 · E2E del curso piloto: recorre el flujo completo de Nubeduca en un stage desplegado,
con 2 tenants a la vez, y comprueba que cada tenant solo ve lo suyo.

    python qa/piloto.py --stage staging                         # utec y upc, tokens mock
    python qa/piloto.py --stage staging --auth cognito          # login real con los usuarios demo
    python qa/piloto.py --stage staging --tenants utec,pucp --reporte qa-staging.json

Usa las credenciales de AWS del entorno (source scripts/cuenta.sh && cargar_cuenta) solo para leer
las URLs de las APIs en SSM (/nubeduca/<stage>/api/<ms>/url) y, con --auth cognito, el App Client
de infra/auth. Todo lo demás pasa por las APIs públicas, como el frontend.

El flujo de cada tenant (ver qa/README.md):
  admin abre y activa un periodo -> docente crea el curso, se matricula y matricula al alumno ->
  publica el curso y un anuncio -> sube un PDF, arma un módulo y lo publica -> crea y publica una tarea ->
  el alumno sube su entrega (y un EICAR que se rechaza) -> el docente califica -> publica la nota ->
  la ajusta a mano -> el historial de auditoría tiene los dos cambios -> el alumno tiene sus avisos.

Termina con código 0 solo si todos los pasos pasan en todos los tenants.
"""

import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import boto3

SERVICIOS = ("usuarios", "cursos", "contenidos", "evaluaciones", "calificaciones", "notificaciones")
DOMINIOS = {"utec": "utec.edu.pe", "upc": "upc.edu.pe", "pucp": "pucp.edu.pe"}
ESPERA_SEGUNDOS = 90  # lo que puede tardar un efecto que viaja por eventos
AVISOS = ("COURSE_PUBLISHED", "ANNOUNCEMENT", "MODULE", "ASSIGNMENT", "SUBMISSION_RECEIPT", "GRADE")

# Archivo de prueba EICAR, armado por partes para que el antivirus de la máquina no borre este script.
EICAR = b"".join([b"X5O!P%@AP[4\\PZX54(P^)7CC)7}$", b"EICAR-STANDARD-ANTIVIRUS", b"-TEST-FILE!$H+H*"])
PDF = b"%PDF-1.7\n% Nubeduca QA-01\n" + b"Laboratorio 4: SQS y DLQ\n" * 64


class Fallo(Exception):
    pass


# --- HTTP -------------------------------------------------------------------------------

def llamar(metodo, url, token=None, body=None, crudo=None, headers=None):
    cabeceras = dict(headers or {})
    if token:
        cabeceras["Authorization"] = f"Bearer {token}"
    datos = crudo
    if body is not None:
        datos = json.dumps(body).encode()
        cabeceras["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=datos, method=metodo, headers=cabeceras)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            contenido = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        contenido, status = e.read(), e.code
    if crudo is not None or metodo == "GET" and not contenido.startswith((b"{", b"[")):
        return status, contenido
    try:
        return status, json.loads(contenido or b"null")
    except ValueError:
        return status, contenido


def esperar(funcion, segundos=ESPERA_SEGUNDOS, cada=3):
    """Repite `funcion` hasta que devuelva algo verdadero (los efectos por eventos tardan)."""
    limite = time.monotonic() + segundos
    while True:
        valor = funcion()
        if valor or time.monotonic() > limite:
            return valor
        time.sleep(cada)


# --- Actores y tokens ---------------------------------------------------------------------

class Actor:
    def __init__(self, tenant, rol, user_id, token):
        self.tenant, self.rol, self.user_id, self.token = tenant, rol, user_id, token

    def __repr__(self):
        return f"{self.rol}@{self.tenant}"


def actor_mock(tenant, rol):
    user_id = str(uuid.uuid4())
    return Actor(tenant, rol, user_id, f"mock.{tenant}.{rol}.{user_id}")


def _client_id(stage):
    nombre = f"nubeduca-{stage}-user-pool-client-id"
    paginador = boto3.client("cloudformation").get_paginator("list_exports")
    for pagina in paginador.paginate():
        for export in pagina["Exports"]:
            if export["Name"] == nombre:
                return export["Value"]
    raise Fallo(f"No encuentro el export {nombre} (¿está desplegado infra/auth en {stage}?)")


def actor_cognito(stage, tenant, rol, password, cognito):
    correo = {"ADMIN": "admin", "TEACHER": "docente", "STUDENT": "alumno"}[rol]
    usuario = f"{correo}.demo@{DOMINIOS.get(tenant, tenant + '.edu.pe')}"
    resp = cognito.initiate_auth(ClientId=_client_id(stage), AuthFlow="USER_PASSWORD_AUTH",
                                 AuthParameters={"USERNAME": usuario, "PASSWORD": password})
    token = resp["AuthenticationResult"]["IdToken"]  # el access token no trae los atributos custom
    carga = token.split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(carga + "=" * (-len(carga) % 4)))
    if claims.get("custom:tenant_id") != tenant or claims.get("custom:role") != rol:
        raise Fallo(f"{usuario} tiene tenant={claims.get('custom:tenant_id')} rol={claims.get('custom:role')}")
    return Actor(tenant, rol, claims["sub"], token)


# --- Recorrido de un tenant ---------------------------------------------------------------

class Recorrido:
    def __init__(self, urls, tenant, actores, corrida):
        self.urls, self.tenant, self.corrida = urls, tenant, corrida
        self.admin, self.docente, self.alumno = actores["ADMIN"], actores["TEACHER"], actores["STUDENT"]
        self.pasos, self.datos = [], {}

    def api(self, ms, ruta):
        return self.urls[ms] + ruta

    def paso(self, nombre, funcion):
        inicio = time.monotonic()
        try:
            detalle = funcion()
            estado = "OK"
        except Fallo as exc:
            detalle, estado = str(exc), "FALLA"
        except Exception as exc:  # noqa: BLE001 - un error inesperado también es un paso fallido
            detalle, estado = f"{type(exc).__name__}: {exc}", "FALLA"
        segundos = round(time.monotonic() - inicio, 1)
        self.pasos.append({"tenant": self.tenant, "paso": nombre, "estado": estado, "segundos": segundos,
                           "detalle": detalle or ""})
        print(f"  [{self.tenant:4}] {'OK   ' if estado == 'OK' else 'FALLA'} {nombre} ({segundos}s)"
              + (f" — {detalle}" if detalle else ""), flush=True)
        if estado != "OK":
            raise Fallo(nombre)

    @staticmethod
    def esperado(status, cuerpo, *codigos):
        if status not in codigos:
            raise Fallo(f"HTTP {status}: {json.dumps(cuerpo, ensure_ascii=False)[:300]}")
        return cuerpo

    # Pasos ---------------------------------------------------------------------------------

    def provisionar(self):
        for actor in (self.admin, self.docente, self.alumno):
            s, b = llamar("POST", self.api("usuarios", "/users/me"), actor.token)
            self.esperado(s, b, 200, 201)
        return "admin, docente y alumno con perfil (user.provisioned)"

    def abrir_periodo(self):
        hoy = datetime.now(timezone.utc).date()
        s, b = llamar("POST", self.api("usuarios", "/terms"), self.admin.token,
                      {"name": f"QA {self.corrida}", "startsOn": hoy.isoformat(),
                       "endsOn": (hoy + timedelta(days=120)).isoformat()})
        periodo = self.esperado(s, b, 201)
        s, b = llamar("POST", self.api("usuarios", f"/terms/{periodo['termId']}/start"), self.admin.token)
        if self.esperado(s, b, 200)["status"] != "ACTIVE":
            raise Fallo(f"el periodo quedó en {b['status']}")
        self.datos["termId"] = periodo["termId"]
        return periodo["termId"]

    def crear_curso(self):
        cuerpo = {"termId": self.datos["termId"], "code": f"QA{self.corrida[-6:]}",
                  "title": "Cloud Computing (piloto QA-01)", "description": "Curso piloto de QA-01"}

        def intentar():  # ms-cursos conoce el periodo cuando le llega term.started
            s, b = llamar("POST", self.api("cursos", "/courses"), self.docente.token, cuerpo)
            return b if s == 201 else None

        curso = esperar(intentar)
        if not curso:
            raise Fallo("ms-cursos no aceptó el curso (¿llegó term.started?)")
        self.datos["courseId"] = curso["courseId"]
        return curso["courseId"]

    def matricular(self):
        cid = self.datos["courseId"]
        for actor, rol in ((self.docente, "TEACHER"), (self.alumno, "STUDENT")):
            s, b = llamar("POST", self.api("cursos", f"/courses/{cid}/enrollments"), self.docente.token,
                          {"userId": actor.user_id, "role": rol})
            self.esperado(s, b, 201)
        return "docente como TEACHER y alumno como STUDENT (enrollment.created)"

    def publicar_curso(self):
        cid = self.datos["courseId"]
        s, b = llamar("POST", self.api("cursos", f"/courses/{cid}/publish"), self.docente.token)
        self.esperado(s, b, 200)
        s, b = llamar("GET", self.api("cursos", "/courses"), self.alumno.token)
        ids_curso = [c["courseId"] for c in self.esperado(s, b, 200).get("items", [])]
        if cid not in ids_curso:
            raise Fallo("el alumno no ve el curso publicado en GET /courses")
        return "PUBLISHED y visible para el alumno"

    def anunciar(self):
        cid = self.datos["courseId"]
        s, b = llamar("POST", self.api("cursos", f"/courses/{cid}/announcements"), self.docente.token,
                      {"title": "Bienvenidos", "body": "El curso piloto empieza esta semana."})
        self.esperado(s, b, 201)
        return b["announcementId"]

    def _subir(self, actor, purpose, nombre, contenido, tipo):
        s, b = llamar("POST", self.api("contenidos", "/files"), actor.token,
                      {"courseId": self.datos["courseId"], "purpose": purpose, "fileName": nombre,
                       "contentType": tipo, "sizeBytes": len(contenido)})
        ticket = self.esperado(s, b, 201)
        s, _ = llamar("PUT", ticket["uploadUrl"], crudo=contenido, headers=ticket["headers"])
        if s != 200:
            raise Fallo(f"PUT a S3 respondió {s}")

        def estado():
            s, b = llamar("GET", self.api("contenidos", f"/files/{ticket['fileId']}"), actor.token)
            return b["status"] if s == 200 and b["status"] in ("CLEAN", "INFECTED") else None

        return ticket["fileId"], esperar(estado)

    def contenido(self):
        file_id, estado = self._subir(self.docente, "CONTENT", "lab4.pdf", PDF, "application/pdf")
        if estado != "CLEAN":
            raise Fallo(f"el PDF quedó en {estado}")
        cid = self.datos["courseId"]
        base = self.api("contenidos", f"/courses/{cid}/modules")
        s, b = llamar("POST", base, self.docente.token, {"title": "Semana 1: Serverless", "position": 1})
        mid = self.esperado(s, b, 201)["moduleId"]
        for item in ({"type": "PAGE", "title": "Introducción", "body": "# Lambda y API Gateway"},
                     {"type": "FILE", "title": "Laboratorio 4", "fileId": file_id}):
            s, b = llamar("POST", f"{base}/{mid}/items", self.docente.token, item)
            self.esperado(s, b, 201)
        s, b = llamar("POST", f"{base}/{mid}/publish", self.docente.token)
        self.esperado(s, b, 200)
        s, b = llamar("GET", base, self.alumno.token)
        if mid not in [m["moduleId"] for m in self.esperado(s, b, 200)["items"]]:
            raise Fallo("el alumno no ve el módulo publicado")
        s, b = llamar("GET", self.api("contenidos", f"/files/{file_id}/download"), self.alumno.token)
        s, bajado = llamar("GET", self.esperado(s, b, 200)["downloadUrl"])
        if s != 200 or bajado != PDF:
            raise Fallo("el alumno no pudo descargar el PDF del módulo")
        self.datos.update(moduleId=mid, contentFileId=file_id)
        return f"módulo {mid} con PDF CLEAN, publicado y descargado por el alumno"

    def tarea(self):
        cid = self.datos["courseId"]
        vence = (datetime.now(timezone.utc) + timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
        s, b = llamar("POST", self.api("evaluaciones", f"/courses/{cid}/assignments"), self.docente.token,
                      {"title": "Laboratorio 4: SQS y DLQ", "instructions": "Sube tu informe en PDF.",
                       "dueAt": vence, "maxScore": 20, "allowLate": False})
        aid = self.esperado(s, b, 201)["assignmentId"]
        s, b = llamar("POST", self.api("evaluaciones", f"/assignments/{aid}/publish"), self.docente.token)
        self.esperado(s, b, 200)
        self.datos["assignmentId"] = aid
        return aid

    def entrega(self):
        aid = self.datos["assignmentId"]
        ruta = self.api("evaluaciones", f"/assignments/{aid}/submissions")

        sucio, estado = self._subir(self.alumno, "SUBMISSION", "virus.pdf", EICAR, "application/pdf")
        if estado != "INFECTED":
            raise Fallo(f"el EICAR quedó en {estado}")
        # ms-evaluaciones conoce el resultado del antivirus por file.scanned: un INFECTED nunca se acepta.
        time.sleep(5)
        s, b = llamar("POST", ruta, self.alumno.token, {"fileIds": [sucio]})
        if s != 409:
            raise Fallo(f"la entrega con el EICAR respondió {s}, se esperaba 409")

        limpio, estado = self._subir(self.alumno, "SUBMISSION", "informe.pdf", PDF, "application/pdf")
        if estado != "CLEAN":
            raise Fallo(f"el informe quedó en {estado}")

        def entregar():  # 409 ARCHIVO_NO_VERIFICADO hasta que llegue file.scanned a ms-evaluaciones
            s, b = llamar("POST", ruta, self.alumno.token, {"fileIds": [limpio], "comment": "Informe del lab 4"})
            return b if s == 201 else None

        sub = esperar(entregar)
        if not sub:
            raise Fallo("ms-evaluaciones no aceptó la entrega con el archivo CLEAN")
        self.datos["submissionId"] = sub["submissionId"]
        return f"EICAR rechazado (409); entrega {sub['submissionId']} intento {sub['attempt']}"

    def calificar(self):
        sid = self.datos["submissionId"]
        s, b = llamar("POST", self.api("evaluaciones", f"/submissions/{sid}/grade"), self.docente.token,
                      {"score": 15, "feedback": "Bien, falta la DLQ."})
        self.esperado(s, b, 200)
        cid, aid = self.datos["courseId"], self.datos["assignmentId"]

        def en_libro():  # submission.graded -> ms-calificaciones crea la nota en DRAFT
            s, b = llamar("GET", self.api("calificaciones", f"/courses/{cid}/gradebook"), self.docente.token)
            if s != 200:
                return None
            columna = next((c for c in b["gradeItems"] if c.get("assignmentId") == aid), None)
            fila = next((f for f in b["rows"] if f["studentId"] == self.alumno.user_id), None)
            nota = next((g for g in (fila or {}).get("grades", []) if columna
                         and g["gradeItemId"] == columna["gradeItemId"]), None)
            return (columna, nota) if nota else None

        encontrado = esperar(en_libro)
        if not encontrado:
            raise Fallo("la nota no apareció en el libro de notas")
        columna, nota = encontrado
        if nota["status"] != "DRAFT" or nota["score"] != 15:
            raise Fallo(f"nota inesperada: {nota}")
        s, b = llamar("GET", self.api("calificaciones", f"/courses/{cid}/grades/me"), self.alumno.token)
        if self.esperado(s, b, 200)["items"]:
            raise Fallo("el alumno ve una nota que todavía no se publicó")
        self.datos.update(gradeItemId=columna["gradeItemId"], gradeId=nota["gradeId"])
        return f"nota {nota['gradeId']} 15/20 en DRAFT; el alumno todavía no la ve"

    def _nota_del_alumno(self, puntaje):
        cid = self.datos["courseId"]

        def ver():
            s, b = llamar("GET", self.api("calificaciones", f"/courses/{cid}/grades/me"), self.alumno.token)
            notas = b.get("items", []) if s == 200 else []
            return next((g for g in notas if g["gradeId"] == self.datos["gradeId"] and g["score"] == puntaje
                         and g["status"] == "POSTED"), None)

        return esperar(ver)

    def publicar_nota(self):
        gri = self.datos["gradeItemId"]
        s, b = llamar("POST", self.api("calificaciones", f"/grade-items/{gri}/post"), self.docente.token)
        if self.esperado(s, b, 200)["posted"] < 1:
            raise Fallo(f"no se publicó ninguna nota: {b}")
        if not self._nota_del_alumno(15):
            raise Fallo("el alumno no ve su nota publicada")
        return "POSTED; el alumno ve 15/20"

    def ajustar_y_auditar(self):
        gid = self.datos["gradeId"]
        s, b = llamar("PATCH", self.api("calificaciones", f"/grades/{gid}"), self.docente.token,
                      {"score": 17, "reason": "Revisión: la DLQ sí estaba configurada"})
        self.esperado(s, b, 200)
        if not self._nota_del_alumno(17):
            raise Fallo("el alumno no ve la nota ajustada")

        def historial():  # DAT-01: cada grade.changed queda en la auditoría
            s, b = llamar("GET", self.api("calificaciones", f"/grades/{gid}/history"), self.docente.token)
            items = b.get("items", []) if s == 200 else []
            return items if len(items) >= 2 else None

        items = esperar(historial)
        if not items:
            raise Fallo("el historial no tiene los dos cambios")
        cambios = [(i["cause"], i["score"]) for i in items]
        if cambios != [("GRADED", 15), ("MANUAL_OVERRIDE", 17)]:
            raise Fallo(f"historial inesperado: {cambios}")
        return "15 -> 17 (MANUAL_OVERRIDE); historial GRADED y MANUAL_OVERRIDE"

    def avisos(self):
        cid = self.datos["courseId"]

        def tipos():
            s, b = llamar("GET", self.api("notificaciones", "/notifications/me"), self.alumno.token)
            vistos = {n["type"] for n in (b.get("items", []) if s == 200 else []) if n.get("courseId") == cid}
            return vistos if vistos >= set(AVISOS) else None

        vistos = esperar(tipos)
        if not vistos:
            s, b = llamar("GET", self.api("notificaciones", "/notifications/me"), self.alumno.token)
            vistos = {n["type"] for n in b.get("items", []) if n.get("courseId") == cid} if s == 200 else set()
            raise Fallo(f"faltan avisos: {sorted(set(AVISOS) - vistos)}")
        return ", ".join(AVISOS)

    def correr(self):
        try:
            self.paso("Perfiles (POST /users/me)", self.provisionar)
            self.paso("Periodo abierto y activo", self.abrir_periodo)
            self.paso("Curso creado por el docente", self.crear_curso)
            self.paso("Matrículas", self.matricular)
            self.paso("Curso publicado", self.publicar_curso)
            self.paso("Anuncio", self.anunciar)
            self.paso("Módulo con archivo (CON-01/02)", self.contenido)
            self.paso("Tarea publicada (EVA-01)", self.tarea)
            self.paso("Entrega del alumno + EICAR rechazado", self.entrega)
            self.paso("Calificación en el libro de notas (EVA-02)", self.calificar)
            self.paso("Nota publicada al alumno", self.publicar_nota)
            self.paso("Ajuste manual + auditoría (DAT-01)", self.ajustar_y_auditar)
            self.paso("Avisos del alumno (ENG-01)", self.avisos)
        except Fallo:
            pass  # el paso ya quedó registrado; los siguientes dependen de él
        return self.pasos


# --- Aislamiento entre tenants ------------------------------------------------------------

def aislamiento(urls, recorridos):
    """El docente y el alumno de un tenant no ven nada del otro (el tenant sale del token)."""
    pasos = []
    for a, b in ((recorridos[0], recorridos[1]), (recorridos[1], recorridos[0])):
        datos = a.datos
        if not {"courseId", "moduleId", "contentFileId", "assignmentId", "gradeId"} <= set(datos):
            pasos.append({"tenant": f"{b.tenant}->{a.tenant}", "paso": "Aislamiento", "estado": "OMITIDO",
                          "segundos": 0, "detalle": f"el recorrido de {a.tenant} no llegó al final"})
            continue
        pruebas = [
            ("curso", "cursos", f"/courses/{datos['courseId']}", b.docente),
            ("módulos", "contenidos", f"/courses/{datos['courseId']}/modules", b.alumno),
            ("archivo", "contenidos", f"/files/{datos['contentFileId']}", b.alumno),
            ("tarea", "evaluaciones", f"/assignments/{datos['assignmentId']}", b.alumno),
            ("libro de notas", "calificaciones", f"/courses/{datos['courseId']}/gradebook", b.docente),
            ("historial de la nota", "calificaciones", f"/grades/{datos['gradeId']}/history", b.admin),
        ]
        for nombre, ms, ruta, actor in pruebas:
            s, cuerpo = llamar("GET", urls[ms] + ruta, actor.token)
            bien = s in (403, 404)
            pasos.append({"tenant": f"{b.tenant}->{a.tenant}", "paso": f"Aislamiento: {nombre}",
                          "estado": "OK" if bien else "FALLA", "segundos": 0,
                          "detalle": f"{actor!r} GET {ruta} -> {s}"})
            print(f"  [{b.tenant}->{a.tenant}] {'OK   ' if bien else 'FALLA'} {nombre}: {actor!r} -> {s}", flush=True)
    return pasos


# --- Principal ------------------------------------------------------------------------------

def urls_de(stage):
    ssm = boto3.client("ssm")
    urls = {}
    for ms in SERVICIOS:
        try:
            valor = ssm.get_parameter(Name=f"/nubeduca/{stage}/api/{ms}/url")["Parameter"]["Value"]
        except ssm.exceptions.ParameterNotFound:
            raise Fallo(f"falta /nubeduca/{stage}/api/{ms}/url: ¿está desplegado ms-{ms} en {stage}?") from None
        urls[ms] = valor.rstrip("/")
    return urls


def salud(urls):
    for ms, url in urls.items():
        s, b = llamar("GET", url + "/health")
        if s != 200:
            raise Fallo(f"ms-{ms} /health respondió {s}")
        print(f"  OK    ms-{ms:15} {url}")


def main():
    parser = argparse.ArgumentParser(description="QA-01: E2E del curso piloto con 2 tenants")
    parser.add_argument("--stage", default="staging")
    parser.add_argument("--tenants", default="utec,upc", help="dos tenants separados por coma")
    parser.add_argument("--auth", choices=("mock", "cognito"), default="mock")
    parser.add_argument("--password", help="contraseña de los usuarios demo (o NUBEDUCA_DEMO_PASSWORD)")
    parser.add_argument("--reporte", help="guarda el resultado en este archivo JSON (evidencia)")
    args = parser.parse_args()
    tenants = [x.strip() for x in args.tenants.split(",") if x.strip()]
    if len(tenants) != 2:
        raise SystemExit("--tenants necesita exactamente 2 tenants, por ejemplo utec,upc")

    corrida = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    print(f"QA-01 · stage {args.stage} · tenants {', '.join(tenants)} · auth {args.auth} · corrida {corrida}")
    print("Salud de los 6 microservicios:")
    urls = urls_de(args.stage)
    salud(urls)

    actores = {}
    if args.auth == "cognito":
        import os
        password = args.password or os.environ.get("NUBEDUCA_DEMO_PASSWORD")
        if not password:
            raise SystemExit("Con --auth cognito pasa --password o define NUBEDUCA_DEMO_PASSWORD.")
        cognito = boto3.client("cognito-idp")
        for tenant in tenants:
            actores[tenant] = {rol: actor_cognito(args.stage, tenant, rol, password, cognito)
                               for rol in ("ADMIN", "TEACHER", "STUDENT")}
    else:
        actores = {tenant: {rol: actor_mock(tenant, rol) for rol in ("ADMIN", "TEACHER", "STUDENT")}
                   for tenant in tenants}

    print("Flujo del curso piloto (los dos tenants a la vez):")
    recorridos = [Recorrido(urls, tenant, actores[tenant], corrida) for tenant in tenants]
    with ThreadPoolExecutor(max_workers=2) as pool:
        resultados = list(pool.map(lambda r: r.correr(), recorridos))
    print("Aislamiento entre tenants:")
    pasos = [p for lista in resultados for p in lista] + aislamiento(urls, recorridos)

    fallas = [p for p in pasos if p["estado"] != "OK"]
    total = sum(1 for p in pasos)
    print(f"\nRESULTADO: {total - len(fallas)}/{total} pasos OK" + ("" if not fallas else " — HAY FALLAS"))
    if args.reporte:
        with open(args.reporte, "w", encoding="utf-8") as f:
            json.dump({"stage": args.stage, "tenants": tenants, "auth": args.auth, "corrida": corrida,
                       "urls": urls, "datos": {r.tenant: r.datos for r in recorridos}, "pasos": pasos},
                      f, ensure_ascii=False, indent=2)
        print(f"Reporte: {args.reporte}")
    sys.exit(1 if fallas else 0)


if __name__ == "__main__":
    try:
        main()
    except Fallo as exc:
        print(f"\nNO SE PUDO CORRER QA-01: {exc}")
        sys.exit(2)
