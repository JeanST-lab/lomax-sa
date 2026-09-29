import json

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, ConnectTimeoutError, EndpointConnectionError

from . import config
from .errores import ErrorPaso

_CFG = Config(connect_timeout=5, read_timeout=15, retries={"max_attempts": 2},
              s3={"addressing_style": "path"})
_CFG_LAMBDA = Config(connect_timeout=5, read_timeout=65, retries={"max_attempts": 1})

_s3 = boto3.client("s3", endpoint_url=config.AWS_ENDPOINT, region_name=config.REGION, config=_CFG)
_dynamo = boto3.resource("dynamodb", endpoint_url=config.AWS_ENDPOINT,
                         region_name=config.REGION, config=_CFG)
_lambda = boto3.client("lambda", endpoint_url=config.AWS_ENDPOINT,
                       region_name=config.REGION, config=_CFG_LAMBDA)

_NO_EXISTE = ("404", "NoSuchKey", "NotFound")


def _error(paso, e, producto_id=None, estado=None):
    if isinstance(e, ErrorPaso):
        return e
    sin_conexion = isinstance(e, (EndpointConnectionError, ConnectTimeoutError))
    return ErrorPaso(503 if sin_conexion else 502, paso, str(e), producto_id, estado)


# ---------- S3 originales ----------
def buscar_originales(producto_id, estado=None):
    try:
        r = _s3.list_objects_v2(Bucket=config.ORIGINALES_BUCKET,
                                Prefix=f"originales/{producto_id}/")
        return sorted(o["Key"] for o in r.get("Contents", []))
    except Exception as e:
        raise _error("s3_original", e, producto_id, estado)


def guardar_original(producto_id, ext, tipo, datos, estado=None):
    """Clave determinista por producto: originales/{id}/original.{ext}."""
    key = f"originales/{producto_id}/original.{ext}"
    try:
        _s3.put_object(Bucket=config.ORIGINALES_BUCKET, Key=key, Body=datos, ContentType=tipo)
        for otra in buscar_originales(producto_id, estado):
            if otra != key:  # si cambia jpg<->png no queda un original huerfano
                _s3.delete_object(Bucket=config.ORIGINALES_BUCKET, Key=otra)
    except Exception as e:
        raise _error("s3_original", e, producto_id, estado)
    return key


# ---------- Lambda ----------
def invocar_lambda(producto_id, key, estado=None):
    evento = {"producto_id": producto_id, "bucket": config.ORIGINALES_BUCKET, "key": key}
    try:
        r = _lambda.invoke(FunctionName=config.LAMBDA_NAME, InvocationType="RequestResponse",
                           Payload=json.dumps(evento).encode())
        crudo = r["Payload"].read()
    except Exception as e:
        raise _error("lambda", e, producto_id, estado)
    try:
        payload = json.loads(crudo or b"{}")
    except ValueError:
        payload = {"error": crudo[:200].decode(errors="replace")}
    if not isinstance(payload, dict):
        payload = {"error": str(payload)}
    if r.get("FunctionError"):
        detalle = payload.get("errorMessage") or payload
        raise ErrorPaso(502, "lambda", f"Error de ejecucion: {detalle}", producto_id, estado)
    return payload


# ---------- S3 miniaturas ----------
def verificar_miniatura(producto_id, key, estado=None):
    try:
        _s3.head_object(Bucket=config.MINIATURAS_BUCKET, Key=key)
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") in _NO_EXISTE:
            raise ErrorPaso(502, "s3_miniatura",
                            f"La Lambda reporto exito pero no existe {key}", producto_id, estado)
        raise _error("s3_miniatura", e, producto_id, estado)
    except Exception as e:
        raise _error("s3_miniatura", e, producto_id, estado)


def leer_miniatura(key):
    try:
        o = _s3.get_object(Bucket=config.MINIATURAS_BUCKET, Key=key)
        return o["Body"].read(), o.get("ContentType") or "image/jpeg"
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") in _NO_EXISTE:
            return None
        raise _error("s3_miniatura", e)
    except Exception as e:
        raise _error("s3_miniatura", e)


# ---------- DynamoDB ----------
def crear_item(producto_id, atributos):
    try:
        _dynamo.Table(config.DYNAMO_TABLE).put_item(Item={
            "producto_id": producto_id,
            "atributos_json": json.dumps(atributos, ensure_ascii=False),
            "estado_procesamiento": "PENDIENTE",
        })
    except Exception as e:
        raise _error("dynamodb", e, producto_id, "PENDIENTE")


def obtener_item(producto_id, estado=None):
    try:
        r = _dynamo.Table(config.DYNAMO_TABLE).get_item(
            Key={"producto_id": producto_id}, ConsistentRead=True)
        return r.get("Item") or {}
    except Exception as e:
        raise _error("dynamodb", e, producto_id, estado)
