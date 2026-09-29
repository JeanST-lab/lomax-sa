from decimal import Decimal

from fastapi import FastAPI, File, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field

from . import config, db, servicio
from .errores import ErrorPaso

app = FastAPI(title="Lomax SA API", version="1.0.0")


class ProductoIn(BaseModel):
    codigo: str = Field(min_length=1, max_length=50)
    nombre: str = Field(min_length=1, max_length=150)
    descripcion: str
    precio: Decimal = Field(ge=0, max_digits=10, decimal_places=2)
    categoria_id: int = Field(ge=1, le=2147483647)
    atributos: dict


@app.exception_handler(ErrorPaso)
async def _manejar_paso(request, exc: ErrorPaso):
    return JSONResponse(status_code=exc.status, content=exc.cuerpo())


@app.exception_handler(RequestValidationError)
async def _manejar_validacion(request, exc: RequestValidationError):
    detalle = "; ".join(
        f"{'.'.join(str(x) for x in e['loc'])}: {e['msg']}" for e in exc.errors())
    return JSONResponse(status_code=400,
                        content={"error": {"paso": "validacion", "detalle": detalle}})


@app.exception_handler(Exception)
async def _manejar_inesperado(request, exc: Exception):
    return JSONResponse(status_code=500,
                        content={"error": {"paso": "interno", "detalle": str(exc)[:300]}})


@app.get("/categorias")
def categorias():
    return db.listar_categorias()


@app.post("/productos", status_code=201)
def crear_producto(p: ProductoIn):
    return servicio.crear_producto(p)


@app.post("/productos/{pid}/imagen")
async def subir_imagen(pid: str, file: UploadFile = File(...)):
    prod = await run_in_threadpool(servicio.obtener_o_404, pid)
    if file.content_type not in config.TIPOS_PERMITIDOS:
        raise ErrorPaso(415, "validacion_formato", "Solo se permite image/jpeg o image/png",
                        pid, prod["estado"])
    datos = await file.read(config.MAX_BYTES + 1)
    if len(datos) > config.MAX_BYTES:
        raise ErrorPaso(413, "validacion_tamano", "El archivo supera 5 MB", pid, prod["estado"])
    formato = servicio.detectar_formato(datos)
    if formato is None:
        raise ErrorPaso(415, "validacion_formato",
                        "El contenido no es un JPEG ni un PNG valido", pid, prod["estado"])
    return await run_in_threadpool(servicio.guardar_y_publicar, prod, datos, formato)


@app.post("/productos/{pid}/reprocesar")
def reprocesar(pid: str):
    return servicio.reprocesar(pid)


@app.get("/productos")
def listar():
    return servicio.listar_publicados()


@app.get("/productos/{pid}")
def detalle(pid: str):
    return servicio.detalle(pid)


@app.get("/productos/{pid}/imagen")
def imagen(pid: str):
    datos, tipo = servicio.leer_imagen(pid)
    return Response(content=datos, media_type=tipo)
