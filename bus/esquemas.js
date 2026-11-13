// Genera un recurso AWS::EventSchemas::Schema por cada esquema de nubeduca-contratos.
// Por defecto busca el repo al lado de nubeduca-infra; o usa CONTRATOS_DIR (raíz del repo).
const fs = require('fs');
const path = require('path');

module.exports.generar = () => {
  const raiz = process.env.CONTRATOS_DIR
    ? path.resolve(process.env.CONTRATOS_DIR)
    : path.resolve(__dirname, '..', '..', 'nubeduca-contratos');
  const dir = path.join(raiz, 'eventos', 'esquemas');

  if (!fs.existsSync(dir)) {
    throw new Error(
      `No encuentro los esquemas en ${dir}. Clona nubeduca-contratos al lado de ` +
      `nubeduca-infra o define CONTRATOS_DIR.`
    );
  }

  const Resources = {};
  fs.readdirSync(dir)
    .filter((f) => f.endsWith('.json') && !f.startsWith('_'))
    .sort()
    .forEach((f) => {
      const nombre = f.replace(/\.json$/, '');
      const esquema = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
      const id = 'Esquema' + nombre.replace(/[^A-Za-z0-9]/g, '');
      Resources[id] = {
        Type: 'AWS::EventSchemas::Schema',
        Condition: 'CrearEsquemas',
        Properties: {
          RegistryName: { 'Fn::GetAtt': ['RegistroEsquemas', 'RegistryName'] },
          SchemaName: nombre,
          Type: 'JSONSchemaDraft4',
          Description: String(esquema.description || nombre).slice(0, 250),
          Content: JSON.stringify(esquema),
        },
      };
    });

  return { Resources };
};