// PERF-01 · Prueba de carga de ms-cursos con k6.
//
// Uso (desde la raíz de nubeduca-backend):
//   mkdir -p perf/reportes
//   k6 run -e BASE_URL=<url del API de ms-cursos> perf/k6/carga_cursos.js
//   k6 run -e BASE_URL=... -e AUTH_MODE=cognito -e TOKENS_FILE=$PWD/perf/tokens/tokens.json perf/k6/carga_cursos.js
//
// Variables (-e NOMBRE=valor):
//   BASE_URL     obligatoria. Ej.: aws ssm get-parameter --name /nubeduca/dev/api/cursos/url
//   AUTH_MODE    mock (por defecto) | cognito. Debe coincidir con el authMode del servicio.
//   TOKENS_FILE  solo con cognito: ruta ABSOLUTA del JSON que genera perf/tokens/generar_tokens.sh
//   PERFIL       corto (por defecto, ~2 min contra dev) | estres (PERF-02, contra staging)
//   ROL          TEACHER (por defecto, docentes del seed) | STUDENT | mixto (80 % STUDENT, 20 % TEACHER)
//   REPORTE_DIR  carpeta del resumen JSON (por defecto perf/reportes)
//
// Reporte HTML: agrega K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT=perf/reportes/reporte.html

import http from 'k6/http';
import { check, sleep } from 'k6';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.2/index.js';

const BASE_URL = (__ENV.BASE_URL || '').replace(/\/$/, '');
if (!BASE_URL) {
  throw new Error('Falta -e BASE_URL=<url del API de ms-cursos>');
}
const AUTH_MODE = __ENV.AUTH_MODE || 'mock';
const PERFIL = __ENV.PERFIL || 'corto';
const ROL = __ENV.ROL || 'TEACHER';

// Rampas de usuarios virtuales. Ajustar a la sección 13 del documento de arquitectura.
// corto: ~5 usuarios durante ~1,5 min ≈ 700 peticiones (centavos en el Learner Lab).
const PERFILES = {
  corto: [
    { duration: '20s', target: 5 },
    { duration: '1m', target: 5 },
    { duration: '10s', target: 0 },
  ],
  estres: [
    { duration: '2m', target: 50 },
    { duration: '5m', target: 50 },
    { duration: '2m', target: 100 },
    { duration: '3m', target: 100 },
    { duration: '1m', target: 0 },
  ],
};
if (!PERFILES[PERFIL]) {
  throw new Error(`PERFIL desconocido: ${PERFIL} (usa corto o estres)`);
}
// Seguro: el perfil estres consume más presupuesto del Learner Lab. Solo corre con -e CONFIRMAR=si.
if (PERFIL === 'estres' && __ENV.CONFIRMAR !== 'si') {
  throw new Error('PERFIL=estres gasta presupuesto del Learner Lab: agrega -e CONFIRMAR=si si de verdad quieres correrlo');
}

export const options = {
  scenarios: {
    lectura_catalogo: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: PERFILES[PERFIL],
      gracefulRampDown: '10s',
    },
  },
  // Metas provisionales: cambiarlas si la sección 13 define otras.
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{endpoint:listar}': ['p(95)<1000'],
    'http_req_duration{endpoint:detalle}': ['p(95)<1000'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

// Reparto de tenants igual que los datos de prueba: UTEC 15.000, UPC 10.000, PUCP 5.000.
const PESOS = { utec: 15, upc: 10, pucp: 5 };

// authMode=mock: token "mock.<tenant>.<ROL>.<userId>" (lo entiende lib/auth.py).
// GET /courses solo devuelve los cursos del docente (ownerId). Estos son los 20 docentes por tenant
// del seed de ms-cursos: uuid5(6f1c2e8a-3b7d-4c5e-9a10-5eed00000000, "<tenant>-docente-<n>"), n = 0..19.
const DOCENTES_SEED = {
  utec: ['3651db88-79cd-5df8-bd8c-488941b6e878', '9eb06802-c0aa-5fa5-a900-867a1996b372', 'ba3a1492-58e3-5e7a-9f85-2b1ec41e6677', 'ff05a31e-e5ba-57bc-88c6-3a36b11ca534', 'af6e8234-82e5-58bb-a266-bb9d8a50d514', 'b06892f3-d14b-5123-b99b-8fd65b972174', '7d7d15f1-217f-5ead-8cd1-41e5b0f97ab5', '7517a623-44ac-54a5-8695-0a9ac424b753', '30646123-e5b9-56ff-a061-cd928d991dc1', 'e81bf03a-9dd7-5457-bba5-26d8b6c26ae0', '9da6a930-2cc5-5a1a-a5ee-745bf904e7e6', '7273eef1-20a5-538f-bc54-8174ccb62bdf', '9325e207-d85b-5b84-9d26-5d52be8c888c', 'd05924b8-8c69-5401-8e97-89a59608ee9a', 'e551a387-ba83-5fd7-a5cb-a1e7391e1edc', 'd9ca7646-e6f9-5d73-baa9-d1e678f7c467', '37685d33-4010-5dfb-9fc3-37edcd00a72a', '6b19d8d5-c19d-5b30-b009-7d65b3039d92', '42b5ff98-7b9f-5050-a5d0-86abf51bb0bb', 'ecd77b0a-371e-5ac4-9631-c1fbdc74b6c1'],
  upc: ['e8a6d096-9a3b-51d7-ad95-46f6af2383b5', '1c17e6d9-3fea-5713-926b-5ac922447332', '58d6d5b3-3d80-5c95-9ad3-faa007966373', 'de730417-de87-50ff-bc2b-42d4c16860fa', '51ec75b6-d15c-51ab-97a9-4da3b87d5f26', '5f858e20-5100-5dd8-97d7-cfdeb2af1b24', 'b7899cc1-984e-591a-8329-95311e58bf17', 'c7039fac-9a99-5c94-be99-8d58b0969f5a', '8bc02d26-aec2-5825-84c2-8e8ad2399153', 'a07e51a3-ab7e-5022-8512-b3c54a2f8753', 'd27b9ac6-5276-50f4-820f-193907d9d019', '2f366727-d476-55c0-ad9a-671ae9536d51', 'd3a56336-13ae-57c5-87d0-699041b13b7c', '5364823b-3c52-584a-a3a1-48474af4283f', 'e4e2c21f-f28d-50f7-989e-426bcecaa877', '16d238cf-1290-5d43-b643-330463b82cef', 'd5fcb6ec-010f-549c-b83b-90f25f547dbe', '9eff4bc1-b385-5be8-b7fb-6e418c5a0ee0', 'edf13bbb-889f-5803-8baf-e2232446982b', 'fc89bcbf-f728-54f6-951e-746dfc43fc24'],
  pucp: ['832116c6-f86e-5837-811f-39fac97ce9b3', '5fc3236d-4530-5d25-b1a4-c3fb4ec62160', '61e2fabc-7cac-5148-97f0-593927987322', 'da86144f-f7c2-56ae-8013-f897b1d7b631', '137852b4-c023-5ebd-ba18-a6819d93326c', 'e35bd6d6-ee05-5257-a300-f94586e6d860', '6aec791a-f668-590f-be52-9f6bf79a8451', '1c15f802-bb15-5308-8242-9dd0785982ed', '2c9c791d-cbe4-5b77-9c7e-7d9cf49aff77', 'dbb15ab1-9cd8-526b-b02f-897c82c09e97', 'b0861566-4338-5d4c-be11-32ddc0f52338', '160d4460-dcbe-5251-a43b-50eef5675cda', '55eab097-0d56-5f77-803e-8e789e454fff', '16c8079e-9545-5aea-ac58-b96dd76088d6', 'c37932f2-36b5-541b-afdc-ad9c1082d981', '52b1b2bf-bdf0-5849-86bb-a7344e321189', '5eb48463-2852-50d0-861e-0000c17e710a', '2c368e1b-5aac-5de1-8a27-2ea03c3c5ca8', 'cd871434-295a-5133-9334-c5992636db70', '83d59e2c-6471-553f-9920-2131226b0fdd'],
};
// El seed no crea matrículas: un alumno ve la lista vacía (sirve como carga, pero no abre detalles).
const ALUMNO_MOCK = '5b1f2c3d-8e4a-4f6b-9c7d-2a1e3f4b5c6d';

// authMode=cognito: { "utec": { "TEACHER": "<idToken>", "STUDENT": "<idToken>" }, ... }
const TOKENS = AUTH_MODE === 'cognito' ? JSON.parse(open(__ENV.TOKENS_FILE)) : null;

const TENANTS = Object.keys(PESOS).filter((t) => !TOKENS || TOKENS[t]);
const PESO_TOTAL = TENANTS.reduce((s, t) => s + PESOS[t], 0);

function elegirTenant() {
  let r = Math.random() * PESO_TOTAL;
  for (const t of TENANTS) {
    r -= PESOS[t];
    if (r < 0) return t;
  }
  return TENANTS[0];
}

function elegirRol() {
  if (ROL !== 'mixto') return ROL;
  return Math.random() < 0.8 ? 'STUDENT' : 'TEACHER';
}

function token(tenant, rol) {
  if (TOKENS) return TOKENS[tenant][rol];
  const docentes = DOCENTES_SEED[tenant];
  const userId = rol === 'TEACHER' ? docentes[Math.floor(Math.random() * docentes.length)] : ALUMNO_MOCK;
  return `mock.${tenant}.${rol}.${userId}`;
}

// Acepta la lista como arreglo o dentro de items / courses / data.
function idsDeCursos(respuesta) {
  let cuerpo;
  try {
    cuerpo = respuesta.json();
  } catch (e) {
    return [];
  }
  const lista = Array.isArray(cuerpo) ? cuerpo : cuerpo.items || cuerpo.courses || cuerpo.data || [];
  return lista.map((c) => c.courseId || c.id).filter(Boolean).slice(0, 50);
}

export function setup() {
  const r = http.get(`${BASE_URL}/health`, { tags: { endpoint: 'health' } });
  if (r.status !== 200) {
    throw new Error(`/health respondió ${r.status}: revisa BASE_URL`);
  }
  console.log(`ms-cursos OK · perfil=${PERFIL} · auth=${AUTH_MODE} · tenants=${TENANTS.join(',')}`);
}

export default function () {
  const tenant = elegirTenant();
  const rol = elegirRol();
  const params = {
    headers: { Authorization: `Bearer ${token(tenant, rol)}` },
    tags: { tenant, rol },
  };

  const lista = http.get(`${BASE_URL}/courses`, {
    ...params,
    tags: { ...params.tags, endpoint: 'listar' },
  });
  check(lista, { 'GET /courses 200': (r) => r.status === 200 });

  const ids = idsDeCursos(lista);
  if (ids.length > 0) {
    const id = ids[Math.floor(Math.random() * ids.length)];
    const detalle = http.get(`${BASE_URL}/courses/${id}`, {
      ...params,
      tags: { ...params.tags, endpoint: 'detalle' },
    });
    check(detalle, { 'GET /courses/{id} 200': (r) => r.status === 200 });
  }

  sleep(1);
}

export function handleSummary(data) {
  const sello = new Date().toISOString().replace(/[:.]/g, '-');
  const dir = __ENV.REPORTE_DIR || 'perf/reportes';
  return {
    stdout: textSummary(data, { indent: ' ', enableColors: true }),
    [`${dir}/resumen-${PERFIL}-${sello}.json`]: JSON.stringify(data, null, 2),
  };
}
