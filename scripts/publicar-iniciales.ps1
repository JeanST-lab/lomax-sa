<#
  publicar-iniciales.ps1 - Publica los 20 productos iniciales (LAP-/MON-/PER-) subiendo una foto
  DISTINTA a cada uno con la propia API (POST /productos/{id}/imagen), es decir, por el flujo real.
  Uso (desde la carpeta Lomax SA):
    .\scripts\publicar-iniciales.ps1
  Genera con Pillow una imagen 1200x800 por producto (color propio + el codigo escrito) en
  evidencia\e5\iniciales\. Es idempotente: solo toca los productos PENDIENTE.
#>
param(
    [string]$Api = "http://localhost:8000",
    [string]$PgContainer = "lomax-rds-local",
    [string]$PgUser = "postgres",
    [string]$PgDb = "lomax_db",
    [string]$Patron = "^(LAP|MON|PER)-"
)
$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root
[Environment]::CurrentDirectory = $Root

$Dir = "evidencia\e5\iniciales"
New-Item -ItemType Directory -Force $Dir | Out-Null

# Generador de imagenes (Python + Pillow)
$py = @'
import sys, hashlib, colorsys
from PIL import Image, ImageDraw, ImageFont
codigo, out = sys.argv[1], sys.argv[2]
d = hashlib.md5(codigo.encode()).digest()
r, g, b = [int(c * 255) for c in colorsys.hsv_to_rgb(d[0] / 255.0, 0.55, 0.80)]
img = Image.new("RGB", (1200, 800), (r, g, b))
dr = ImageDraw.Draw(img)
try:
    font = ImageFont.truetype("arial.ttf", 150)
except Exception:
    try:
        font = ImageFont.load_default(size=150)
    except Exception:
        font = ImageFont.load_default()
box = dr.textbbox((0, 0), codigo, font=font)
w, h = box[2] - box[0], box[3] - box[1]
dr.text(((1200 - w) / 2 - box[0], (800 - h) / 2 - box[1]), codigo, fill=(255, 255, 255), font=font)
img.save(out, "JPEG", quality=90)
'@
[IO.File]::WriteAllText("$Dir\_gen.py", $py)

$filas = @(docker exec $PgContainer psql -U $PgUser -d $PgDb -t -A -c "SELECT producto_id || '|' || codigo FROM productos WHERE estado='PENDIENTE' AND codigo ~ '$Patron' ORDER BY codigo")
$filas = @($filas | Where-Object { "$_".Trim() -ne "" })
Write-Host "Productos iniciales pendientes: $($filas.Count)"
$ok = 0; $fallo = 0
foreach ($f in $filas) {
    $p = "$f".Trim().Split("|")
    $id = $p[0]; $codigo = $p[1]
    $img = "$Dir\$codigo.jpg"
    python "$Dir\_gen.py" $codigo $img
    if (-not (Test-Path $img)) { $fallo++; Write-Host "  [FALLO]  $codigo : no se pudo generar la imagen (Pillow instalado?)"; continue }
    $code = "$(curl.exe -s -o NUL -w '%{http_code}' -X POST -F "file=@$img;type=image/jpeg" "$Api/productos/$id/imagen")"
    if ($code -eq "200") { $ok++; Write-Host "  [OK]     $codigo ($id) -> 200" }
    else { $fallo++; Write-Host "  [FALLO]  $codigo ($id) -> HTTP $code" }
}
Remove-Item "$Dir\_gen.py" -ErrorAction SilentlyContinue
$pub = (docker exec $PgContainer psql -U $PgUser -d $PgDb -t -A -c "SELECT count(*) FROM productos WHERE estado='PUBLICADO' AND codigo ~ '$Patron'").Trim()
Write-Host "Publicados ahora (iniciales): $pub | OK: $ok | FALLO: $fallo"
if ($fallo -gt 0) { exit 1 }