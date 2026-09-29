import json
import uuid

from . import aws, config, db
from .errores import ErrorPaso


def crear_producto(p):
    if not db.categoria_existe(p.categoria_id):
        raise ErrorPaso(400, "validacion", "categoria_id no existe")
    producto_id = str(uuid.uuid4())
    try:
        db.insertar_producto(producto_id, p)
    except db.CodigoDuplicado:
        raise ErrorPaso(409, "rds", f"El codigo '{p.codigo}' ya existe")
    aws.crear_item(producto_id, p.atributos)  # si falla: 502/503 y queda PENDIENTE
    return {"producto_id": producto_id, "estado": "PENDIENTE"}


def obtener_o_404(producto_id):
    prod = db.obtener_producto(producto_id)
    if prod is None:
        raise ErrorPaso(404, "rds", "El producto no existe")
    return prod


def detectar_formato(datos):
    if datos[:3] == b"\xff\xd8\xff":
        return "jpg", "image/jpeg"
    if datos[:8] == b"\x89PNG\r\n\x1a\n":
        return "png", "image/png"
    return None


def _publicar(prod, original_key):
    """Lambda -> verificar miniatura (S3) y atributos (DynamoDB) -> PUBLICADO (RDS)."""
    pid, estado = prod["producto_id"], prod["estado"]

    payload = aws.invocar_lambda(pid, original_key, estado)
    # El resultado funcional manda, no el StatusCode de transporte.
    if payload.get("estado") != "PROCESADO":
        raise ErrorPaso(502, "lambda", payload.get("error") or f"Resultado inesperado: {payload}",
                        pid, estado)
    miniatura_key = payload.get("miniatura_key")
    if not miniatura_key:
        raise ErrorPaso(502, "lambda", "La funcion no devolvio miniatura_key", pid, estado)

    aws.verificar_miniatura(pid, miniatura_key, estado)

    item = aws.obtener_item(pid, estado)
    fallos = []
    if item.get("estado_procesamiento") != "PROCESADO":
        fallos.append(f"estado_procesamiento={item.get('estado_procesamiento')}")
    if item.get("miniatura_key") != miniatura_key:
        fallos.append("miniatura_key no coincide con el objeto en S3")
    if not item.get("atributos_json"):
        fallos.append("atributos_json ausente")
    if fallos:
        raise ErrorPaso(502, "dynamodb", "; ".join(fallos), pid, estado)

    try:
        filas = db.marcar_publicado(pid)
    except ErrorPaso as e:
        e.producto_id, e.estado = pid, estado
        raise
    if filas != 1:
        raise ErrorPaso(502, "rds", "No se pudo marcar el producto como PUBLICADO", pid, estado)

    return {"producto_id": pid, "estado": "PUBLICADO", "original_key": original_key,
            "miniatura_key": miniatura_key, "dimensiones": payload.get("dimensiones")}


def guardar_y_publicar(prod, datos, formato):
    ext, tipo = formato
    key = aws.guardar_original(prod["producto_id"], ext, tipo, datos, prod["estado"])
    return _publicar(prod, key)


def reprocesar(producto_id):
    prod = obtener_o_404(producto_id)
    originales = aws.buscar_originales(producto_id, prod["estado"])
    if not originales:
        raise ErrorPaso(409, "s3_original", "No hay imagen original guardada para este producto",
                        producto_id, prod["estado"])
    return _publicar(prod, originales[0])


def _vista(p, item):
    pid = p["producto_id"]
    mkey = item.get("miniatura_key")
    listo = item.get("estado_procesamiento") == "PROCESADO" and bool(mkey)
    return {
        "producto_id": pid,
        "codigo": p["codigo"],
        "nombre": p["nombre"],
        "descripcion": p["descripcion"],
        "precio": float(p["precio"]),
        "categoria_id": p["categoria_id"],
        "fecha": p["fecha"].isoformat() if p.get("fecha") else None,
        "estado": p["estado"],
        "atributos": json.loads(item.get("atributos_json") or "{}"),
        "estado_imagen": item.get("estado_procesamiento"),
        "miniatura": {"bucket": item.get("miniatura_bucket"), "key": mkey,
                      "url": item.get("miniatura_url")} if listo else None,
        "imagen_url": f"/productos/{pid}/imagen" if listo else None,
    }


def listar_publicados():
    return [_vista(p, aws.obtener_item(p["producto_id"], p["estado"]))
            for p in db.listar_publicados()]


def detalle(producto_id):
    p = obtener_o_404(producto_id)
    return _vista(p, aws.obtener_item(producto_id, p["estado"]))


def leer_imagen(producto_id):
    item = aws.obtener_item(producto_id)
    mkey = item.get("miniatura_key")
    if item.get("estado_procesamiento") != "PROCESADO" or not mkey:
        raise ErrorPaso(404, "s3_miniatura", "Miniatura no disponible", producto_id)
    res = aws.leer_miniatura(mkey)
    if res is None:
        raise ErrorPaso(404, "s3_miniatura", "Miniatura no disponible", producto_id)
    return res
