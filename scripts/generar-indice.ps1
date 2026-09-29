# Genera docs\indice-archivos.md con los archivos de evidencia de cada etapa.
# Ejecutar desde la raiz del proyecto:
#   powershell -ExecutionPolicy Bypass -File .\scripts\generar-indice.ps1
$raiz = (Get-Location).Path
$salida = Join-Path $raiz "docs\indice-archivos.md"
$lineas = @("# Archivos de evidencia por etapa", "", "Generado el $(Get-Date -Format 'yyyy-MM-dd HH:mm').", "")

$carpetas = @()
foreach ($base in "evidencia", "evidencias") {
    if (Test-Path (Join-Path $raiz $base)) {
        $carpetas += Get-ChildItem (Join-Path $raiz $base) -Directory
    }
}

if ($carpetas.Count -eq 0) {
    $lineas += "No se encontraron carpetas de evidencia."
}

foreach ($c in ($carpetas | Sort-Object Name)) {
    $archivos = Get-ChildItem $c.FullName -Recurse -File | Sort-Object FullName
    $rel = $c.FullName.Substring($raiz.Length + 1).Replace("\", "/")
    $lineas += "## $rel ($($archivos.Count) archivos)"
    $lineas += ""
    $lineas += "| Archivo | Tamano (bytes) | Modificado |"
    $lineas += "|---|---|---|"
    foreach ($a in $archivos) {
        $nombre = $a.FullName.Substring($c.FullName.Length + 1).Replace("\", "/")
        $lineas += "| $nombre | $($a.Length) | $($a.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) |"
    }
    $lineas += ""
}

# UTF-8 sin BOM
[System.IO.File]::WriteAllLines($salida, $lineas, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Indice generado en $salida"
$lineas | Select-Object -First 40
