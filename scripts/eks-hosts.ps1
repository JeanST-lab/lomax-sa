# Apunta el ConfigMap de EKS a las IP actuales de RDS y FLOCI en la red floci-net.
# Ejecutar de nuevo si se reinician esos contenedores. Requiere KUBECONFIG definido.
$rds = ((docker inspect lomax-rds-local --format "{{json .NetworkSettings.Networks}}" | ConvertFrom-Json).'floci-net').IPAddress
$flo = ((docker inspect floci --format "{{json .NetworkSettings.Networks}}" | ConvertFrom-Json).'floci-net').IPAddress
if (-not $rds -or -not $flo) { throw "No se encontraron las IP en floci-net" }
"RDS=$rds  FLOCI=$flo"
@{ data = @{ DB_HOST = $rds; AWS_ENDPOINT_URL = "http://${flo}:4566" } } | ConvertTo-Json -Compress | Set-Content "$env:TEMP\lomax-patch.json" -Encoding ascii
kubectl patch configmap lomax-config -n lomax --type merge --patch-file "$env:TEMP\lomax-patch.json"
kubectl rollout restart deployment/backend -n lomax
kubectl rollout status deployment/backend -n lomax --timeout=120s
