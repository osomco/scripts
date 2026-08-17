# Guía operativa: migración de VMs Azure entre tenants

Esta guía explica el funcionamiento del script
`azure-cross-tenant-vm-migrate.sh` y propone una secuencia controlada para
ejecutarlo. El método utiliza snapshots, SAS temporales y AzCopy para transferir
los discos directamente entre Azure y Azure.

Esta edición corresponde al script **v1.1.0**.

> **Importante:** los bloques que muestran llamadas ARM sirven para entender y
> diagnosticar el proceso. Para la migración real se recomienda usar el script,
> porque controla reintentos, operaciones asíncronas, reanudación y revocación
> de SAS.

## 1. Arquitectura del movimiento

| Componente | Origen | Destino |
| --- | --- | --- |
| Suscripción | `AZPLAN-OSOMCO-CSSA` | `OSOMGROUP-AZPLAN-RESCASA` |
| ID | `b594755a-639d-4f7b-bb29-c01c9397a87a` | `a4ba9883-6dbb-4184-92a2-6da22dac9c01` |
| Tenant | OSOMCO | Cliente |
| Región | `eastus2` | `eastus2` |
| Acceso al destino | Azure Lighthouse | Azure Lighthouse |
| Transferencia | Snapshot SAS → AzCopy → Managed Disk SAS | |

Las suscripciones pertenecen a tenants distintos. Por esa razón no se puede
crear el disco destino directamente con `--source <resource-id>`. AzCopy realiza
una transferencia server-to-server y los datos no pasan por la computadora que
ejecuta el script.

## 2. Alcance

| VM | IP privada | Red destino | Discos | Particularidad |
| --- | --- | --- | ---: | --- |
| `MINFO-VM-P` | `172.17.38.4` | `cdc-vnet-spoke3/cdc-snet-spoke3` | 3 | Piloto; Gen1 |
| `AZINTBK-VM-P` | `172.17.44.100` | `cdc-vnet-spoke4/cdc-snet-spoke4` | 5 | Se migra junto con AZINTCDC |
| `AZINTCDC-VM-P` | `172.17.44.101` | `cdc-vnet-spoke4/cdc-snet-spoke4` | 5 | Se migra junto con AZINTBK |
| `LSR-DB-VM-P` | `172.17.20.4` | `cdc-vnet-spoke1/cdc-snet-spoke1` | 5 | Trusted Launch + VMGS |
| `RECAZSRVHO-VM-P` | `172.22.10.4` | `rec-vnet-spoke1/rec-snet-spoke1` | 3 | Recibe una IP pública nueva |
| `ADCDCDC-VM-P` | `172.17.70.4` | `cdc-vnet-spoke6/cdc-snet-spoke6` | 2 | Controlador de dominio |

Total: **6 VMs y 23 discos, aproximadamente 1.79 TiB**.

Las seis redes destino, incluida `rec-vnet-spoke1`, fueron verificadas en el
grupo de recursos `network-rg-cdc`.

## 3. Qué hace y qué no hace el script

El script sí realiza:

1. Inventario y validaciones previas.
2. Apagado y deallocation de la VM origen.
3. Snapshots completos de todos los discos.
4. Copia cross-tenant de discos mediante AzCopy.
5. Copia de VMGS para `LSR-DB-VM-P` con Trusted Launch.
6. Creación de NSG, NIC, IP privada y, cuando corresponde, IP pública.
7. Pausa obligatoria para que el equipo de redes ejecute el corte.
8. Creación de la VM especializada en destino.
9. Validación, rollback y eliminación controlada de snapshots.

El script no realiza:

- Cambios de VPN, rutas o peerings.
- Eliminación de VMs o discos de origen.
- Eliminación automática de snapshots sin aceptación.
- Recreación automática de backup, Defender, monitorización o SQL IaaS.
- Migración de Confidential VMs.

## 4. Preparación de la terminal

### 4.1 Plataformas soportadas

| Plataforma | Método soportado |
| --- | --- |
| macOS | Bash nativo |
| Windows 10/11 | WSL2 con Ubuntu |
| PowerShell o CMD nativo | **No soportado** |
| Git Bash | No validado; no usar para producción |

El script requiere Bash, `curl`, `jq`, Azure CLI y AzCopy. En Windows debe
ejecutarse dentro de WSL2; las instrucciones y rutas de PowerShell no son
intercambiables con las de Bash.

### 4.2 Descargar y verificar los artefactos en macOS

Descargar la distribución publicada en GitHub a un directorio persistente:

```bash
RUNBOOK_DIR="$HOME/AzureMigrationRunbook"
BASE_URL="https://raw.githubusercontent.com/osomco/scripts/main/azure-vm-cross-tenant-migration"

mkdir -p "$RUNBOOK_DIR"
chmod 700 "$RUNBOOK_DIR"
cd "$RUNBOOK_DIR"

curl --fail --location --remote-name "$BASE_URL/azure-cross-tenant-vm-migrate.sh"
curl --fail --location --remote-name "$BASE_URL/GUIA-MIGRACION-VM-CROSS-TENANT-SCRIPT-v1.1.0.md"
curl --fail --location --remote-name "$BASE_URL/GUIA-MIGRACION-VM-CROSS-TENANT-NOTEBOOK.md"
curl --fail --location --remote-name "$BASE_URL/SHA256SUMS"

SCRIPT="$RUNBOOK_DIR/azure-cross-tenant-vm-migrate.sh"
GUIDE="$RUNBOOK_DIR/GUIA-MIGRACION-VM-CROSS-TENANT-SCRIPT-v1.1.0.md"
NOTEBOOK="$RUNBOOK_DIR/GUIA-MIGRACION-VM-CROSS-TENANT-NOTEBOOK.md"
chmod 700 "$SCRIPT"
shasum -a 256 -c SHA256SUMS
```

La verificación debe mostrar `OK` para los tres artefactos antes de ejecutar el
script. No continuar si falta un archivo o aparece `FAILED`.

Instalar dependencias con Homebrew:

```bash
brew install azure-cli jq azcopy tmux

command -v az jq curl azcopy tmux
az version
azcopy --version
jq --version
```

Para evitar suspensión y conservar la sesión:

```bash
tmux new -s azure-migration
caffeinate -dimsu "$SCRIPT"
```

Dentro de `tmux`, `Ctrl-b d` desconecta la vista sin detener el proceso;
`tmux attach -t azure-migration` vuelve a conectarla. `caffeinate` mantiene
macOS despierto mientras el script esté activo.

### 4.3 Preparar Windows con WSL2 Ubuntu

Desde **PowerShell como administrador**, instalar WSL2 si aún no existe:

```powershell
wsl --install -d Ubuntu
```

Reiniciar Windows si lo solicita y abrir Ubuntu. Dentro de WSL2:

```bash
sudo apt-get update
sudo apt-get install -y curl jq tmux ca-certificates
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

tmpdir="$(mktemp -d)"
curl -L https://aka.ms/downloadazcopy-v10-linux -o "$tmpdir/azcopy.tgz"
tar -xzf "$tmpdir/azcopy.tgz" -C "$tmpdir"
sudo install -m 0755 "$tmpdir"/azcopy_linux_*/azcopy /usr/local/bin/azcopy
rm -f "$tmpdir/azcopy.tgz"

command -v az jq curl azcopy tmux
az version
azcopy --version
jq --version
```

Descargar los artefactos directamente dentro del sistema de archivos Linux:

```bash
RUNBOOK_DIR="$HOME/AzureMigrationRunbook"
BASE_URL="https://raw.githubusercontent.com/osomco/scripts/main/azure-vm-cross-tenant-migration"

mkdir -p "$RUNBOOK_DIR"
chmod 700 "$RUNBOOK_DIR"
cd "$RUNBOOK_DIR"

curl --fail --location --remote-name "$BASE_URL/azure-cross-tenant-vm-migrate.sh"
curl --fail --location --remote-name "$BASE_URL/GUIA-MIGRACION-VM-CROSS-TENANT-SCRIPT-v1.1.0.md"
curl --fail --location --remote-name "$BASE_URL/GUIA-MIGRACION-VM-CROSS-TENANT-NOTEBOOK.md"
curl --fail --location --remote-name "$BASE_URL/SHA256SUMS"

SCRIPT="$RUNBOOK_DIR/azure-cross-tenant-vm-migrate.sh"
GUIDE="$RUNBOOK_DIR/GUIA-MIGRACION-VM-CROSS-TENANT-SCRIPT-v1.1.0.md"
NOTEBOOK="$RUNBOOK_DIR/GUIA-MIGRACION-VM-CROSS-TENANT-NOTEBOOK.md"
chmod 700 "$SCRIPT"
sha256sum -c SHA256SUMS
```

La verificación debe mostrar `OK` para los tres artefactos antes de ejecutar el
script. No continuar si falta un archivo o aparece `FAILED`. Antes de la
ventana, impedir que el host Windows entre en suspensión según la política
corporativa. Una opción temporal en PowerShell elevado es:

```powershell
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change hibernate-timeout-dc 0
```

Mantener el equipo conectado a corriente. Restaurar después los cuatro valores
corporativos. Ejecutar el script dentro de `tmux`:

```bash
tmux new -s azure-migration
"$SCRIPT"
```

Cerrar la ventana de Windows Terminal no debe usarse como mecanismo de
desconexión; usar `Ctrl-b d`.

### 4.4 Autenticación

El script usa el tenant administrador OSOMCO y accede al destino por Lighthouse.

```bash
az login \
  --tenant 11e34461-47a6-46c4-a3ca-720f77590ccc \
  --use-device-code
```

Autenticarse **antes** de entrar en la fase de copia. Los workers paralelos
pueden renovar silenciosamente un token desde la caché de Azure CLI, pero nunca
abrirán un inicio de sesión interactivo. Si la renovación falla, el script se
detiene y conserva los discos ya marcados como `Copied`.

Comprobar la suscripción origen:

```bash
az account show \
  --subscription b594755a-639d-4f7b-bb29-c01c9397a87a \
  --query '{name:name,id:id,tenantId:tenantId,state:state}' \
  --output table
```

Comprobar acceso Lighthouse al destino:

```bash
TOKEN="$(
  az account get-access-token \
    --tenant 11e34461-47a6-46c4-a3ca-720f77590ccc \
    --resource https://management.azure.com/ \
    --query accessToken \
    --output tsv
)"

curl --silent --show-error --fail-with-body \
  --header "Authorization: Bearer $TOKEN" \
  "https://management.azure.com/subscriptions/a4ba9883-6dbb-4184-92a2-6da22dac9c01?api-version=2022-12-01" |
  jq '{displayName,subscriptionId,tenantId,state}'

unset TOKEN
```

Salida esperada:

```json
{
  "displayName": "OSOMGROUP-AZPLAN-RESCASA",
  "subscriptionId": "a4ba9883-6dbb-4184-92a2-6da22dac9c01",
  "tenantId": "494bc003-5c4f-4936-ad7d-b4703f6b86f6",
  "state": "Enabled"
}
```

## 5. Configuración recomendada

Crear un directorio persistente para el estado:

```bash
mkdir -p "$HOME/azure-vm-migration-state"
chmod 700 "$HOME/azure-vm-migration-state"
```

Ejecutar con cuatro copias paralelas y SAS válidos por 12 horas:

```bash
export MIGRATION_STATE_DIR="$HOME/azure-vm-migration-state"
export COPY_CONCURRENCY=4
export SAS_DURATION_SECONDS=43200
```

### 5.1 Tamaños de VM y aprobación obligatoria

La consulta realizada en destino detectó:

- Cuota regional: 50 vCPU, uso 0 en el momento de la revisión.
- Cuota `standardDSv5Family`: 50 vCPU, uso 0.
- `Standard_B2ms` y `Standard_B4ms`: `NotAvailableForSubscription` en `eastus2`.
- `Standard_D2s_v5` y `Standard_D4s_v5`: disponibles para recursos regionales;
  tienen restricciones zonales que no aplican a estas VMs regionales.

El script **no sustituye tamaños automáticamente**. Sin overrides aprobados, el
preflight bloquea las VMs B. Una equivalencia técnica para evaluación del
cliente es:

| VM | Tamaño origen | Alternativa a aprobar |
| --- | --- | --- |
| `MINFO-VM-P` | `Standard_B2ms` | `Standard_D2s_v5` |
| `AZINTBK-VM-P` | `Standard_B2ms` | `Standard_D2s_v5` |
| `AZINTCDC-VM-P` | `Standard_B2ms` | `Standard_D2s_v5` |
| `LSR-DB-VM-P` | `Standard_B4ms` | `Standard_D4s_v5` |
| `RECAZSRVHO-VM-P` | `Standard_B4ms` | `Standard_D4s_v5` |
| `ADCDCDC-VM-P` | `Standard_D2s_v5` | Sin cambio |

Los tamaños D no tienen el modelo de créditos de CPU de B y pueden cambiar
costo/rendimiento. Solo después de aprobación escrita:

```bash
export TARGET_SIZE_MINFO_VM_P=Standard_D2s_v5
export TARGET_SIZE_AZINTBK_VM_P=Standard_D2s_v5
export TARGET_SIZE_AZINTCDC_VM_P=Standard_D2s_v5
export TARGET_SIZE_LSR_DB_VM_P=Standard_D4s_v5
export TARGET_SIZE_RECAZSRVHO_VM_P=Standard_D4s_v5
```

El preflight vuelve a consultar restricciones de SKU, cuota regional y cuota
por familia; los valores anteriores son evidencia puntual, no una garantía de
capacidad futura.

No se copia `licenseType` de forma predeterminada. Si una VM llegara a usar
Azure Hybrid Benefit y el cliente aprueba/licencia ese uso:

```bash
export KEEP_LICENSE_TYPE=1
```

Ejecutar:

```bash
"$SCRIPT"
```

El menú mostrado será:

```text
1) Preflight/inventory for one VM
2) Migrate pilot MINFO-VM-P
3) Migrate internal DB wave (AZINTBK + AZINTCDC)
4) Migrate another selected VM
5) Validate a destination VM
6) Roll back a selected VM
7) Roll back internal DB wave
8) Show migration status
9) Delete accepted VM migration snapshots
10) Test destination disk write policy
0) Exit
```

## 6. Fase 1: preflight

La opción `1` de preflight es de solo lectura respecto de Azure; únicamente
escribe el manifiesto local en `MIGRATION_STATE_DIR`. Debe ejecutarse para las
seis VMs antes de la ventana de cambio.

1. Ejecutar el script.
2. Seleccionar la opción `1`.
3. Seleccionar una VM.
4. Repetir para las seis.

Ejemplo de salida:

```text
Preflight: MINFO-VM-P
  Source power:         PowerState/running
  Destination RG:      MAINFO-RG
  Destination network: cdc-vnet-spoke3/cdc-snet-spoke3
  Private IP:          172.17.38.4
  Disks:               3
  Total provisioned:   191.0 GiB
  Source VM size:      Standard_B2ms
  Target VM size:      Standard_D2s_v5
  Security type:       Standard
  Zone:                Regional
```

El preflight comprueba:

- Acceso a ambas suscripciones.
- Existencia de grupo de recursos y subred destino.
- Disponibilidad de la IP privada.
- Ausencia o presencia de la VM destino.
- Número, tamaño, SKU, LUN y caché de discos.
- Generación, zona y perfil de seguridad.
- NIC, NSG y extensiones del origen.
- Coincidencia entre la IP real de origen y el mapeo estático.
- Disponibilidad del tamaño destino y cuotas regional/familiar.
- Cifrado solo con claves administradas por Microsoft; bloquea ADE y DES.
- Ausencia de referencias a Application Security Groups en NIC/NSG.
- Advertencias de identidad administrada, URI de Boot Diagnostics y licencia.

El inventario confirmado tiene los 23 discos con
`EncryptionAtRestWithPlatformKey`, sin DES ni ADE, y no contiene referencias a
ASG. Las seis VMs no tenían identidad administrada al revisar la configuración.

### 6.1 Prueba de escritura y Azure Policy

La opción `10` **sí modifica temporalmente Azure**. Crea un disco de carga de
1 GiB en el grupo destino seleccionado, solicita y revoca un SAS de escritura,
deshabilita el acceso público y elimina el disco. Sirve para detectar antes de
la ventana bloqueos RBAC o Azure Policy sobre `Upload`/SAS:

```text
10) Test destination disk write policy
```

Confirmación requerida:

```text
CREATE POLICY TEST DISK <VM>
```

Ejecutarla una vez por cada grupo de recursos destino. Verificar al terminar que
no exista ningún recurso con prefijo `migration-policy-test-`.

### 6.2 Archivos generados

Por cada VM se crea:

```text
azure-vm-migration-state/
└── MINFO-VM-P/
    ├── source-vm.json
    ├── source-nic.json
    ├── source-nsg.json
    ├── source-extensions.json
    ├── disks.json
    └── migration.json
```

Inspeccionar el inventario:

```bash
STATE="$HOME/azure-vm-migration-state/MINFO-VM-P"

jq '{
  vmSize: .properties.hardwareProfile.vmSize,
  securityProfile: .properties.securityProfile,
  zones: .zones
}' "$STATE/source-vm.json"

jq '.[] | {
  role,
  lun,
  name: .resource.name,
  sizeGiB: .resource.properties.diskSizeGB,
  sku: .resource.sku.name,
  caching: .config.caching
}' "$STATE/disks.json"
```

## 7. Fase 2: piloto con MINFO-VM-P

### 7.1 Antes de comenzar

Confirmar:

- Ventana de mantenimiento aprobada.
- Propietario de aplicación disponible.
- Equipo de redes preparado para cortar `172.17.38.0/24`.
- Backup o mecanismo de recuperación confirmado.
- Servicios de aplicación detenidos.

### 7.2 Iniciar el piloto

```bash
export MIGRATION_STATE_DIR="$HOME/azure-vm-migration-state"
"$SCRIPT"
```

Seleccionar:

```text
2) Migrate pilot MINFO-VM-P
```

El primer control requiere escribir exactamente:

```text
SERVICES STOPPED MINFO-VM-P
```

No escribir esta frase hasta verificar que las aplicaciones y bases de datos
estén detenidas de forma consistente.

## 8. Qué ocurre después de confirmar el apagado

### 8.1 Deallocate de la VM origen

Conceptualmente se ejecuta:

```bash
az vm deallocate \
  --subscription b594755a-639d-4f7b-bb29-c01c9397a87a \
  --resource-group MAINFO-RG \
  --name MINFO-VM-P
```

Validar manualmente:

```bash
az vm get-instance-view \
  --subscription b594755a-639d-4f7b-bb29-c01c9397a87a \
  --resource-group MAINFO-RG \
  --name MINFO-VM-P \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].code" \
  --output tsv
```

Resultado esperado:

```text
PowerState/deallocated
```

### 8.2 Crear snapshots

Por cada disco se crea un snapshot completo:

```bash
az snapshot create \
  --subscription b594755a-639d-4f7b-bb29-c01c9397a87a \
  --resource-group MAINFO-RG \
  --name mig-minfo-vm-p-00-<timestamp> \
  --source "/subscriptions/.../Microsoft.Compute/disks/<disk-name>" \
  --sku Standard_LRS
```

Los nombres siguen este formato:

```text
mig-<nombre-vm>-<indice-disco>-<timestamp-utc>
```

Ejemplo:

```text
mig-minfo-vm-p-00-20260816T120000Z
```

El índice `00` corresponde al disco del sistema operativo.

### 8.3 Crear el disco vacío en destino

El destino se crea en modo de carga. El tamaño incluye 512 bytes para el footer
del VHD:

```json
{
  "location": "eastus2",
  "sku": {
    "name": "StandardSSD_LRS"
  },
  "properties": {
    "osType": "Windows",
    "hyperVGeneration": "V1",
    "creationData": {
      "createOption": "Upload",
      "uploadSizeBytes": 136367309312
    }
  }
}
```

El script usa ARM REST para el destino debido a que la suscripción se administra
mediante Lighthouse:

```bash
curl --request PUT \
  --header "Authorization: Bearer $TOKEN" \
  --header "Content-Type: application/json" \
  --data-binary @disk-payload.json \
  "https://management.azure.com/subscriptions/a4ba9883-6dbb-4184-92a2-6da22dac9c01/resourceGroups/MAINFO-RG/providers/Microsoft.Compute/disks/<disk-name>?api-version=2025-01-02"
```

### 8.4 Generar SAS temporales

Se obtiene:

- SAS de lectura para el snapshot origen.
- SAS de escritura para el Managed Disk destino.

Petición conceptual:

```json
{
  "access": "Read",
  "durationInSeconds": 43200,
  "fileFormat": "VHD",
  "getSecureVMGuestStateSAS": false
}
```

Los SAS se conservan únicamente en memoria y no deben copiarse en tickets,
mensajes, capturas o logs.

### 8.5 Copiar con AzCopy

El comando principal es:

```bash
azcopy copy \
  "$SOURCE_SNAPSHOT_SAS" \
  "$DESTINATION_DISK_SAS" \
  --blob-type PageBlob \
  --check-length=true \
  --output-type text
```

Los discos de una VM se copian en paralelo. La concurrencia predeterminada es
cuatro:

```bash
export COPY_CONCURRENCY=4
```

Reducirla si aparece throttling:

```bash
export COPY_CONCURRENCY=2
```

### 8.6 Trusted Launch en LSR-DB-VM-P

`LSR-DB-VM-P` tiene Trusted Launch. Su disco OS contiene dos componentes:

1. VHD del sistema operativo.
2. VMGS con Secure Boot y estado de vTPM.

El disco destino se crea con:

```json
{
  "creationData": {
    "createOption": "UploadPreparedSecure",
    "uploadSizeBytes": 136367309312
  },
  "securityProfile": {
    "securityType": "TrustedLaunch"
  }
}
```

La solicitud de SAS usa:

```json
{
  "access": "Read",
  "durationInSeconds": 43200,
  "fileFormat": "VHD",
  "getSecureVMGuestStateSAS": true
}
```

Azure devuelve:

```json
{
  "accessSAS": "<VHD-SAS>",
  "securityDataAccessSAS": "<VMGS-SAS>"
}
```

El script ejecuta dos transferencias:

```bash
azcopy copy "$SOURCE_VHD_SAS" "$DESTINATION_VHD_SAS" \
  --blob-type PageBlob --check-length=true

azcopy copy "$SOURCE_VMGS_SAS" "$DESTINATION_VMGS_SAS" \
  --blob-type PageBlob --check-length=true
```

Si Azure no devuelve ambos SAS de VMGS, el script se detiene y no crea la VM.

### 8.7 Revocar SAS

Después de cada copia se revoca acceso tanto en origen como en destino:

```http
POST <resource-id>/endGetAccess?api-version=2025-01-02
```

El script también intenta revocar los SAS mediante un `trap` si AzCopy falla o
el proceso se interrumpe. A continuación cambia ambos recursos a:

```json
{
  "properties": {
    "networkAccessPolicy": "DenyAll",
    "publicNetworkAccess": "Disabled"
  }
}
```

Si una copia debe reanudarse, el script abre nuevamente el acceso solo para
obtener los SAS y vuelve a cerrarlo al terminar. Revocar el SAS y deshabilitar
el acceso público son controles separados; ambos deben completarse.

## 9. Preparación de red en destino

Después de copiar los discos, el script:

1. Recrea el NSG con las reglas de origen.
2. Crea una NIC.
3. Mantiene la IP privada original.
4. Conserva aceleración, IP forwarding y DNS configurado en la NIC.
5. Para `RECAZSRVHO-VM-P`, crea una IP pública Standard estática nueva.

El script bloquea el despliegue si encuentra referencias a Application Security
Groups. Los IDs de ASG son específicos de la suscripción y no pueden copiarse
literalmente; primero deben crearse ASG equivalentes en destino y añadirse a una
versión futura/aprobada del mapeo.

Ejemplo conceptual de NIC:

```json
{
  "location": "eastus2",
  "properties": {
    "networkSecurityGroup": {
      "id": "/subscriptions/.../networkSecurityGroups/MINFO-NSG"
    },
    "ipConfigurations": [
      {
        "name": "ipconfig1",
        "properties": {
          "primary": true,
          "privateIPAddress": "172.17.38.4",
          "privateIPAllocationMethod": "Static",
          "subnet": {
            "id": "/subscriptions/.../virtualNetworks/cdc-vnet-spoke3/subnets/cdc-snet-spoke3"
          }
        }
      }
    ]
  }
}
```

## 10. Punto de control de red

Cuando discos y NIC estén listos, el script se detiene.

No continuar hasta que el equipo de redes confirme el corte de rutas/VPN de la
subred correspondiente.

Antes de confirmar el corte, comprobar desde un host de prueba en destino que
las dependencias que seguirán temporalmente en origen —especialmente AD y DNS—
son alcanzables por la ruta aprobada. Ejemplo desde Windows:

```powershell
Test-NetConnection <IP-DNS-ORIGEN> -Port 53
Test-NetConnection <IP-DC-ORIGEN> -Port 88
Test-NetConnection <IP-DC-ORIGEN> -Port 389
Test-NetConnection <IP-DC-ORIGEN> -Port 445
Resolve-DnsName <DOMINIO-AD> -Server <IP-DNS-ORIGEN>
```

Repetir después del corte. Si el tránsito destino→origen está bloqueado, no
arrancar una VM que dependa del dominio/DNS hasta corregir el enrutamiento.

Para el piloto, la confirmación requerida es:

```text
NETWORK CUTOVER COMPLETE MINFO-VM-P
```

> **Regla crítica:** origen y destino no deben anunciar simultáneamente el mismo
> prefijo ni deben encenderse a la vez con la misma identidad e IP.

## 11. Creación de la VM destino

Después del corte, el script crea una VM especializada:

- No ejecuta Sysprep.
- No cambia el nombre dentro de Windows.
- Adjunta el disco OS copiado.
- Adjunta discos de datos con sus LUN originales.
- Conserva caché de disco, tags, generación y zona.
- Usa el tamaño destino validado, que puede diferir del tamaño origen mediante
  un override aprobado.
- Conserva Trusted Launch en `LSR-DB-VM-P`.
- Configura `deleteOption: Detach` para proteger los discos.
- Usa Boot Diagnostics administrado por Azure; nunca reutiliza una URI de
  almacenamiento del tenant origen.
- No copia identidades administradas, porque son recursos vinculados al tenant.
- Solo copia `licenseType` con `KEEP_LICENSE_TYPE=1`.

Fragmento conceptual:

```json
{
  "location": "eastus2",
  "properties": {
    "hardwareProfile": {
      "vmSize": "Standard_D2s_v5"
    },
    "storageProfile": {
      "osDisk": {
        "osType": "Windows",
        "createOption": "Attach",
        "deleteOption": "Detach",
        "managedDisk": {
          "id": "/subscriptions/.../disks/<os-disk>"
        }
      },
      "dataDisks": [
        {
          "lun": 0,
          "createOption": "Attach",
          "deleteOption": "Detach",
          "managedDisk": {
            "id": "/subscriptions/.../disks/<data-disk>"
          }
        }
      ]
    }
  }
}
```

## 12. Validación del piloto

En el menú seleccionar:

```text
5) Validate a destination VM
```

Seleccionar `MINFO-VM-P`.

El script comprueba automáticamente:

- Estado `PowerState/running`.
- Cantidad de discos conectados.
- IP privada.

Luego pregunta:

```text
Did Windows boot without critical errors?
Are all volumes and drive letters correct?
Are DNS, domain and required network paths working?
Did the application owner approve the functional test?
Are security, monitoring and backup actions complete?
```

Responder `y` únicamente después de verificar cada punto.

Comandos de apoyo:

```bash
# Estado de la VM destino mediante ARM/Lighthouse
TOKEN="$(
  az account get-access-token \
    --tenant 11e34461-47a6-46c4-a3ca-720f77590ccc \
    --resource https://management.azure.com/ \
    --query accessToken -o tsv
)"

curl --silent --show-error --fail-with-body \
  --header "Authorization: Bearer $TOKEN" \
  "https://management.azure.com/subscriptions/a4ba9883-6dbb-4184-92a2-6da22dac9c01/resourceGroups/MAINFO-RG/providers/Microsoft.Compute/virtualMachines/MINFO-VM-P/instanceView?api-version=2024-11-01" |
  jq '.statuses'

unset TOKEN
```

Después de aceptación, se crea:

```text
$MIGRATION_STATE_DIR/MINFO-VM-P/accepted-at
```

Sin ese archivo el script no permite eliminar snapshots.

### 12.1 VM Agent, extensiones e identidad

La clonación copia el estado del sistema operativo, pero no recrea los recursos
ARM de extensiones ni una identidad administrada del tenant origen. Después del
primer arranque:

```powershell
Get-Service WindowsAzureGuestAgent
Get-Content 'C:\WindowsAzure\Logs\WaAppAgent.log' -Tail 100
```

1. Confirmar que Azure muestre `VM agent status: Ready`.
2. Si el servicio está detenido, iniciarlo y volver a revisar el log:

   ```powershell
   Start-Service WindowsAzureGuestAgent
   ```

3. Si continúa `Not Ready`, no aprobar la VM: corregir conectividad saliente y
   reinstalar/actualizar Azure VM Agent mediante el procedimiento soportado.
4. Recrear deliberadamente MDE, Network Watcher, SQL IaaS, acceso y backup según
   el inventario; no asumir que la metadata de extensión fue clonada.
5. Si el preflight advirtió identidad administrada, crear una identidad nueva en
   destino y reasignar RBAC, Key Vault y permisos de aplicación antes de validar.

## 13. Consultar estado general

En el menú:

```text
8) Show migration status
```

Ejemplo:

```text
VM                   SOURCE                   DESTINATION              DISKS   ACCEPTED
MINFO-VM-P           PowerState/deallocated   PowerState/running       3/3     Yes
AZINTBK-VM-P         PowerState/running       NotCreated               0/5     No
```

## 14. Oleada AZINTBK + AZINTCDC

Estas máquinas comparten `172.17.44.96/27` y no se migran individualmente.

Seleccionar:

```text
3) Migrate internal DB wave (AZINTBK + AZINTCDC)
```

Secuencia:

1. Preflight de ambas VMs.
2. Confirmación de detención de aplicaciones y SQL.
3. Deallocate de ambas.
4. Snapshots de diez discos.
5. Copia de discos de ambas VMs.
6. Creación de ambas NICs.
7. Pausa para cortar `172.17.44.96/27`.
8. Creación y arranque de ambas VMs.

Confirmaciones:

```text
SERVICES STOPPED AZINT DATABASE WAVE
NETWORK CUTOVER COMPLETE AZINT DATABASE WAVE
```

## 15. Resto de oleadas

Después de aprobar el piloto:

### 15.1 LSR-DB-VM-P

```text
4) Migrate another selected VM
4) LSR-DB-VM-P
```

Validar específicamente:

- Secure Boot.
- vTPM.
- Arranque de Windows.
- Discos SQL y letras.
- Bases online.
- Jobs, logins y respaldos.
- SQL IaaS Agent.

### 15.2 RECAZSRVHO-VM-P

```text
4) Migrate another selected VM
5) RECAZSRVHO-VM-P
```

Después del despliegue:

- Registrar la IP pública nueva.
- Actualizar DNS público.
- Actualizar allowlists y firewalls.
- Revisar certificados o dependencias de IP.

### 15.3 ADCDCDC-VM-P

Antes de ejecutar:

```powershell
dcdiag /v
repadmin /replsummary
repadmin /showrepl
```

Crear un backup actual de System State.

Antes de aprobar la oleada, documentar cuántos DC/DNS operativos existen en el
dominio y dónde están. Decisión obligatoria:

- Si existe otro DC saludable y replicando, mantenerlo disponible durante el
  corte y validar que clientes destino puedan alcanzarlo.
- Si `ADCDCDC-VM-P` es el único DC o no hay replicación saludable, la opción
  preferida es crear/promover un DC nuevo en destino; el clon requiere una
  excepción de riesgo aprobada por el propietario de AD.
- Confirmar soporte de VM-Generation ID en hipervisor/SO y que nunca puedan
  arrancar simultáneamente origen y destino.

En el menú:

```text
4) Migrate another selected VM
6) ADCDCDC-VM-P
```

El script exige:

```text
AD HEALTH AND SYSTEM STATE VERIFIED ADCDCDC-VM-P
SERVICES STOPPED ADCDCDC-VM-P
```

Después del arranque:

```powershell
dcdiag /v
repadmin /replsummary
repadmin /showrepl
net share
```

Comprobar `SYSVOL`, `NETLOGON`, DNS y eventos de Directory Service.

Si no se puede confirmar VM-Generation ID o la salud de AD, no clonar el DC:
desplegar una VM nueva y promoverla como controlador de dominio.

## 16. Reanudación después de un error

El estado persiste en `MIGRATION_STATE_DIR`.

Cada disco tiene un archivo:

```text
disk-0-state.json
disk-1-state.json
...
```

Ejemplo:

```json
{
  "snapshotId": "/subscriptions/.../snapshots/mig-minfo-vm-p-00-...",
  "destinationDiskId": "/subscriptions/.../disks/MINFO-VM-P_OsDisk_...",
  "status": "Copied",
  "completedAt": "2026-08-16T12:45:00Z"
}
```

Al volver a ejecutar:

- Un snapshot existente se reutiliza.
- Un disco con estado `Copied` no se transfiere otra vez.
- Un disco destino `Unattached` sin marca `Copied` se elimina y se recrea.
- Un SAS todavía abierto se intenta revocar al salir.

No eliminar manualmente el directorio de estado durante la migración.

Estas reglas de reanudación solo aplican mientras el origen permanece
deallocated y no ha vuelto a prestar servicio. Después de un rollback, los datos
del origen pueden haber cambiado: el script escribe `rolled-back-at` y prohíbe
reutilizar los snapshots/discos anteriores.

## 17. Rollback

### 17.1 Rollback de una VM individual

Seleccionar:

```text
6) Roll back a selected VM
```

El script:

1. Exige escribir `ROLLBACK <VM>`.
2. Deallocate de la VM destino.
3. Se detiene para que redes regrese el prefijo al origen.
4. Exige `SOURCE NETWORK RESTORED <VM>`.
5. Enciende la VM origen.
6. Conserva discos y snapshots destino para análisis.
7. Escribe `rolled-back-at` e invalida la reanudación anterior.

Ejemplo:

```text
ROLLBACK MINFO-VM-P
SOURCE NETWORK RESTORED MINFO-VM-P
```

### 17.2 Rollback de la oleada interna

Seleccionar:

```text
7) Roll back internal DB wave
```

Confirmaciones:

```text
ROLLBACK AZINT DATABASE WAVE
SOURCE NETWORK RESTORED AZINT DATABASE WAVE
```

Esto revierte conjuntamente `AZINTBK-VM-P` y `AZINTCDC-VM-P`.

### 17.3 Reintentar después de rollback

Al seleccionar nuevamente una migración marcada como `RolledBack`, el script
explica que eliminará permanentemente la VM destino obsoleta, sus discos, los
snapshots de migración y los marcadores `Copied`. Exige por cada VM:

```text
RESET STALE MIGRATION <VM>
```

Solo después crea un `run-id` y snapshots finales nuevos. No borrar
`rolled-back-at` manualmente para evitar esta protección.

Para `ADCDCDC-VM-P`, el rollback añade una confirmación previa:

```text
AD ROLLBACK APPROVED ADCDCDC-VM-P
```

Debe existir aprobación del propietario de AD y una decisión sobre qué DC
contiene los cambios autoritativos posteriores al corte. Un rollback no debe
introducir divergencia de replicación ni pérdida silenciosa de cambios.

## 18. Limpieza

Solo después de:

- Aceptación técnica.
- Aceptación del propietario de aplicación.
- Cierre del periodo de rollback.
- Autorización formal del cliente.

Seleccionar:

```text
9) Delete accepted VM migration snapshots
```

Confirmar:

```text
DELETE MIGRATION SNAPSHOTS <VM>
```

La opción elimina únicamente los snapshots temporales de esa migración.

No elimina:

- VM origen.
- Discos origen.
- NIC origen.
- VM destino.
- Discos destino.

La eliminación de recursos origen debe realizarse mediante un proceso posterior
y con una autorización separada.

## 19. Comprobaciones posteriores por VM

### Azure

- VM en `running`.
- Aprovisionamiento `Succeeded`.
- Todos los discos conectados.
- LUN, caché, SKU y tamaño correctos.
- Boot Diagnostics.
- VM Agent operativo.

### Windows

- Sin discos offline.
- Letras de unidad correctas.
- Hora y zona horaria.
- Activación.
- Pertenencia al dominio.
- Servicios automáticos iniciados.
- Eventos críticos revisados.

### Red

- IP privada esperada.
- DNS directo e inverso.
- NSG correcto.
- Rutas efectivas.
- Acceso a sedes y dependencias.
- Sin anuncio simultáneo del prefijo origen/destino.

### Operación

- Microsoft Defender for Endpoint.
- Monitorización y alertas.
- Backup.
- SQL IaaS Agent cuando corresponda.
- CMDB e inventario.
- Azure VM Agent en `Ready` y extensiones recreadas en `Succeeded`.
- Identidades administradas nuevas con sus permisos de destino, si aplican.
- Snapshots y discos con `publicNetworkAccess: Disabled` y
  `networkAccessPolicy: DenyAll` después de la copia.

## 20. Problemas frecuentes

### `azcopy` no existe

```bash
brew install azcopy
```

### Sesión de Azure expirada

```bash
az login \
  --tenant 11e34461-47a6-46c4-a3ca-720f77590ccc \
  --use-device-code
```

No intentar iniciar sesión desde un worker. Salir del script, renovar en la
terminal principal y volver a ejecutarlo; los discos `Copied` se reutilizan.

### Tamaño no disponible o cuota insuficiente

No omitir el bloqueo. Obtener aprobación del tamaño alternativo, exportar la
variable `TARGET_SIZE_<VM>` correspondiente y repetir el preflight. Si la suma
de uso actual y vCPU requeridas supera la cuota regional o familiar, solicitar
el aumento antes de la ventana.

### La prueba de Azure Policy falla

No iniciar la copia. Guardar el código/mensaje ARM, revisar asignaciones Deny,
RBAC y políticas que impidan discos `Upload`, SAS o acceso público temporal.
Repetir la opción `10` hasta que cree, conceda/revoque SAS, cierre acceso y
elimine el disco correctamente.

### La IP privada ya está ocupada

No continuar. Identificar la NIC:

```bash
az graph query --query "
Resources
| where type =~ 'microsoft.network/networkinterfaces'
| mv-expand ipconfig=properties.ipConfigurations
| where tostring(ipconfig.properties.privateIPAddress) == '172.17.38.4'
| project name, resourceGroup, subscriptionId, id
"
```

### Throttling o copia lenta

Cerrar el script y reejecutar con menos concurrencia:

```bash
export COPY_CONCURRENCY=2
"$SCRIPT"
```

El estado persistente evita repetir discos ya completados.

### Trusted Launch no devuelve VMGS

No continuar con `LSR-DB-VM-P`. El script se detiene para evitar perder el estado
de vTPM. Revisar permisos, API de Compute y soporte del disco antes de reintentar.

### Error antes del corte de red

La VM origen permanece deallocated y los discos destino pueden reanudarse. No
es necesario activar rollback de red si el prefijo todavía apunta al origen.

### Error después del corte de red

Usar la opción de rollback correspondiente. Primero se apaga destino, luego
redes restaura el prefijo y finalmente se enciende origen.

## 21. Secuencia recomendada completa

```text
Día previo:
  1. Copiar artefactos a ruta estable y registrar SHA-256.
  2. Aprobar/exportar tamaños destino.
  3. Ejecutar opción 10 por cada grupo destino.
  4. Preflight de las seis VMs.
  5. Revisión de inventarios y dependencias AD/DNS.
  6. Confirmación del runbook de red.
  7. Confirmación de responsables de aplicación.

Piloto:
  1. Opción 2: MINFO-VM-P.
  2. Corte de red del spoke3.
  3. Opción 5: validar MINFO.
  4. Aceptación del piloto.

Producción:
  1. Opción 3: AZINTBK + AZINTCDC.
  2. Opción 5: validar ambas.
  3. Opción 4: LSR-DB-VM-P.
  4. Opción 5: validar LSR.
  5. Opción 4: RECAZSRVHO-VM-P.
  6. Opción 5: validar RECAZ.
  7. Opción 4: ADCDCDC-VM-P.
  8. Opción 5: validar AD.

Cierre:
  1. Mantener origen apagado durante el periodo de rollback.
  2. Obtener aceptación formal.
  3. Opción 9: eliminar snapshots por VM.
  4. Retirar origen mediante un cambio separado.
```

## 22. Regla de seguridad principal

En ningún momento deben estar activas simultáneamente la VM origen y la VM
destino con el mismo nombre e IP. El orden siempre es:

```text
Apagar origen
    ↓
Crear y copiar snapshots
    ↓
Crear NIC destino
    ↓
Cortar red hacia destino
    ↓
Encender destino
```

Para rollback:

```text
Apagar destino
    ↓
Restaurar red hacia origen
    ↓
Encender origen
```
