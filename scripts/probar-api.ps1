<#
  probar-api.ps1 - Verificacion E4 de la API de Lomax SA
  Uso (desde la carpeta Lomax SA):
    .\scripts\probar-api.ps1 -PgDb lomax_db
    .\scripts\probar-api.ps1 -PgDb lomax_db -ProbarCaida
  (-PgUser por defecto es postgres; -PgDb debe ser la base donde estan las tablas)
  Genera evidencia\e4\reporte.txt (y los archivos descargados en evidencia\e4).
#>
param(
    [string]$Api = "http://localhost:8000",
    [string]$PgContainer = "lomax-rds-local",
    [string]$PgUser = "postgres",
    [string]$PgDb = "lomax_db",
    [string]$ImagenValida = "evidencia\e3\prueba.jpg",
    [switch]$ProbarCaida
)

$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root
[Environment]::CurrentDirectory = $Root

$env:AWS_ENDPOINT_URL = "http://localhost:4566"
$env:AWS_ACCESS_KEY_ID = "test"
$env:AWS_SECRET_ACCESS_KEY = "test"
$env:AWS_DEFAULT_REGION = "us-east-1"

$Tabla = "lomax-productos-attr"
$BktOrig = "lomax-imagenes-originales"
$BktMin = "lomax-imagenes-miniaturas"
$Out = "evidencia\e4"
New-Item -ItemType Directory -Force $Out | Out-Null
$Rep = "$Out\reporte.txt"
$script:ok = 0
$script:fallos = 0

# ---------------- utilidades ----------------
function Log([string]$t) { Write-Host $t; Add-Content -Path $Rep -Value $t -Encoding UTF8 }
function Sec([string]$t) { Log ""; Log "=== $t ===" }
function Check([string]$nombre, [bool]$cond, [string]$detalle = "") {
    if ($cond) { $script:ok++; Log "  [OK]     $nombre" }
    else { $script:fallos++; Log "  [FALLO]  $nombre  $detalle" }
}

function Call {
    param([string]$Method, [string]$Path, [string]$Json = "", [string]$File = "",
          [string]$Type = "", [string]$Save = "")
    $dest = "$Out\_resp.bin"
    if ($Save) { $dest = $Save }
    Remove-Item $dest -ErrorAction SilentlyContinue
    $a = @("-s", "-X", $Method, "-o", $dest, "-w", "%{http_code}|%{content_type}")
    if ($Json) {
        [IO.File]::WriteAllText("$Out\_body.json", $Json)
        $a += @("-H", "Content-Type: application/json", "--data-binary", "@$Out\_body.json")
    }
    if ($File) { $a += @("-F", "file=@$File;type=$Type") }
    $a += "$Api$Path"
    $res = "$(& curl.exe @a)"
    $parts = $res.Split("|")
    $status = 0
    [void][int]::TryParse($parts[0], [ref]$status)
    $tipo = ""
    if ($parts.Count -gt 1) { $tipo = $parts[1] }
    $texto = ""
    if ((Test-Path $dest) -and ($tipo -match "json|text")) { $texto = [IO.File]::ReadAllText($dest) }
    # OJO: no llamar $json a esta variable; PowerShell no distingue mayusculas y
    # chocaria con el parametro [string]$Json (convertiria el objeto a texto).
    $obj = $null
    if ($texto) {
        try {
            # PowerShell 5.1 entrega un array JSON como un solo objeto; ForEach-Object lo enumera.
            # El array vacio se trata aparte para que no se convierta en $null.
            if ($texto.Trim() -eq "[]") { $obj = @() }
            else { $obj = $texto | ConvertFrom-Json | ForEach-Object { $_ } }
        } catch { $obj = $null }
    }
    Log ">> $Method $Path -> HTTP $status ($tipo)"
    if ($texto) { Log ("   " + $texto.Substring(0, [Math]::Min(600, $texto.Length))) }
    elseif (Test-Path $dest) { Log ("   (binario: " + (Get-Item $dest).Length + " bytes)") }
    return [pscustomobject]@{ Status = $status; Type = $tipo; Text = $texto; Json = $obj }
}

function Sql([string]$q) {
    $r = docker exec $PgContainer psql -U $PgUser -d $PgDb -t -A -c $q 2>&1
    $t = (($r | ForEach-Object { "$_" }) -join "`n").Trim()
    Log "   [RDS] $q  =>  $t"
    return $t
}

function DynGet([string]$id) {
    [IO.File]::WriteAllText("$Out\_key.json", ('{"producto_id":{"S":"' + $id + '"}}'))
    $raw = aws dynamodb get-item --table-name $Tabla --key file://evidencia/e4/_key.json --consistent-read --output json 2>&1
    $txt = (($raw | ForEach-Object { "$_" }) -join "`n").Trim()
    Log "   [DynamoDB get-item $id]"
    Log $txt
    if (-not $txt) { return $null }
    try { return ($txt | ConvertFrom-Json).Item } catch { return $null }
}

function S3Count([string]$bucket, [string]$prefix) {
    $r = @(aws s3 ls "s3://$bucket/$prefix" --recursive 2>$null)
    Log "   [S3] ls s3://$bucket/$prefix  =>  $($r.Count) objeto(s)"
    foreach ($l in $r) { Log "        $l" }
    return $r.Count
}

function S3Existe([string]$bucket, [string]$key) {
    $r = aws s3api head-object --bucket $bucket --key $key 2>&1
    $existe = ($LASTEXITCODE -eq 0)
    $txt = "NO existe"
    if ($existe) { $txt = "existe" }
    Log "   [S3] head-object s3://$bucket/$key  =>  $txt"
    return $existe
}

function Dim([string]$path) {
    $r = python -c "from PIL import Image; import sys; print(Image.open(sys.argv[1]).size)" $path
    return ("$r").Trim()
}

# ---------------- preparacion ----------------
"REPORTE E4 - API Lomax SA" | Out-File $Rep -Encoding UTF8
Log "Fecha: $(Get-Date -Format s)"
Log "API: $Api | RDS: contenedor $PgContainer (usuario $PgUser, base $PgDb) | AWS: $env:AWS_ENDPOINT_URL"

if (-not (Test-Path $ImagenValida)) { Log "Falta la imagen valida $ImagenValida (debe ser 1200x800)."; exit 1 }
Copy-Item $ImagenValida "$Out\original.jpg" -Force
[IO.File]::WriteAllText("$Out\no_imagen.txt", "esto no es una imagen")
[IO.File]::WriteAllText("$Out\falso.jpg", "texto disfrazado de jpg")
$big = New-Object byte[] (6 * 1024 * 1024); $big[0] = 0xFF; $big[1] = 0xD8; $big[2] = 0xFF
[IO.File]::WriteAllBytes("$Out\grande_6mb.jpg", $big)
$corr = New-Object byte[] 300; $corr[0] = 0xFF; $corr[1] = 0xD8; $corr[2] = 0xFF; $corr[3] = 0xE0
for ($i = 4; $i -lt 300; $i++) { $corr[$i] = 0x41 }
[IO.File]::WriteAllBytes("$Out\corrupto.jpg", $corr)

$stamp = Get-Date -Format "yyyyMMddHHmmss"

# ---------------- A. categorias ----------------
Sec "A. GET /categorias"
$r = Call "GET" "/categorias"
Check "HTTP 200" ($r.Status -eq 200)
$nCatRds = [int](Sql "SELECT count(*) FROM categorias")
$cats = @($r.Json)
Check "categorias de la API == filas en RDS ($nCatRds)" ($cats.Count -eq $nCatRds)
if ($r.Status -ne 200 -or $nCatRds -eq 0) { Log "No se puede continuar (API caida o sin categorias)."; exit 1 }
$catId = [int]$cats[0].categoria_id

# ---------------- B. crear producto ----------------
Sec "B. POST /productos (201, PENDIENTE)"
$codigo = "E4-$stamp"
$body = @{ codigo = $codigo; nombre = "Producto prueba E4"; descripcion = "Creado por probar-api.ps1";
           precio = 25.5; categoria_id = $catId; atributos = @{ color = "rojo"; peso_kg = 1.5 } } | ConvertTo-Json -Depth 5
$r = Call "POST" "/productos" -Json $body
Check "HTTP 201" ($r.Status -eq 201)
Check "estado PENDIENTE en la respuesta" ($r.Json.estado -eq "PENDIENTE")
$id = $r.Json.producto_id
if (-not $id) { Log "No se pudo crear el producto de prueba; se detiene el script."; exit 1 }
Check "RDS: fila con estado PENDIENTE" ((Sql "SELECT estado FROM productos WHERE producto_id='$id'") -eq "PENDIENTE")
$it = DynGet $id
Check "DynamoDB: item con atributos_json" ($null -ne $it.atributos_json)
Check "DynamoDB: estado_procesamiento PENDIENTE" ($it.estado_procesamiento.S -eq "PENDIENTE")

# ---------------- C. entradas invalidas en POST /productos ----------------
Sec "C. POST /productos con errores (409, 400)"
$r = Call "POST" "/productos" -Json $body
Check "codigo duplicado -> 409" ($r.Status -eq 409)
Check "solo existe 1 fila con ese codigo en RDS" ((Sql "SELECT count(*) FROM productos WHERE codigo='$codigo'") -eq "1")
$malo = @{ codigo = "E4-MALO-$stamp"; nombre = "x"; descripcion = "x"; precio = -5; categoria_id = $catId; atributos = @{} } | ConvertTo-Json
$r = Call "POST" "/productos" -Json $malo
Check "precio negativo -> 400" ($r.Status -eq 400)
$r = Call "POST" "/productos" -Json '{"codigo":"solo-codigo"}'
Check "campos faltantes -> 400" ($r.Status -eq 400)
$sinCat = @{ codigo = "E4-SINCAT-$stamp"; nombre = "x"; descripcion = "x"; precio = 1; categoria_id = 999999; atributos = @{} } | ConvertTo-Json
$r = Call "POST" "/productos" -Json $sinCat
Check "categoria inexistente -> 400" ($r.Status -eq 400)
Check "RDS: no se creo ningun producto invalido" ((Sql "SELECT count(*) FROM productos WHERE codigo LIKE 'E4-MALO-%' OR codigo LIKE 'E4-SINCAT-%' OR codigo='solo-codigo'") -eq "0")

# ---------------- D. producto pendiente ----------------
Sec "D. Producto PENDIENTE: detalle, listado, imagen y reprocesar"
$r = Call "GET" "/productos/$id"
Check "GET /productos/{id} -> 200" ($r.Status -eq 200)
Check "estado PENDIENTE" ($r.Json.estado -eq "PENDIENTE")
Check "atributos combinados desde DynamoDB" ($r.Json.atributos.color -eq "rojo")
$r = Call "GET" "/productos/no-existe-$stamp"
Check "GET /productos/{id} inexistente -> 404" ($r.Status -eq 404)
$r = Call "GET" "/productos"
Check "GET /productos -> 200" ($r.Status -eq 200)
Check "el producto PENDIENTE no aparece en el listado" (@($r.Json | Where-Object { $_.producto_id -eq $id }).Count -eq 0)
$r = Call "GET" "/productos/$id/imagen"
Check "GET imagen sin miniatura -> 404" ($r.Status -eq 404)
$r = Call "POST" "/productos/$id/reprocesar"
Check "reprocesar sin original -> 409" ($r.Status -eq 409)

# ---------------- E. imagenes invalidas ----------------
Sec "E. POST /productos/{id}/imagen con entradas invalidas"
$r = Call "POST" "/productos/no-existe-$stamp/imagen" -File "$Out\original.jpg" -Type "image/jpeg"
Check "producto inexistente -> 404" ($r.Status -eq 404)
$r = Call "POST" "/productos/$id/imagen" -File "$Out\no_imagen.txt" -Type "text/plain"
Check "text/plain -> 415" ($r.Status -eq 415)
$r = Call "POST" "/productos/$id/imagen" -File "$Out\falso.jpg" -Type "image/jpeg"
Check "texto con cabecera image/jpeg -> 415 (se validan los bytes)" ($r.Status -eq 415)
$r = Call "POST" "/productos/$id/imagen" -File "$Out\grande_6mb.jpg" -Type "image/jpeg"
Check "archivo de 6 MB -> 413" ($r.Status -eq 413)
Check "RDS: sigue PENDIENTE" ((Sql "SELECT estado FROM productos WHERE producto_id='$id'") -eq "PENDIENTE")
Check "S3: no se guardo ningun original" ((S3Count $BktOrig "originales/$id/") -eq 0)

# ---------------- F. imagen valida -> PUBLICADO ----------------
Sec "F. POST /productos/{id}/imagen valida (200, PUBLICADO)"
$r = Call "POST" "/productos/$id/imagen" -File "$Out\original.jpg" -Type "image/jpeg"
Check "HTTP 200" ($r.Status -eq 200)
Check "estado PUBLICADO en la respuesta" ($r.Json.estado -eq "PUBLICADO")
Check "RDS: estado PUBLICADO" ((Sql "SELECT estado FROM productos WHERE producto_id='$id'") -eq "PUBLICADO")
$it = DynGet $id
$minKey = $it.miniatura_key.S
Check "DynamoDB: estado_procesamiento PROCESADO" ($it.estado_procesamiento.S -eq "PROCESADO")
Check "DynamoDB: atributos_json conservado" ($null -ne $it.atributos_json)
Check "DynamoDB: miniatura_key = miniaturas/$id/original_300.jpg" ($minKey -eq "miniaturas/$id/original_300.jpg")
Check "S3: existe el original originales/$id/original.jpg" (S3Existe $BktOrig "originales/$id/original.jpg")
Check "S3: existe la miniatura referenciada en DynamoDB" (S3Existe $BktMin $minKey)

Sec "F2. GET /productos/{id}/imagen vs objeto descargado de S3"
$r = Call "GET" "/productos/$id/imagen" -Save "$Out\miniatura_api.jpg"
Check "HTTP 200" ($r.Status -eq 200)
Check "Content-Type image/jpeg" ($r.Type -like "image/jpeg*") $r.Type
$g = aws s3api get-object --bucket $BktMin --key $minKey "$Out\miniatura_s3.jpg" 2>&1
Log (($g | ForEach-Object { "$_" }) -join "`n")
$h1 = (Get-FileHash "$Out\miniatura_api.jpg").Hash
$h2 = (Get-FileHash "$Out\miniatura_s3.jpg").Hash
Log "   SHA256 API: $h1"
Log "   SHA256 S3 : $h2"
Check "bytes del endpoint == bytes descargados de S3" ($h1 -eq $h2)
$dOrig = Dim "$Out\original.jpg"
$dMin = Dim "$Out\miniatura_s3.jpg"
Log "   Dimensiones original: $dOrig | miniatura: $dMin"
Check "original 1200x800" ($dOrig -eq "(1200, 800)")
Check "miniatura 300x200" ($dMin -eq "(300, 200)")

# ---------------- G. listado y detalle publicados ----------------
Sec "G. GET /productos y GET /productos/{id} (publicado)"
$r = Call "GET" "/productos"
$lista = @($r.Json)
$mio = $lista | Where-Object { $_.producto_id -eq $id }
Check "el producto PUBLICADO aparece en el listado" ($null -ne $mio)
Check "listado con atributos y referencia de miniatura" (($mio.atributos.color -eq "rojo") -and ($mio.miniatura.key -eq $minKey))
Check "todos los elementos del listado son PUBLICADO" (@($lista | Where-Object { $_.estado -ne "PUBLICADO" }).Count -eq 0)
$nPub = Sql "SELECT count(*) FROM productos WHERE estado='PUBLICADO'"
Check "elementos del listado == publicados en RDS ($nPub)" ($lista.Count -eq [int]$nPub)
$r = Call "GET" "/productos/$id"
Check "detalle -> 200 y PUBLICADO" (($r.Status -eq 200) -and ($r.Json.estado -eq "PUBLICADO"))

# ---------------- H. idempotencia ----------------
Sec "H. Reprocesar y repetir la carga (sin objetos duplicados)"
$r = Call "POST" "/productos/$id/reprocesar"
Check "reprocesar -> 200 PUBLICADO" (($r.Status -eq 200) -and ($r.Json.estado -eq "PUBLICADO"))
$r = Call "POST" "/productos/$id/imagen" -File "$Out\original.jpg" -Type "image/jpeg"
Check "repetir la imagen -> 200 PUBLICADO" (($r.Status -eq 200) -and ($r.Json.estado -eq "PUBLICADO"))
Check "S3: 1 solo original para el producto" ((S3Count $BktOrig "originales/$id/") -eq 1)
Check "S3: 1 sola miniatura para el producto" ((S3Count $BktMin "miniaturas/$id/") -eq 1)

# ---------------- I. fallo del paso Lambda y reintento ----------------
Sec "I. Fallo en Lambda: 502, PENDIENTE y reintento"
$body2 = @{ codigo = "E4B-$stamp"; nombre = "Producto con imagen corrupta"; descripcion = "prueba de fallo";
            precio = 10; categoria_id = $catId; atributos = @{ nota = "corrupto" } } | ConvertTo-Json -Depth 5
$r = Call "POST" "/productos" -Json $body2
$id2 = $r.Json.producto_id
Check "segundo producto creado (201)" ($r.Status -eq 201)
if (-not $id2) { Log "No se pudo crear el segundo producto; se detiene el script."; exit 1 }
$r = Call "POST" "/productos/$id2/imagen" -File "$Out\corrupto.jpg" -Type "image/jpeg"
Check "imagen corrupta -> 502" ($r.Status -eq 502)
Check "la respuesta identifica el paso fallido: lambda" ($r.Json.error.paso -eq "lambda")
Check "la respuesta conserva estado PENDIENTE" ($r.Json.estado -eq "PENDIENTE")
Check "RDS: sigue PENDIENTE" ((Sql "SELECT estado FROM productos WHERE producto_id='$id2'") -eq "PENDIENTE")
$it = DynGet $id2
Check "DynamoDB: estado_procesamiento ERROR" ($it.estado_procesamiento.S -eq "ERROR")
Check "S3: no hay miniatura valida para este producto" ((S3Count $BktMin "miniaturas/$id2/") -eq 0)
$r = Call "GET" "/productos"
Check "el producto fallido no se publica (no esta en el listado)" (@($r.Json | Where-Object { $_.producto_id -eq $id2 }).Count -eq 0)
$r = Call "POST" "/productos/$id2/reprocesar"
Check "reprocesar la imagen corrupta -> 502 (el original existe, no es 409)" ($r.Status -eq 502)
$r = Call "POST" "/productos/$id2/imagen" -File "$Out\original.jpg" -Type "image/jpeg"
Check "reintento con imagen valida -> 200 PUBLICADO" (($r.Status -eq 200) -and ($r.Json.estado -eq "PUBLICADO"))
Check "RDS: PUBLICADO tras el reintento" ((Sql "SELECT estado FROM productos WHERE producto_id='$id2'") -eq "PUBLICADO")
$it = DynGet $id2
Check "DynamoDB: PROCESADO tras el reintento" ($it.estado_procesamiento.S -eq "PROCESADO")
Check "S3: 1 miniatura tras el reintento" ((S3Count $BktMin "miniaturas/$id2/") -eq 1)
Check "S3: 1 solo original (el corrupto fue reemplazado)" ((S3Count $BktOrig "originales/$id2/") -eq 1)

# ---------------- J. caida de RDS (opcional) ----------------
if ($ProbarCaida) {
    Sec "J. RDS no disponible -> 503"
    docker stop $PgContainer | Out-Null
    $r = Call "GET" "/categorias"
    Check "GET /categorias con RDS detenido -> 503" ($r.Status -eq 503)
    Check "la respuesta identifica el paso: rds" ($r.Json.error.paso -eq "rds")
    docker start $PgContainer | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        docker exec $PgContainer pg_isready -U $PgUser 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 1
    }
    $r = Call "GET" "/categorias"
    Check "GET /categorias tras reiniciar RDS -> 200" ($r.Status -eq 200)
}

# ---------------- resumen ----------------
Sec "RESUMEN"
Log "Verificaciones OK: $($script:ok) | FALLO: $($script:fallos)"
Log "Productos de prueba: $id (codigo $codigo) y $id2 (codigo E4B-$stamp)"
Log "Reporte: $Rep"
if ($script:fallos -gt 0) { exit 1 }