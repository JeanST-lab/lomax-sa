# Índice de evidencias

Las evidencias se organizan por etapa en `evidencia/eN/`. Cada sesión de terminal se grabó con
`Start-Transcript`, por lo que los `.txt` contienen los comandos y sus salidas completas.

La lista automática de archivos de cada carpeta se genera con:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\generar-indice.ps1
```

El resultado queda en `docs/indice-archivos.md`.

## Resumen por etapa

| Evidencia | Etapa | Entregable | Carpeta | Estado |
|---|---|---|---|---|
| E1 | Entorno y base del proyecto | | `evidencia/e1/` | Por ubicar: la carpeta no existe |
| E2 | Persistencia con RDS y DynamoDB | P3 | `evidencia/e2/` | Por ubicar: la carpeta no existe |
| E3 | S3 y Lambda | | `evidencia/e3/` | Carpeta con 14 archivos |
| E4 | Por completar con el título del enunciado | | `evidencia/e4/` | Carpeta con 11 archivos |
| E5 | Flujo integral de la API | | `evidencia/e5/` | Carpeta con 26 archivos |
| E6 | Imágenes Docker y ECR | | `evidencia/e6/` | 2 archivos |
| E7 | Despliegue y validación en EKS | P8 | `evidencia/e7/` | Completa |

Los títulos de E1 a E6 hay que confirmarlos contra el enunciado del curso antes de entregar.

## E2 · Qué debe demostrar (según el enunciado)

- Consultas SQL y `get-item` de DynamoDB.
- Salidas de las pruebas de restricciones: inserción válida, código duplicado, precio negativo y
  categoría inexistente, sin registros parciales.
- Comparación de identificadores y valores antes y después de reiniciar los componentes de
  persistencia sin borrar volúmenes.
- La carga inicial se repite sin duplicar registros.

Archivos del repositorio relacionados: `db/schema.sql`, `db/seed.sql`, `db/pruebas.sql`.

## E6 · Imágenes en ECR

| Qué se demuestra | Comando o archivo |
|---|---|
| Login al registro ECR local | `aws ecr get-login-password \| docker login ...` (tras conectar `floci` y `floci-ecr-registry` a `floci-net`) |
| Tres imágenes publicadas con tag `8154c29` | `docker push` y `aws ecr describe-images` |
| Las imágenes salen de ECR | Se borran las locales, `docker pull` desde ECR y ejecución de los contenedores |
| Mismo digest en ECR y local | `docker image inspect ... --format "{{.RepoDigests}}"` |
| Etiqueta de revisión | `docker image inspect ... --format "{{json .Config.Labels}}"` |
| Miniatura servida por el proxy | `evidencia/e6/miniatura_via_proxy.jpg` (hash `7CF6EC76…`) |
| Sesión completa | `evidencia/e6/sesion.txt` |

## E7 · Despliegue y validación en EKS

| Requisito del enunciado | Evidencia | Archivo de respaldo |
|---|---|---|
| Crear el clúster mediante Floci | `describe-cluster` en `ACTIVE`; contenedor `floci-eks-lomax-eks`; nodo `Ready` | `evidencia/e7/sesion_7_1.txt` |
| Mostrar los Pods | `kubectl get pods -n lomax -o wide` | `evidencia/e7/sesion_7_3.txt` |
| EKS ejecuta las imágenes de ECR | Eventos `Pulled` desde `000000000000.dkr.ecr.us-east-1.localhost:4566`; `IMAGEID` igual al digest de ECR | `evidencia/e7/sesion_7_3.txt`, `sesion_7_4.txt` |
| Acceso a RDS, DynamoDB, S3 y Lambda desde los Pods | Categorías, 22 productos y miniatura con hash `7CF6EC76…` por el proxy | `evidencia/e7/sesion_7_4b.txt` |
| Escalar el backend de 1 a 3 réplicas | Deployment `3/3`; reparto de 60 solicitudes: 23, 17 y 20 por Pod; logs con prefijo de Pod | `evidencia/e7/sesion_7_5.txt`, `sesion_7_5b.txt` |
| Eliminar un Pod y comparar UID | UID `0b5d3339-326b-4ff9-aa4c-5b9be46aa94e` reemplazado por `2fcf15c2-0369-407f-a334-dd71396c297c`; réplicas recuperadas | `evidencia/e7/sesion_7_6.txt`, `sesion_7_6b.txt` |
| Registrar un producto nuevo desde EKS | `EKS-E7-001` (`b3aaa866-2536-4aa9-810e-e96cbdfae590`) en RDS, DynamoDB y S3 | `evidencia/e7/sesion_7_8b.txt` |
| Descargar su miniatura desde S3 | 300×225; hash igual entre S3 y API (`63618B85…`) | `evidencia/e7/miniatura_s3_directa.jpg`, `miniatura_via_api.jpg` |
| Aparición en el catálogo | 23 productos, con el nuevo `PUBLICADO` | `evidencia/e7/sesion_7_8b.txt` |
| Recrear Pods y repetir consultas | 5 Pods reemplazados sin UID repetido; mismo producto, mismos datos y mismo hash | `evidencia/e7/sesion_7_9.txt`, `sesion_7_9b.txt` |

Capturas de navegador recomendadas para completar E7:

1. Catálogo en `http://localhost:8090/#/` con la tarjeta de `Teclado Mecanico EKS E7`.
2. Catálogo tras `Ctrl+F5`, después de recrear los Pods.
3. Formulario *Registrar producto* con un segundo producto (`EKS-E7-002`) y su tarjeta en el catálogo.

Nota sobre `evidencia/e7/sesion_7_9.txt`: la comprobación de datos de ese bloque no se ejecutó
por un error de conteo en PowerShell 5.1 (ver la sección de problemas de `docs/eks.md`). El
resultado válido de esa comprobación está en `sesion_7_9b.txt`. La recreación de Pods y la línea
`OK: los 5 Pods originales fueron reemplazados...` sí están en `sesion_7_9.txt`.
