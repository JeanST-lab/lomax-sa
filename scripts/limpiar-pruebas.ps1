<#
  limpiar-pruebas.ps1 - Borra los productos de prueba (por defecto codigo LIKE 'E4%') de RDS, DynamoDB y S3.
  Uso (desde la carpeta Lomax SA):
    .\scripts\limpiar-pruebas.ps1              # SIMULACION: solo lista lo que borraria
    .\scripts\limpiar-pruebas.ps1 -Ejecutar    # borra de verdad
  Guarda antes las capturas de la E4: la evidencia se apoya en esos datos.
#>
param(
    [string]$PgContainer = "lomax-rds-local",
    [string]$PgUser = "postgres",
    [string]$PgDb = "lomax_db",
    [string]$PatronLike = "E4%",
    [switch]$Ejecutar
)
$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root
[Environment]::CurrentDirectory = $Root
$env:AWS_ENDPOINT_URL = "http://localhost:4566"
$env:AWS_ACCESS_KEY_ID = "test"
$env:AWS_SECRET_ACCESS_KEY = "test"
$env:AWS_DEFAULT_REGION = "us-east-1"
$Tabla = "lomax-productos-attr"; $BktOrig = "lomax-imagenes-originales"; $BktMin = "lomax-imagenes-miniaturas"
New-Item -ItemType Directory -Force "evidencia" | Out-Null

$filas = @(docker exec $PgContainer psql -U $PgUser -d $PgDb -t -A -c "SELECT producto_id || '|' || codigo FROM productos WHERE codigo LIKE '$PatronLike' ORDER BY codigo")
$filas = @($filas | Where-Object { "$_".Trim() -ne "" })
Write-Host "Productos que coinciden con '$PatronLike': $($filas.Count)"
foreach ($f in $filas) {
    $p = "$f".Trim().Split("|"); $id = $p[0]; $codigo = $p[1]
    if (-not $Ejecutar) { Write-Host "  (simulacion) $codigo  $id"; continue }
    aws s3 rm "s3://$BktOrig/originales/$id/" --recursive | Out-Null
    aws s3 rm "s3://$BktMin/miniaturas/$id/" --recursive | Out-Null
    [IO.File]::WriteAllText("evidencia\_key.json", ('{"producto_id":{"S":"' + $id + '"}}'))
    aws dynamodb delete-item --table-name $Tabla --key file://evidencia/_key.json | Out-Null
    docker exec $PgContainer psql -U $PgUser -d $PgDb -t -A -c "DELETE FROM productos WHERE producto_id='$id'" | Out-Null
    Write-Host "  borrado: $codigo  $id"
}
Remove-Item "evidencia\_key.json" -ErrorAction SilentlyContinue
if (-not $Ejecutar) { Write-Host "Simulacion terminada. Repite con -Ejecutar para borrar." }
else { Write-Host "Listo. Productos restantes: $((docker exec $PgContainer psql -U $PgUser -d $PgDb -t -A -c 'SELECT count(*) FROM productos').Trim())" }
