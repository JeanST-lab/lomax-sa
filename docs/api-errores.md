# Errores de la API: formato y paso fallido

Todas las respuestas de error usan el mismo cuerpo:

```json
{"error": {"paso": "lambda", "detalle": "cannot identify image file ..."},
 "producto_id": "3f1c...", "estado": "PENDIENTE"}
```

`producto_id` y `estado` aparecen cuando el error afecta a un producto concreto.

| Codigo | Cuando | Valores de `paso` |
|---|---|---|
| 400 | JSON o campos invalidos, categoria inexistente | `validacion` |
| 404 | Producto inexistente, miniatura no disponible | `rds`, `s3_miniatura` |
| 409 | Codigo duplicado; reprocesar sin original | `rds`, `s3_original` |
| 413 | Archivo mayor a 5 MB | `validacion_tamano` |
| 415 | Tipo no JPEG/PNG (cabecera o bytes) | `validacion_formato` |
| 502 | Un servicio respondio con error | `rds`, `dynamodb`, `s3_original`, `lambda`, `s3_miniatura` |
| 503 | Un servicio no es alcanzable | `rds`, `dynamodb`, `s3_original`, `lambda`, `s3_miniatura` |

Ante cualquier 502/503 el producto conserva su estado (`PENDIENTE`) y se puede reintentar
con `POST /productos/{id}/reprocesar` o volviendo a subir la imagen.
