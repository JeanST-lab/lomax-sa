param([string]$Codigo = "EKS-E7-R1", [string]$Dir = "evidencia\e7\revalidacion", [string]$Nombre = "Teclado Mecanico EKS E7 Revalidacion")
$env:AWS_ENDPOINT_URL="http://localhost:4566"; $env:AWS_ACCESS_KEY_ID="test"; $env:AWS_SECRET_ACCESS_KEY="test"; $env:AWS_DEFAULT_REGION="us-east-1"
$API = "http://localhost:8090/api"
$codigo = $Codigo
$dir = $Dir; New-Item -ItemType Directory -Force $dir | Out-Null
Add-Type -AssemblyName System.Drawing

# Asegurar la entrada al proxy de EKS
$http = curl.exe -s -o NUL -w "%{http_code}" http://localhost:8090/
if ($http -ne "200") { Start-Process kubectl -ArgumentList "port-forward -n lomax svc/proxy 8090:80" -WindowStyle Hidden; Start-Sleep -Seconds 5 }

# 0. Foto de prueba grande
$img = "data\producto_e7.jpg"
if (-not (Test-Path $img)) {
    New-Item -ItemType Directory -Force data | Out-Null
    $bmp = New-Object System.Drawing.Bitmap 1600, 1200
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::SteelBlue)), 0, 0, 1600, 1200)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::DarkOrange)), 100, 100, 700, 500)
    $g.DrawString("Lomax SA - E7", (New-Object System.Drawing.Font "Arial", 110), [System.Drawing.Brushes]::White, 150, 800)
    $g.Dispose()
    $bmp.Save((Join-Path $PWD $img), [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bmp.Dispose()
}
$im = [System.Drawing.Image]::FromFile((Join-Path $PWD $img))
"=== 0. FOTO ORIGINAL: $($im.Width)x$($im.Height), $((Get-Item $img).Length) bytes ==="
$im.Dispose()

# 1. Registro (idempotente por codigo)
"=== 1. REGISTRO VIA PROXY DE EKS ==="
$id = $null
$existente = $null; if (Test-Path "$dir\e7_producto_id.txt") { $sid = (Get-Content "$dir\e7_producto_id.txt").Trim(); try { $existente = Invoke-RestMethod "$API/productos/$sid" } catch { } }; if (-not $existente) { $existente = (Invoke-RestMethod "$API/productos") | Where-Object codigo -eq $codigo }
if ($existente) { $id = $existente.producto_id; "El codigo $codigo ya existe; se reutiliza el producto $id" }
else {
    $body = @{ codigo = $codigo; nombre = $Nombre; descripcion = "Producto registrado desde la aplicacion en EKS"; precio = 59.90; categoria_id = 3; atributos = @{ conexion = "USB-C"; distribucion = "Latinoamericano"; retroiluminado = $true } } | ConvertTo-Json -Depth 5
    try { $r = Invoke-RestMethod -Method Post -Uri "$API/productos" -ContentType "application/json" -Body $body; $id = $r.producto_id; "Registrado: $id" }
    catch { "ERROR al registrar: " + $_.ErrorDetails.Message; throw }
}
$id | Set-Content "$dir\e7_producto_id.txt" -Encoding ascii

# 2. Foto
"=== 2. SUBIDA DE LA FOTO ==="
$o = Invoke-RestMethod "$API/openapi.json"
$campo = "file"
"Campo multipart: $campo"
curl.exe -s -X POST "$API/productos/$id/imagen" -F "${campo}=@$img;type=image/jpeg"
""
Start-Sleep -Seconds 2

# 3. Detalle
"=== 3. DETALLE VIA API ==="
$d = Invoke-RestMethod "$API/productos/$id"
$d | ConvertTo-Json -Depth 6

# 4. RDS
"=== 4. RDS ==="
docker exec lomax-rds-local psql -U postgres -d lomax_db -c "SELECT producto_id, codigo, nombre, precio, categoria_id, estado FROM productos WHERE producto_id='$id';"
docker exec lomax-rds-local psql -U postgres -d lomax_db -c "SELECT count(*) AS filas_con_ese_codigo FROM productos WHERE codigo='$codigo';"

# 5. DynamoDB
"=== 5. DYNAMODB ==="
$T = "lomax-productos-attr"
$ds = aws dynamodb describe-table --table-name $T | ConvertFrom-Json
$hk = $ds.Table.KeySchema[0].AttributeName
$ht = ($ds.Table.AttributeDefinitions | Where-Object AttributeName -eq $hk).AttributeType
"Clave: $hk (tipo $ht)"
$k = @{}; $k[$hk] = @{ $ht = "$id" }
$kf = "$env:TEMP\e7key.json"
$k | ConvertTo-Json -Compress | Set-Content $kf -Encoding ascii
aws dynamodb get-item --table-name $T --key "file://$kf"

# 6. S3
"=== 6. S3 ==="
"Originales:"; aws s3 ls s3://lomax-imagenes-originales --recursive | Select-String $id
"Miniaturas:"; aws s3 ls s3://lomax-imagenes-miniaturas --recursive | Select-String $id
aws s3 cp "s3://lomax-imagenes-miniaturas/$($d.miniatura.key)" "$dir\miniatura_s3_directa.jpg" --only-show-errors
curl.exe -s -o "$dir\miniatura_via_api.jpg" "$API/productos/$id/imagen"
"Hash miniatura desde S3 : " + (Get-FileHash "$dir\miniatura_s3_directa.jpg").Hash
"Hash miniatura via API  : " + (Get-FileHash "$dir\miniatura_via_api.jpg").Hash
$t = [System.Drawing.Image]::FromFile((Join-Path $PWD "$dir\miniatura_via_api.jpg"))
"Dimensiones miniatura: $($t.Width)x$($t.Height) (maximo 300x300, misma proporcion 4:3)"
$t.Dispose()

# 7. Catalogo
"=== 7. CATALOGO ==="
$lista = Invoke-RestMethod "$API/productos"
"Productos en el catalogo: $($lista.Count)"
$lista | Where-Object codigo -eq $codigo | Select-Object producto_id, codigo, nombre, precio, estado | Format-List
