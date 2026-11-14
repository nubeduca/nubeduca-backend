# Endpoint protegido con Cognito

Copia el bloque `authorizer` de `serverless.yml` en cada endpoint protegido.

```yaml
authorizer:
  name: cognito
  type: COGNITO_USER_POOLS
  arn:
    Fn::ImportValue: nubeduca-${sls:stage}-user-pool-arn
```

En la Lambda, el tenant y el rol salen del token (nunca del body):

```python
claims = event['requestContext']['authorizer']['claims']
tenant_id = claims['custom:tenant_id']
rol = claims['custom:role']
```

- El header `Authorization` lleva el **ID token solo, sin `Bearer`**.
- Sin token o con token inválido: 401.
- Despliega `infra/auth` antes que cualquier servicio, porque el ARN se importa.
- Valores: tenants `utec`, `upc`, `pucp`; roles `STUDENT`, `TEACHER`, `ADMIN`.
- Esta plantilla usa integración proxy (el valor por defecto de Serverless).