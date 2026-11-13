# Cómo trabajamos

- `main` está protegida: nadie hace push directo. Todo entra por Pull Request.
- Ramas: `<tipo>/<ID>-descripcion-corta`. Tipos: `feat`, `fix`, `docs`, `chore`.
  Ejemplo: `feat/ACA-03-crear-curso`.
- Commits: `<ID>: mensaje`. Ejemplo: `PLT-04: bus lms y plantilla de consumidor`.
- PR hacia `main` con el ID en el título y `Closes nubeduca/nubeduca-backlog#<n>` en la descripción.
- Para mergear: 1 aprobación y CI en verde. Se hace squash merge.
- Un PR que rompe un esquema de evento no se puede mergear (ver `nubeduca-contratos`).