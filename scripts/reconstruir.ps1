# Reconstruye el entorno Floci por pasos (Floci ya arranca con --persist, esto se hace una sola vez).
# Uso, desde la raiz del proyecto:
#   .\scripts\reconstruir.ps1 -Paso 1              # buckets S3 + lista de productos "extra" en RDS (no borra nada)
#   .\scripts\reconstruir.ps1 -Paso 1 -Limpiar     # deja RDS consistente y crea tabla + items en DynamoDB
#   .\scripts\reconstruir.ps1 -Paso 2              # Lambda + prueba de miniatura
#   .\scripts\reconstruir.ps1 -Paso 3              # repositorios ECR + push de las 3 imagenes
#   .\scripts\reconstruir.ps1 -Paso 4              # cluster EKS + kubeconfig
#   .\scripts\reconstruir.ps1 -Paso 5              # despliegue en EKS
param([Parameter(Mandatory=$true)][ValidateSet(1,2,3,4,5)][int]$Paso, [switch]$Limpiar)

$ErrorActionPreference = "Continue"
$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root
[Environment]::CurrentDirectory = $Root
$env:AWS_ENDPOINT_URL = "http://localhost:4566"; $env:AWS_ACCESS_KEY_ID = "test"
$env:AWS_SECRET_ACCESS_KEY = "test"; $env:AWS_DEFAULT_REGION = "us-east-1"

$Rds = "lomax-rds-local"; $K3S = "floci-eks-lomax-eks"
$Reg = "000000000000.dkr.ecr.us-east-1.localhost:4566"; $Tag = "8154c29"
$BktO = "lomax-imagenes-originales"; $BktM = "lomax-imagenes-miniaturas"; $Tabla = "lomax-productos-attr"
$Fn = "lomax-procesar-imagen"

function Titulo($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Ok($t)     { Write-Host "  [OK]    $t" -ForegroundColor Green }
function Mal($t)    { Write-Host "  [FALLO] $t" -ForegroundColor Red }
function Psql([string]$sql) { (docker exec $Rds psql -U postgres -d lomax_db -t -A -c $sql | Out-String).Trim() }

# Floci tiene que responder y ser persistente
aws s3 ls 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Mal "Floci no responde en localhost:4566"; return }

# ------------------------------------------------------------------ PASO 1
if ($Paso -eq 1) {
    Titulo "Paso 1: buckets S3, RDS consistente y DynamoDB"
    foreach ($b in $BktO, $BktM) {
        aws s3api head-bucket --bucket $b 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { aws s3 mb "s3://$b" | Out-Null; Ok "bucket $b creado" } else { Ok "bucket $b ya existe" }
    }
    $extra = Psql "SELECT codigo FROM productos WHERE codigo !~ '^(LAP|MON|PER)-' ORDER BY codigo"
    $nExtra = @($extra -split "`n" | Where-Object { $_.Trim() -ne "" }).Count
    Write-Host "`nProductos NO iniciales en RDS (su foto y sus atributos se perdieron con Floci): $nExtra"
    if ($nExtra -gt 0) { Write-Host $extra }
    if (-not $Limpiar) {
        Write-Host "`nSi la lista es correcta, ejecuta de nuevo con -Limpiar." -ForegroundColor Yellow
        return
    }
    Psql "DELETE FROM productos WHERE codigo !~ '^(LAP|MON|PER)-'" | Out-Null
    Psql "UPDATE productos SET estado='PENDIENTE'" | Out-Null
    Ok "RDS: solo los productos iniciales, todos en PENDIENTE"
    & "$PSScriptRoot\cargar-datos.ps1"
    $nR = Psql "SELECT count(*) FROM productos"
    $nD = (aws dynamodb scan --table-name $Tabla --select COUNT --query Count --output text)
    Write-Host "`nProductos en RDS: $nR | Items en DynamoDB: $nD"
    if ($nR -eq $nD) { Ok "RDS y DynamoDB coinciden" } else { Mal "RDS y DynamoDB NO coinciden" }
}

# ------------------------------------------------------------------ PASO 2
if ($Paso -eq 2) {
    Titulo "Paso 2: Lambda $Fn"
    if (-not (Test-Path "lambda\function.zip")) { Mal "Falta lambda\function.zip"; return }
    $trust = Join-Path $env:TEMP "lambda-trust.json"
    [IO.File]::WriteAllText($trust, '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}')
    aws iam create-role --role-name lomax-lambda-role --assume-role-policy-document "file://$trust" 2>$null | Out-Null
    aws lambda delete-function --function-name $Fn 2>$null | Out-Null
    aws lambda create-function --function-name $Fn --runtime python3.12 --handler lambda_function.lambda_handler `
        --role arn:aws:iam::000000000000:role/lomax-lambda-role --zip-file "fileb://lambda/function.zip" `
        --timeout 30 --memory-size 512 `
        --environment "Variables={AWS_ENDPOINT_URL=http://host.docker.internal:4566,TABLE_NAME=$Tabla,MINIATURAS_BUCKET=$BktM}" | Out-Null
    if ($LASTEXITCODE -ne 0) { Mal "No se pudo crear la funcion"; return }
    Ok "funcion creada"

    Write-Host "Prueba de miniatura (la primera invocacion puede tardar por la descarga del runtime)..."
    $id = "prueba-lambda-" + (Get-Date -Format "HHmmss")
    aws s3 cp evidencia\e3\prueba.jpg "s3://$BktO/originales/$id/prueba.jpg" | Out-Null
    $ev = Join-Path $env:TEMP "ev.json"; $out = Join-Path $env:TEMP "salida.json"
    [IO.File]::WriteAllText($ev, ('{"producto_id":"' + $id + '","bucket":"' + $BktO + '","key":"originales/' + $id + '/prueba.jpg"}'))
    aws lambda invoke --function-name $Fn --payload "fileb://$ev" $out | Out-Null
    $res = Get-Content $out -Raw
    Write-Host $res
    if ($res -match "PROCESADO") { Ok "Lambda genero la miniatura" } else { Mal "La Lambda no proceso la imagen (si fue timeout, repite el paso 2)" }
    # limpieza de la prueba
    aws s3 rm "s3://$BktO/originales/$id/" --recursive | Out-Null
    aws s3 rm "s3://$BktM/miniaturas/$id/" --recursive | Out-Null
    $k = Join-Path $env:TEMP "k.json"; [IO.File]::WriteAllText($k, ('{"producto_id":{"S":"' + $id + '"}}'))
    aws dynamodb delete-item --table-name $Tabla --key "file://$k" | Out-Null
}

# ------------------------------------------------------------------ PASO 3
if ($Paso -eq 3) {
    Titulo "Paso 3: ECR e imagenes"
    docker network connect floci-net floci-ecr-registry 2>$null | Out-Null
    foreach ($n in "backend","frontend","proxy") {
        aws ecr describe-repositories --repository-names "lomax-$n" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            aws ecr create-repository --repository-name "lomax-$n" | Out-Null
            if ($LASTEXITCODE -ne 0) { Mal "No se pudo crear el repositorio lomax-$n"; return }
            Ok "repositorio lomax-$n creado"
        } else { Ok "repositorio lomax-$n ya existe" }
    }
    aws ecr get-login-password | docker login --username AWS --password-stdin $Reg
    foreach ($n in "backend","frontend","proxy") {
        $img = "$Reg/lomax-${n}:$Tag"
        docker image inspect $img 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  La imagen $img no existe local: se construye desde .\$n"
            docker build -t $img --label "org.opencontainers.image.revision=$Tag" ".\$n"
        }
        docker push $img
        if ($LASTEXITCODE -ne 0) { Mal "Fallo el push de $img"; return }
    }
    foreach ($n in "backend","frontend","proxy") {
        Write-Host "lomax-$n :"
        aws ecr describe-images --repository-name "lomax-$n" --query "imageDetails[].[imageTags[0],imageDigest]" --output text
    }
}

# ------------------------------------------------------------------ PASO 4
if ($Paso -eq 4) {
    Titulo "Paso 4: cluster EKS lomax-eks"
    docker network connect floci-net $Rds 2>$null | Out-Null
    aws iam create-role --role-name eks-role --assume-role-policy-document file://k8s/eks-trust.json 2>$null | Out-Null
    aws eks create-cluster --name lomax-eks --role-arn arn:aws:iam::000000000000:role/eks-role `
        --resources-vpc-config "subnetIds=subnet-default-us-east-1-a,subnet-default-us-east-1-b,securityGroupIds=sg-default-us-east-1" | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        $st = (aws eks describe-cluster --name lomax-eks --query cluster.status --output text 2>$null)
        if ($st -eq "ACTIVE") { break }
        Start-Sleep -Seconds 5
    }
    Write-Host "Estado del cluster: $st"
    if ($st -ne "ACTIVE") { Mal "El cluster no llego a ACTIVE"; return }
    Start-Sleep -Seconds 10
    $port = (docker port $K3S 6443 | Select-Object -First 1).Split(":")[-1]
    docker exec $K3S cat /etc/rancher/k3s/k3s.yaml | Out-File kubeconfig-lomax.yaml -Encoding ascii
    (Get-Content kubeconfig-lomax.yaml) -replace "https://127.0.0.1:6443","https://127.0.0.1:$port" | Set-Content kubeconfig-lomax.yaml -Encoding ascii
    $env:KUBECONFIG = "$PWD\kubeconfig-lomax.yaml"
    docker network connect floci-net $K3S 2>$null | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        if (kubectl get nodes --no-headers 2>$null | Select-String " Ready") { break }
        Start-Sleep -Seconds 5
    }
    kubectl get nodes -o wide
}

# ------------------------------------------------------------------ PASO 5
if ($Paso -eq 5) {
    Titulo "Paso 5: despliegue en EKS"
    $env:KUBECONFIG = "$PWD\kubeconfig-lomax.yaml"
    kubectl apply -f k8s/config.yaml
    $pw = (docker inspect $Rds --format "{{range .Config.Env}}{{println .}}{{end}}" | Select-String "^POSTGRES_PASSWORD=").ToString().Trim().Split("=",2)[1]
    kubectl create secret generic lomax-db -n lomax --from-literal=DB_PASSWORD="$pw" --dry-run=client -o yaml | kubectl apply -f -
    Remove-Variable pw
    kubectl apply -f k8s/backend.yaml -f k8s/frontend.yaml -f k8s/proxy.yaml
    & "$PSScriptRoot\eks-hosts.ps1"
    kubectl rollout status deployment/frontend -n lomax --timeout=120s
    kubectl rollout status deployment/proxy -n lomax --timeout=120s
    kubectl get pods -n lomax -o wide
    Write-Host "`nPara abrir la app en http://localhost:8090 deja esto corriendo en OTRA ventana:" -ForegroundColor Yellow
    Write-Host "  `$env:KUBECONFIG=`"$Root\kubeconfig-lomax.yaml`"; kubectl port-forward -n lomax svc/proxy 8090:80"
}
