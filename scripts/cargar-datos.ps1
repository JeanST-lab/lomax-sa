# Cargar datos de forma repetible para RDS y DynamoDB (Etapa 2)
# Lomax SA

Write-Host "Iniciando carga de datos para Lomax SA..." -ForegroundColor Cyan

$env:AWS_ENDPOINT_URL      = "http://localhost:4566"
$env:AWS_ACCESS_KEY_ID     = "test"
$env:AWS_SECRET_ACCESS_KEY = "test"
$env:AWS_DEFAULT_REGION    = "us-east-1"

# Escapar comillas simples para SQL
function Esc([string]$s) { return $s -replace "'", "''" }

# Ejecuta un comando nativo sin que stderr genere errores de PowerShell.
# Devuelve un objeto con Codigo (exit code) y Salida (texto).
function Invoke-Native([scriptblock]$Comando) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $salida = & $Comando 2>&1 | ForEach-Object { "$_" }
        $codigo = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    [pscustomobject]@{ Codigo = $codigo; Salida = ($salida -join "`n") }
}

# 1. Crear tabla DynamoDB si no existe
Write-Host "Verificando/Creando tabla DynamoDB 'lomax-productos-attr'..." -ForegroundColor Yellow
$r = Invoke-Native { aws dynamodb describe-table --table-name lomax-productos-attr }
if ($r.Codigo -ne 0) {
    $r = Invoke-Native {
        aws dynamodb create-table `
            --table-name lomax-productos-attr `
            --attribute-definitions AttributeName=producto_id,AttributeType=S `
            --key-schema AttributeName=producto_id,KeyType=HASH `
            --billing-mode PAY_PER_REQUEST
    }
    if ($r.Codigo -ne 0) {
        Write-Host "Error creando la tabla:`n$($r.Salida)" -ForegroundColor Red
        exit 1
    }
    Write-Host "Tabla creada." -ForegroundColor Green
} else {
    Write-Host "La tabla ya existe." -ForegroundColor Gray
}

# 2. Leer productos.json
$jsonPath = Join-Path $PSScriptRoot "..\db\productos.json"
if (-not (Test-Path $jsonPath)) {
    Write-Error "No se encontró el archivo $jsonPath"
    exit 1
}
$jsonData = Get-Content -Raw -Path $jsonPath -Encoding UTF8 | ConvertFrom-Json

Write-Host "Cargando Categorías y Productos en PostgreSQL (RDS)..." -ForegroundColor Yellow

foreach ($cat in $jsonData.categorias) {
    $sqlCat = "INSERT INTO categorias (categoria_id, nombre, descripcion) VALUES ($($cat.categoria_id), '$(Esc $cat.nombre)', '$(Esc $cat.descripcion)') ON CONFLICT (categoria_id) DO NOTHING;"
    $r = Invoke-Native { docker exec -i lomax-rds-local psql -U postgres -d lomax_db -c $sqlCat }
    if ($r.Codigo -ne 0) { Write-Host "Error en categoría $($cat.categoria_id): $($r.Salida)" -ForegroundColor Red }
}

foreach ($prod in $jsonData.productos) {
    # RDS
    $sqlProd = "INSERT INTO productos (producto_id, codigo, nombre, descripcion, precio, categoria_id, estado) VALUES ('$($prod.producto_id)', '$(Esc $prod.codigo)', '$(Esc $prod.nombre)', '$(Esc $prod.descripcion)', $($prod.precio), $($prod.categoria_id), 'PENDIENTE') ON CONFLICT (codigo) DO NOTHING;"
    $r = Invoke-Native { docker exec -i lomax-rds-local psql -U postgres -d lomax_db -c $sqlProd }
    if ($r.Codigo -ne 0) { Write-Host "Error RDS en producto $($prod.producto_id): $($r.Salida)" -ForegroundColor Red }

    # DynamoDB
    $attrJson = $prod.atributos | ConvertTo-Json -Compress
    $item = @{
        producto_id          = @{ S = [string]$prod.producto_id }
        atributos_json       = @{ S = $attrJson }
        estado_procesamiento = @{ S = "PENDIENTE_IMAGEN" }
    } | ConvertTo-Json -Depth 5 -Compress

    $tmp = Join-Path $env:TEMP "item_$($prod.producto_id).json"
    [System.IO.File]::WriteAllText($tmp, $item, (New-Object System.Text.UTF8Encoding($false)))

    $r = Invoke-Native { aws dynamodb put-item --table-name lomax-productos-attr --item "file://$tmp" }
    if ($r.Codigo -ne 0) { Write-Host "Error DynamoDB en producto $($prod.producto_id): $($r.Salida)" -ForegroundColor Red }

    Remove-Item $tmp -ErrorAction SilentlyContinue
}

Write-Host "Carga finalizada." -ForegroundColor Green