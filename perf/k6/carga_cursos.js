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
//   ROL          mixto (por defecto: 80 % STUDENT, 20 % TEACHER) | STUDENT | TEACHER
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
const ROL = __ENV.ROL || 'mixto';

// Rampas de usuarios virtuales. Ajustar a la sección 13 del documento de arquitectura.
const PERFILES = {
  corto: [
    { duration: '30s', target: 10 },
    { duration: '1m', target: 10 },
    { duration: '15s', target: 0 },
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
const USUARIOS_MOCK = {
  TEACHER: 'c62d9930-b473-4b1d-adec-72fdda7cf599',
  STUDENT: '5b1f2c3d-8e4a-4f6b-9c7d-2a1e3f4b5c6d',
};

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
  return `mock.${tenant}.${rol}.${USUARIOS_MOCK[rol]}`;
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
