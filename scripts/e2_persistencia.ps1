# Evidencia E2: compara RDS y DynamoDB antes y despues de reiniciar SIN borrar volumenes.
# Uso (desde la raiz del proyecto):
#   .\scripts\e2_persistencia.ps1 -Fase antes
#   docker restart lomax-rds-local floci
#   .\scripts\e2_persistencia.ps1 -Fase despues
param([Parameter(Mandatory=$true)][ValidateSet("antes","despues")][string]$Fase)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:AWS_ENDPOINT_URL = "http://localhost:4566"; $env:AWS_ACCESS_KEY_ID = "test"
$env:AWS_SECRET_ACCESS_KEY = "test"; $env:AWS_DEFAULT_REGION = "us-east-1"

$rds = "lomax-rds-local"; $db = "lomax_db"; $tabla = "lomax-productos-attr"
$raiz = Split-Path $PSScriptRoot -Parent
$dir = Join-Path $raiz "evidencia\e2"
New-Item -ItemType Directory -Force $dir | Out-Null
Start-Transcript (Join-Path $dir "sesion_e2_$Fase.txt") | Out-Null

$usr = (docker exec $rds printenv POSTGRES_USER | Out-String).Trim()
if (-not $usr) { $usr = "postgres" }

if ($Fase -eq "despues") {
    Write-Host "Esperando a que RDS y Floci respondan..."
    for ($i = 0; $i -lt 45; $i++) {
        docker exec $rds pg_isready -U $usr 2>$null | Out-Null; $pg = $LASTEXITCODE
        aws dynamodb list-tables 2>$null | Out-Null; $dy = $LASTEXITCODE
        if ($pg -eq 0 -and $dy -eq 0) { break }
        Start-Sleep -Seconds 2
    }
}

# --- RDS: todas las filas de productos ---
docker exec $rds psql -U $usr -d $db -At -c "SELECT * FROM productos ORDER BY 1;" |
    Out-File (Join-Path $dir "rds_$Fase.txt") -Encoding utf8
$nRds = (docker exec $rds psql -U $usr -d $db -At -c "SELECT count(*) FROM productos;" | Out-String).Trim()

# --- DynamoDB: todos los items, ordenados por producto_id ---
$r = aws dynamodb scan --table-name $tabla --output json | Out-String | ConvertFrom-Json
$items = @($r.Items | Sort-Object { $_.producto_id.S })
if ($items.Count -gt 0) { $items | ConvertTo-Json -Depth 10 | Out-File (Join-Path $dir "ddb_$Fase.json") -Encoding utf8 } else { Set-Content (Join-Path $dir "ddb_$Fase.json") -Value "" }

# --- Estado de los contenedores y volumenes ---
$estado = @(
    "fase=$Fase",
    "productos_en_rds=$nRds",
    "items_en_dynamodb=$($items.Count)",
    "rds_iniciado=$(docker inspect -f '{{.State.StartedAt}}' $rds)",
    "floci_iniciado=$(docker inspect -f '{{.State.StartedAt}}' floci)",
    "rds_volumenes=$(docker inspect $rds --format '{{json .Mounts}}')",
    "floci_volumenes=$(docker inspect floci --format '{{json .Mounts}}')"
)
$estado | Out-File (Join-Path $dir "estado_$Fase.txt") -Encoding utf8
$estado | ForEach-Object { if ($_ -notmatch "volumenes") { Write-Host $_ } }

if ($Fase -eq "despues") {
    Write-Host "`n=== Comparacion antes / despues ===" -ForegroundColor Cyan
    $fallo = $false
    foreach ($par in @(@("rds","txt"), @("ddb","json"))) {
        $fa = Join-Path $dir "$($par[0])_antes.$($par[1])"
        $fb = Join-Path $dir "$($par[0])_despues.$($par[1])"
        $a = @(Get-Content $fa -Encoding UTF8 -ErrorAction SilentlyContinue)
        $b = @(Get-Content $fb -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($a.Count -eq 0 -or $b.Count -eq 0) {
            Write-Host "FALLO en $($par[0]): archivo vacio (antes=$($a.Count) lineas, despues=$($b.Count) lineas)" -ForegroundColor Red
            $fallo = $true; continue
        }
        $d = Compare-Object $a $b
        if ($d) { Write-Host "DIFERENCIAS en $($par[0]):" -ForegroundColor Red; $d | Select-Object -First 10; $fallo = $true }
        else    { Write-Host "IGUAL: $($par[0]) ($($a.Count) lineas identicas)" -ForegroundColor Green }
    }
    if ($fallo) { Write-Host "RESULTADO: la persistencia NO se comprobo" -ForegroundColor Red }
    else        { Write-Host "RESULTADO: los datos persisten tras el reinicio" -ForegroundColor Green }
    Write-Host "`n=== Otros servicios de Floci tras el reinicio ===" -ForegroundColor Cyan
    aws s3 ls
    aws lambda list-functions --query "Functions[].FunctionName" --output text
    aws ecr describe-repositories --query "repositories[].repositoryName" --output text
}
Stop-Transcript | Out-Null