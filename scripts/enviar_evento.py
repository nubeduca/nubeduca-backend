import sys
import json
import boto3


def main():
    if len(sys.argv) < 2:
        print('Uso: python enviar_evento.py <ruta-ejemplo.json> [stage]')
        sys.exit(1)

    ruta = sys.argv[1]
    stage = sys.argv[2] if len(sys.argv) > 2 else 'dev'

    with open(ruta, encoding='utf-8') as f:
        evento = json.load(f)

    cliente = boto3.client('events', region_name='us-east-1')
    respuesta = cliente.put_events(Entries=[{
        'EventBusName': f'lms-{stage}',
        'Source': evento['source'],
        'DetailType': evento['detail-type'],
        'Detail': json.dumps(evento['detail']),
    }])
    print(json.dumps(respuesta, indent=2, default=str))
    if respuesta['FailedEntryCount']:
        sys.exit(1)


if __name__ == '__main__':
    main()