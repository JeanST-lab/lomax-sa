<#
  levantar-api.ps1 - Levanta el contenedor de la API de Lomax SA (entorno local)
  Uso (desde la carpeta Lomax SA):
    .\scripts\levantar-api.ps1            # recrea el contenedor con la imagen lomax-api ya construida
    .\scripts\levantar-api.ps1 -Build     # reconstruye la imagen desde .\backend y luego recrea el contenedor

  Requisitos: contenedores lomax-rds-local (Postgres) y floci (emulador AWS, puerto 4566) en marcha.

  Notas:
  - Las variables de un contenedor no se pueden cambiar despues de crearlo; por eso se recrea.
  - host.docker.internal permite al contenedor llegar a Postgres (5432) y a floci (4566) publicados en el host.
  - En EKS estas variables van en el manifiesto del Deployment (env:). Las credenciales de prueba
    (test/test) solo sirven con el emulador; en AWS real se usa un rol de IAM (IRSA) y no se define
    AWS_ENDPOINT_URL ni las claves.
#>
param(
    [string]$Nombre = "lomax-api-container",
    [string]$Imagen = "lomax-api",
    [int]$Puerto = 8000,
    [string]$AwsEndpoint = "http://host.docker.internal:4566",
    [switch]$Build
)

$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root

if ($Build) {
    Write-Host "Construyendo imagen $Imagen desde .\backend ..."
    docker build -t $Imagen .\backend
    if ($LASTEXITCODE -ne 0) { Write-Host "Fallo la construccion de la imagen."; exit 1 }
}

Write-Host "Eliminando contenedor anterior (si existe) ..."
docker rm -f $Nombre 2>&1 | Out-Null

Write-Host "Creando contenedor $Nombre ..."
docker run -d --name $Nombre -p "${Puerto}:8000" `
    -e RDS_DB=lomax_db `
    -e DB_HOST=host.docker.internal `
    -e POSTGRES_HOST=host.docker.internal `
    -e RDS_HOST=host.docker.internal `
    -e DB_NAME=lomax_db `
    -e POSTGRES_DB=lomax_db `
    -e AWS_ACCESS_KEY_ID=test `
    -e AWS_SECRET_ACCESS_KEY=test `
    -e AWS_DEFAULT_REGION=us-east-1 `
    -e AWS_ENDPOINT_URL=$AwsEndpoint `
    $Imagen
if ($LASTEXITCODE -ne 0) { Write-Host "No se pudo crear el contenedor."; exit 1 }

Start-Sleep -Seconds 3
Write-Host ""
Write-Host "Variables AWS dentro del contenedor:"
docker exec $Nombre env | Select-String "AWS"
Write-Host ""
Write-Host "API en http://localhost:$Puerto"