<#
  verificar-e5.ps1 - Verificacion E5 (frontend + proxy + datos)
  Uso (desde la carpeta Lomax SA), DESPUES de registrar un producto desde el formulario:
    .\scripts\verificar-e5.ps1 -Codigo <codigo-registrado-en-el-formulario>
  Todas las llamadas HTTP pasan por el proxy (http://localhost:8080).
  Genera evidencia\e5\reporte.txt y descarga la miniatura en evidencia\e5.
#>
param(
    [Parameter(Mandatory = $true)][string]$Codigo,
    [string]$Base = "http://localhost:8080",
    [string]$PgContainer = "lomax-rds-local",
    [string]$PgUser = "postgres",
    [string]$PgDb = "lomax_db",
    [string]$PatronIniciales = "^(LAP|MON|PER)-"
)
$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root
[Environment]::CurrentDirectory = $Root
$env:AWS_ENDPOINT_URL = "http://localhost:4566"
$env:AWS_ACCESS_KEY_ID = "test"
$env:AWS_SECRET_ACCESS_KEY = "test"
$env:AWS_DEFAULT_REGION = "us-east-1"
$Tabla = "lomax-productos-attr"; $BktOrig = "lomax-imagenes-originales"; $BktMin = "lomax-imagenes-miniaturas"
$Out = "evidencia\e5"
New-Item -ItemType Directory -Force $Out | Out-Null
$Rep = "$Out\reporte.txt"
$script:ok = 0; $script:fallos = 0

function Log([string]$t) { Write-Host $t; Add-Content -Path $Rep -Value $t -Encoding UTF8 }
function Sec([string]$t) { Log ""; Log "=== $t ===" }
function Check([string]$n, [bool]$c, [string]$d = "") {
    if ($c) { $script:ok++; Log "  [OK]     $n" } else { $script:fallos++; Log "  [FALLO]  $n  $d" }
}
function Call {
    param([string]$Method, [string]$Path, [string]$Body = "", [string]$File = "", [string]$Type = "", [string]$Save = "")
    $dest = "$Out\_resp.bin"; if ($Save) { $dest = $Save }
    Remove-Item $dest -ErrorAction SilentlyContinue
    $a = @("-s", "-X", $Method, "-o", $dest, "-w", "%{http_code}|%{content_type}")
    if ($Body) {
        [IO.File]::WriteAllText("$Out\_body.json", $Body)
        $a += @("-H", "Content-Type: application/json", "--data-binary", "@$Out\_body.json")
    }
    if ($File) { $a += @("-F", "file=@$File;type=$Type") }
    $a += "$Base$Path"
    $res = "$(& curl.exe @a)"
    $parts = $res.Split("|")
    $status = 0; [void][int]::TryParse($parts[0], [ref]$status)
    $tipo = ""; if ($parts.Count -gt 1) { $tipo = $parts[1] }
    $texto = ""
    if ((Test-Path $dest) -and ($tipo -match "json|text|html")) { $texto = [IO.File]::ReadAllText($dest) }
    # OJO: no llamar $json a esta variable (choca con parametros y variables de tipo string)
    $obj = $null
    if ($texto -and $tipo -match "json") {
        try {
            if ($texto.Trim() -eq "[]") { $obj = @() } else { $obj = $texto | ConvertFrom-Json | ForEach-Object { $_ } }
        } catch { $obj = $null }
    }
    Log ">> $Method $Path -> HTTP $status ($tipo)"
    if ($texto -and $tipo -match "json") { Log ("   " + $texto.Substring(0, [Math]::Min(500, $texto.Length))) }
    elseif (Test-Path $dest) { Log ("   (" + (Get-Item $dest).Length + " bytes)") }
    return [pscustomobject]@{ Status = $status; Type = $tipo; Text = $texto; Obj = $obj }
}
function Sql([string]$q) {
    $r = docker exec $PgContainer psql -U $PgUser -d $PgDb -t -A -c $q 2>&1
    $t = (($r | ForEach-Object { "$_" }) -join "`n").Trim()
    Log "   [RDS] $q  =>  $t"
    return $t
}

"REPORTE E5 - Frontend Lomax SA" | Out-File $Rep -Encoding UTF8
Log "Fecha: $(Get-Date -Format s)"
Log "Entrada (proxy): $Base | codigo registrado desde el formulario: $Codigo"
$stamp = Get-Date -Format "yyyyMMddHHmmss"

# ---------------- 1. proxy y frontend ----------------
Sec "1. Proxy: frontend en / y API en /api"
$r = Call "GET" "/"
Check "GET / -> 200 (frontend servido por el proxy)" (($r.Status -eq 200) -and ($r.Text -match "Lomax"))
$r = Call "GET" "/api/categorias"
Check "GET /api/categorias -> 200 (API tras el proxy)" ($r.Status -eq 200)
$catId = [int](@($r.Obj)[0].categoria_id)

# ---------------- 2. producto registrado desde el formulario ----------------
Sec "2. Producto registrado desde el formulario"
$fila = Sql "SELECT producto_id || '|' || estado FROM productos WHERE codigo='$Codigo'"
Check "RDS: existe una fila con ese codigo" ($fila -match "\|")
if ($fila -notmatch "\|") { Log "No se encontro el codigo en RDS; se detiene."; exit 1 }
$id = $fila.Split("|")[0]; $est = $fila.Split("|")[1]
Log "   producto_id = $id"
Check "RDS: estado PUBLICADO" ($est -eq "PUBLICADO")
$r = Call "GET" "/api/productos/$id"
Check "GET /api/productos/{id} -> 200 y PUBLICADO" (($r.Status -eq 200) -and ($r.Obj.estado -eq "PUBLICADO"))
Check "el detalle trae descripcion y atributos" ((-not [string]::IsNullOrEmpty($r.Obj.descripcion)) -and ($null -ne $r.Obj.atributos))

[IO.File]::WriteAllText("$Out\_key.json", ('{"producto_id":{"S":"' + $id + '"}}'))
$raw = aws dynamodb get-item --table-name $Tabla --key file://evidencia/e5/_key.json --consistent-read --output json
Log "   [DynamoDB get-item $id]"; Log ($raw -join "`n")
$it = (($raw -join "`n") | ConvertFrom-Json).Item
$minKey = $it.miniatura_key.S
Check "DynamoDB: atributos_json presente" ($null -ne $it.atributos_json)
Check "DynamoDB: estado_procesamiento PROCESADO" ($it.estado_procesamiento.S -eq "PROCESADO")
Check "DynamoDB: miniatura_key = miniaturas/$id/original_300.jpg" ($minKey -eq "miniaturas/$id/original_300.jpg")

aws s3api head-object --bucket $BktOrig --key "originales/$id/original.jpg" 2>$null | Out-Null
Check "S3: existe el original" ($LASTEXITCODE -eq 0)
aws s3api get-object --bucket $BktMin --key $minKey "$Out\miniatura_s3.jpg" 2>$null | Out-Null
Check "S3: miniatura descargada ($Out\miniatura_s3.jpg)" ($LASTEXITCODE -eq 0)
$r = Call "GET" "/api/productos/$id/imagen" -Save "$Out\miniatura_api.jpg"
Check "GET /api/productos/{id}/imagen -> 200 image/jpeg" (($r.Status -eq 200) -and ($r.Type -like "image/jpeg*"))
$h1 = (Get-FileHash "$Out\miniatura_api.jpg").Hash; $h2 = (Get-FileHash "$Out\miniatura_s3.jpg").Hash
Log "   SHA256 API: $h1"; Log "   SHA256 S3 : $h2"
Check "bytes del endpoint == miniatura descargada de S3" ($h1 -eq $h2)
$r = Call "GET" "/api/productos"
Check "el producto aparece en el catalogo (GET /api/productos)" (@($r.Obj | Where-Object { $_.producto_id -eq $id }).Count -eq 1)

# ---------------- 3. codigo duplicado ----------------
Sec "3. Codigo duplicado"
$dup = @{ codigo = $Codigo; nombre = "dup"; descripcion = "dup"; precio = 1; categoria_id = $catId; atributos = @{} } | ConvertTo-Json
$r = Call "POST" "/api/productos" -Body $dup
Check "codigo duplicado -> 409" ($r.Status -eq 409)
Check "la respuesta identifica el paso: rds" ($r.Obj.error.paso -eq "rds")
Check "RDS: sigue habiendo 1 sola fila con ese codigo" ((Sql "SELECT count(*) FROM productos WHERE codigo='$Codigo'") -eq "1")

# ---------------- 4. archivo invalido ----------------
Sec "4. Archivo invalido: producto incompleto fuera del catalogo"
$codInv = "E5-INV-$stamp"
$nuevo = @{ codigo = $codInv; nombre = "Producto sin imagen valida"; descripcion = "prueba E5"; precio = 5; categoria_id = $catId; atributos = @{ nota = "sin imagen" } } | ConvertTo-Json -Depth 4
$r = Call "POST" "/api/productos" -Body $nuevo
$idInv = $r.Obj.producto_id
Check "producto creado (201) en PENDIENTE" (($r.Status -eq 201) -and ($r.Obj.estado -eq "PENDIENTE"))
[IO.File]::WriteAllText("$Out\falso.jpg", "texto disfrazado de jpg")
$r = Call "POST" "/api/productos/$idInv/imagen" -File "$Out\falso.jpg" -Type "image/jpeg"
Check "archivo invalido -> 415" ($r.Status -eq 415)
Check "RDS: el producto sigue PENDIENTE" ((Sql "SELECT estado FROM productos WHERE producto_id='$idInv'") -eq "PENDIENTE")
$r = Call "GET" "/api/productos"
Check "el producto incompleto NO aparece en el catalogo" (@($r.Obj | Where-Object { $_.producto_id -eq $idInv }).Count -eq 0)
Log "   (queda un producto PENDIENTE de prueba: $codInv, $idInv)"

# ---------------- 5. los 20 productos iniciales ----------------
Sec "5. Los 20 productos iniciales publicados (catalogo, RDS, DynamoDB, S3)"
$idsRds = @(docker exec $PgContainer psql -U $PgUser -d $PgDb -t -A -c "SELECT producto_id FROM productos WHERE estado='PUBLICADO' AND codigo ~ '$PatronIniciales' ORDER BY codigo" | Where-Object { "$_".Trim() -ne "" } | ForEach-Object { "$_".Trim() })
Log "   [RDS] publicados con codigo $PatronIniciales => $($idsRds.Count)"
Check "RDS: 20 productos iniciales PUBLICADO" ($idsRds.Count -eq 20)
$lista = Call "GET" "/api/productos"
$enCat = @($lista.Obj | Where-Object { $_.codigo -match $PatronIniciales }).Count
Check "catalogo (API): 20 productos iniciales" ($enCat -eq 20) "(hay $enCat)"
$nPub = [int](Sql "SELECT count(*) FROM productos WHERE estado='PUBLICADO'")
Check "catalogo total == publicados en RDS ($nPub)" (@($lista.Obj).Count -eq $nPub)
$scan = (aws dynamodb scan --table-name $Tabla --output json) -join "`n" | ConvertFrom-Json
$dyn = @{}; foreach ($i in $scan.Items) { $dyn[$i.producto_id.S] = $i }
$claves = @{}
foreach ($l in @(aws s3 ls "s3://$BktMin/" --recursive)) { $k = ("$l" -split "\s+")[-1]; if ($k) { $claves[$k] = $true } }
$okDyn = 0; $okS3 = 0
foreach ($x in $idsRds) {
    $d = $dyn[$x]
    if ($d -and $d.estado_procesamiento.S -eq "PROCESADO") { $okDyn++ }
    if ($d -and $claves.ContainsKey($d.miniatura_key.S)) { $okS3++ }
}
Log "   DynamoDB PROCESADO: $okDyn de $($idsRds.Count) | miniatura en S3: $okS3 de $($idsRds.Count)"
Check "DynamoDB: los 20 con estado PROCESADO" ($okDyn -eq 20)
Check "S3: las 20 miniaturas existen" ($okS3 -eq 20)

Sec "RESUMEN"
Log "Verificaciones OK: $($script:ok) | FALLO: $($script:fallos)"
Log "Producto del formulario: $id (codigo $Codigo)"
Log "Reporte: $Rep"
Remove-Item "$Out\_key.json", "$Out\_body.json", "$Out\_resp.bin" -ErrorAction SilentlyContinue
if ($script:fallos -gt 0) { exit 1 }
