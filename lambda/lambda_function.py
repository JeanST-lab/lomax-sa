import io
import json
import os
import boto3
from PIL import Image, ImageOps

ENDPOINT = os.environ.get("AWS_ENDPOINT_URL")
s3 = boto3.client("s3", endpoint_url=ENDPOINT)
dynamodb = boto3.resource("dynamodb", endpoint_url=ENDPOINT)

TABLE_NAME = os.environ.get("TABLE_NAME", "lomax-productos-attr")
MINIATURAS_BUCKET = os.environ.get("MINIATURAS_BUCKET", "lomax-imagenes-miniaturas")
MAX_BYTES = 5 * 1024 * 1024
MAX_DIM = (300, 300)


def guardar_estado(producto_id, estado, **extra):
    sets = ["estado_procesamiento = :e"]
    values = {":e": estado}
    for i, (k, v) in enumerate(extra.items()):
        sets.append(f"{k} = :v{i}")
        values[f":v{i}"] = v
    dynamodb.Table(TABLE_NAME).update_item(
        Key={"producto_id": producto_id},
        UpdateExpression="SET " + ", ".join(sets),
        ExpressionAttributeValues=values,
    )


def lambda_handler(event, context):
    producto_id = event.get("producto_id")
    bucket = event.get("bucket")
    key = event.get("key") or event.get("clave")

    try:
        if not (producto_id and bucket and key):
            raise ValueError("Evento incompleto: se requiere producto_id, bucket y key")

        # Tamaño antes de descargar
        head = s3.head_object(Bucket=bucket, Key=key)
        if head["ContentLength"] > MAX_BYTES:
            raise ValueError("El archivo excede el límite de 5 MB")

        data = s3.get_object(Bucket=bucket, Key=key)["Body"].read()

        # Validar que sea un JPEG/PNG real
        img = Image.open(io.BytesIO(data))
        if img.format not in ("JPEG", "PNG"):
            raise ValueError(f"Formato no soportado: {img.format}")
        img.verify()
        img = Image.open(io.BytesIO(data))  # verify() invalida el objeto
        img.load()

        # Miniatura proporcional máx. 300x300
        img = ImageOps.exif_transpose(img)
        if img.mode != "RGB":
            img = img.convert("RGB")
        img.thumbnail(MAX_DIM, Image.LANCZOS)

        # Clave determinista: misma imagen -> misma clave
        base = os.path.splitext(os.path.basename(key))[0]
        output_key = f"miniaturas/{producto_id}/{base}_300.jpg"

        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=85)
        buf.seek(0)
        s3.put_object(Bucket=MINIATURAS_BUCKET, Key=output_key,
                      Body=buf, ContentType="image/jpeg")

        guardar_estado(
            producto_id, "PROCESADO",
            miniatura_bucket=MINIATURAS_BUCKET,
            miniatura_key=output_key,
            miniatura_url=f"s3://{MINIATURAS_BUCKET}/{output_key}",
            original_key=key,
            error_detalle="",
        )
        return {
            "statusCode": 200,
            "estado": "PROCESADO",
            "producto_id": producto_id,
            "miniatura_key": output_key,
            "dimensiones": list(img.size),
        }

    except Exception as e:
        print(f"Error procesando imagen: {e}")
        if producto_id:
            try:
                guardar_estado(producto_id, "ERROR", error_detalle=str(e)[:300])
            except Exception as e2:
                print(f"No se pudo guardar el estado ERROR: {e2}")
        return {
            "statusCode": 400,
            "estado": "ERROR",
            "producto_id": producto_id,
            "error": str(e),
        }