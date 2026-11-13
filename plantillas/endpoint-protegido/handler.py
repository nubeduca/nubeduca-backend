import json


def lambda_handler(event, context):
    # tenant y rol salen del token validado por API Gateway, nunca del body
    claims = event['requestContext']['authorizer']['claims']
    cuerpo = {
        'tenant_id': claims.get('custom:tenant_id'),
        'rol': claims.get('custom:role'),
        'user_id': claims.get('sub'),
        'email': claims.get('email'),
    }
    return {
        'statusCode': 200,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
        },
        'body': json.dumps(cuerpo),
    }