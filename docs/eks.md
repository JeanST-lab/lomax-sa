# Despliegue y validación en EKS (Etapa 7)

Guía reproducible. Todos los comandos son de PowerShell y se ejecutan desde la raíz del
proyecto. Cada bloque puede grabarse con `Start-Transcript -Path evidencia\e7\<nombre>.txt`.

> **Antes de empezar:** Floci debe estar corriendo con su volumen de datos. No ejecutes
> `floci stop`, `docker rm floci` ni `docker volume prune`: perderías ECR, DynamoDB, S3 y Lambda.

## 0. Variables de la sesión

Cada ventana nueva de PowerShell necesita estas variables:

```powershell
$env:AWS_ENDPOINT_URL = "http://localhost:4566"
$env:AWS_ACCESS_KEY_ID = "test"
$env:AWS_SECRET_ACCESS_KEY = "test"
$env:AWS_DEFAULT_REGION = "us-east-1"
$env:KUBECONFIG = "$PWD\kubeconfig-lomax.yaml"
```

## 1. Redes y comprobaciones

El nodo de EKS, Floci, el registro de ECR y PostgreSQL deben compartir la red `floci-net`:

```powershell
docker network create floci-net
docker network connect floci-net floci
docker network connect floci-net floci-ecr-registry
docker network connect floci-net lomax-rds-local
docker network inspect floci-net --format "{{range .Containers}}{{.Name}} {{end}}"
kubectl version --client
```

Usuario y base de PostgreSQL (`postgres` y `lomax_db`) deben coincidir con `k8s/config.yaml`:

```powershell
docker inspect lomax-rds-local --format "{{range .Config.Env}}{{println .}}{{end}}" | Select-String "POSTGRES_USER|POSTGRES_DB"
```

## 2. Imágenes en ECR

El login al registro solo funciona si `floci` y `floci-ecr-registry` están en `floci-net`:

```powershell
$reg = "000000000000.dkr.ecr.us-east-1.localhost:4566"
$sha = git rev-parse --short HEAD        # las imágenes publicadas usan 8154c29
aws ecr get-login-password | docker login --username AWS --password-stdin $reg

foreach ($n in "backend","frontend","proxy") {
  docker build -t "${reg}/lomax-${n}:${sha}" --label "org.opencontainers.image.revision=$sha" ./$n
  docker push "${reg}/lomax-${n}:${sha}"
}
aws ecr describe-images --repository-name lomax-backend --query "imageDetails[].[imageTags,imageDigest]" --output json
```

Los manifiestos de `k8s/` referencian el tag `8154c29`. Si publicas otro tag, actualiza los
tres archivos `k8s/*.yaml`.

## 3. Crear el clúster EKS

```powershell
aws iam create-role --role-name eks-role --assume-role-policy-document file://k8s/eks-trust.json

aws eks create-cluster --name lomax-eks `
  --role-arn arn:aws:iam::000000000000:role/eks-role `
  --resources-vpc-config "subnetIds=subnet-default-us-east-1-a,subnet-default-us-east-1-b,securityGroupIds=sg-default-us-east-1"

Start-Sleep -Seconds 30
aws eks describe-cluster --name lomax-eks --query "cluster.{Nombre:name,Estado:status,Version:version}"
docker ps --filter "name=floci-eks"
```

Floci valida que las subnets existan; las de la VPC por defecto se listan con
`aws ec2 describe-subnets`. Espera el estado `ACTIVE`.

## 4. Conectar kubectl

El kubeconfig se extrae del contenedor k3s y se apunta al puerto publicado en el equipo:

```powershell
$K3S = "floci-eks-lomax-eks"
$port = (docker port $K3S 6443 | Select-Object -First 1).Split(":")[-1]
docker exec $K3S cat /etc/rancher/k3s/k3s.yaml | Out-File kubeconfig-lomax.yaml -Encoding ascii
(Get-Content kubeconfig-lomax.yaml) -replace "https://127.0.0.1:6443","https://127.0.0.1:$port" | Set-Content kubeconfig-lomax.yaml -Encoding ascii
$env:KUBECONFIG = "$PWD\kubeconfig-lomax.yaml"

docker network connect floci-net $K3S
kubectl get nodes -o wide
kubectl get pods -A
```

`kubeconfig-lomax.yaml` contiene credenciales de administrador: debe estar en `.gitignore`.

## 5. Configuración, Secret y despliegue

```powershell
kubectl apply -f k8s/config.yaml

# El Secret se crea desde el contenedor de PostgreSQL; la contraseña no se imprime ni se versiona
$pw = (docker inspect lomax-rds-local --format "{{range .Config.Env}}{{println .}}{{end}}" | Select-String "^POSTGRES_PASSWORD=").ToString().Trim().Split("=",2)[1]
kubectl create secret generic lomax-db -n lomax --from-literal=DB_PASSWORD="$pw" --dry-run=client -o yaml | kubectl apply -f -
Remove-Variable pw

kubectl apply -f k8s/backend.yaml -f k8s/frontend.yaml -f k8s/proxy.yaml
Start-Sleep -Seconds 45
kubectl get pods -n lomax -o wide
kubectl get events -n lomax --sort-by=.lastTimestamp | Select-Object -Last 15
```

Los eventos `Pulling image` y `Successfully pulled image` con el registro
`000000000000.dkr.ecr.us-east-1.localhost:4566` acreditan la descarga desde ECR.

## 6. Acceso desde los Pods a RDS, DynamoDB y S3

Desde los Pods no se resuelven los nombres de los contenedores de Docker. El script escribe las
IP actuales en el ConfigMap y reinicia el backend:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\eks-hosts.ps1
```

Ejecútalo de nuevo cada vez que se reinicien `floci` o `lomax-rds-local`.

Entrada de usuarios (el proxy sigue siendo la única puerta):

```powershell
Start-Process kubectl -ArgumentList "port-forward -n lomax svc/proxy 8090:80" -WindowStyle Hidden
curl.exe -s -o NUL -w "Frontend HTTP %{http_code}`n" http://localhost:8090/
curl.exe -s http://localhost:8090/api/categorias
```

La aplicación queda en `http://localhost:8090/#/`.

## 7. Verificaciones de E7

### 7.1 Las imágenes en ejecución son las de ECR

```powershell
kubectl get pods -n lomax -o custom-columns="POD:.metadata.name,IMAGE:.spec.containers[0].image,IMAGEID:.status.containerStatuses[0].imageID"
foreach ($r in "backend","frontend","proxy") { "$r ECR: " + (aws ecr describe-images --repository-name lomax-$r --query "imageDetails[0].imageDigest" --output text) }
```

Los `sha256:` de `IMAGEID` deben coincidir con los de ECR.

### 7.2 Escalar el backend de 1 a 3 réplicas

```powershell
kubectl scale deployment/backend -n lomax --replicas=3
kubectl rollout status deployment/backend -n lomax --timeout=120s
kubectl get pods -n lomax -l app=backend -o wide

# 60 solicitudes marcadas con ?lote=e7 y conteo por Pod desde sus logs
1..60 | ForEach-Object { curl.exe -s -o NUL "http://localhost:8090/api/categorias?lote=e7&n=$_" }
foreach ($p in (kubectl get pods -n lomax -l app=backend -o name)) {
  "{0} : {1}" -f $p, @(kubectl logs -n lomax $p | Select-String "lote=e7").Count
}
```

### 7.3 Eliminar un Pod y comparar UID

```powershell
kubectl get pods -n lomax -l app=backend -o custom-columns="POD:.metadata.name,UID:.metadata.uid"
$victima = kubectl get pods -n lomax -l app=backend -o jsonpath="{.items[0].metadata.name}"
$uidAntes = kubectl get pod $victima -n lomax -o jsonpath="{.metadata.uid}"
kubectl delete pod $victima -n lomax
kubectl wait --for=condition=Ready pod -l app=backend -n lomax --timeout=90s
kubectl get pods -n lomax -l app=backend -o custom-columns="POD:.metadata.name,UID:.metadata.uid"
```

Las condiciones `if/else` de PowerShell deben escribirse en **una sola línea** cuando se pegan
en la consola.

### 7.4 Registrar un producto desde EKS

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\e7_registro.ps1
```

El script registra `EKS-E7-001` por el proxy, sube la foto, y muestra el detalle, la fila de RDS,
el item de DynamoDB, los objetos de S3 y la comparación de hashes. Si el código ya existe,
reutiliza el producto: no duplica.

### 7.5 Recrear todos los Pods y repetir las consultas

```powershell
Get-Process kubectl -ErrorAction SilentlyContinue | Stop-Process -Force
kubectl delete pods --all -n lomax
foreach ($d in "backend","frontend","proxy") { kubectl rollout status deployment/$d -n lomax --timeout=120s }
Start-Process kubectl -ArgumentList "port-forward -n lomax svc/proxy 8090:80" -WindowStyle Hidden
Start-Sleep -Seconds 6

$all = Invoke-RestMethod "http://localhost:8090/api/productos"   # guardar antes de usar .Count
"Productos en el catalogo: " + $all.Count
```

En Windows PowerShell 5.1 hay que guardar el resultado de `Invoke-RestMethod` en una variable
antes de contar: envolver la llamada en `@(...)` devuelve siempre `1`.

Después verifica que el producto sigue `PUBLICADO`, con la misma fila en RDS, el mismo item en
DynamoDB y el mismo hash de miniatura que antes de recrear los Pods.

## Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| `Unable to parse config file` | `~/.aws/config` con `[default]` duplicado | Reescribir el archivo con un único `[default]` |
| `Subnet ID ... does not exist` | IDs de subnet inventados | Usar los de `aws ec2 describe-subnets` |
| Login a ECR da 503 o 404 | `floci` no alcanza el registro de respaldo | Conectar `floci` y `floci-ecr-registry` a `floci-net` |
| `InvalidAccessKeyId` o `security token invalid` | Ventana nueva sin variables `AWS_*` | Definir las variables de la sección 0 |
| Backend responde 503 con `"paso":"rds"` | Los Pods no resuelven `lomax-rds-local` | Ejecutar `scripts/eks-hosts.ps1` |
| `else` no se reconoce | `if/else` pegado en dos líneas | Escribirlo en una sola línea |
| Conexión rechazada en `localhost:8090` | El `port-forward` murió al recrear Pods | Reabrirlo con `kubectl port-forward` |
