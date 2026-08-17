# Runbook tipo notebook: migración manual de VMs Azure entre tenants

Esta guía permite ejecutar la migración **comando por comando**, sin depender
del script interactivo. Cada bloque se trata como una celda de notebook:
ejecute una celda, revise su salida y continúe únicamente si coincide con el
resultado esperado.

El método es:

```text
VM origen apagada y deallocated
  → snapshots consistentes
  → SAS temporales
  → AzCopy server-to-server
  → Managed Disks destino
  → NIC y VM especializada
  → corte de red
  → validación
```

> **Reglas críticas**
>
> 1. Use una única terminal persistente: las celdas posteriores utilizan las
>    variables exportadas por las anteriores.
> 2. Migre una VM por vez, excepto `AZINTBK-VM-P` y `AZINTCDC-VM-P`, que forman
>    una oleada coordinada.
> 3. Nunca encienda origen y destino simultáneamente con el mismo nombre/IP.
> 4. Deténgase ante cualquier salida inesperada. No adapte un comando durante la
>    ventana sin revisar el estado de Azure.
> 5. Los SAS son secretos. No active `set -x`, no los copie a tickets y no los
>    guarde en archivos persistentes.
> 6. Después de un rollback, nunca reutilice snapshots ni discos copiados antes
>    de volver a encender el origen.

La copia con AzCopy es Azure-a-Azure; los datos no pasan por la computadora del
operador. Microsoft documenta el patrón de direct upload, el incremento
obligatorio de 512 bytes y la revocación del SAS antes de adjuntar el disco:
[Upload a VHD or copy a managed disk with Azure CLI](https://learn.microsoft.com/azure/virtual-machines/linux/disks-upload-vhd-to-managed-disk-cli).

## Descargar y verificar este runbook

Descargue la distribución desde GitHub a un directorio persistente. El script y
su guía se incluyen para que el manifiesto completo pueda verificarse, pero este
notebook sigue siendo independiente: no requiere ejecutar el script.

En macOS:

```bash
RUNBOOK_DIR="$HOME/AzureMigrationRunbook"
BASE_URL="https://raw.githubusercontent.com/osomco/scripts/main/cross-tenant-vm-copy"

mkdir -p "$RUNBOOK_DIR"
chmod 700 "$RUNBOOK_DIR"
cd "$RUNBOOK_DIR"

curl --fail --location --remote-name "$BASE_URL/azure-cross-tenant-vm-migrate.sh"
curl --fail --location --remote-name "$BASE_URL/GUIA-MIGRACION-VM-CROSS-TENANT-SCRIPT-v1.1.0.md"
curl --fail --location --remote-name "$BASE_URL/GUIA-MIGRACION-VM-CROSS-TENANT-NOTEBOOK.md"
curl --fail --location --remote-name "$BASE_URL/SHA256SUMS"
chmod 700 azure-cross-tenant-vm-migrate.sh
grep -E ' (azure-cross-tenant-vm-migrate\.sh|GUIA-MIGRACION-VM-CROSS-TENANT-SCRIPT-v1\.1\.0\.md|GUIA-MIGRACION-VM-CROSS-TENANT-NOTEBOOK\.md)$' SHA256SUMS | shasum -a 256 -c -
```

En WSL2 Ubuntu o Linux:

```bash
RUNBOOK_DIR="$HOME/AzureMigrationRunbook"
BASE_URL="https://raw.githubusercontent.com/osomco/scripts/main/cross-tenant-vm-copy"

mkdir -p "$RUNBOOK_DIR"
chmod 700 "$RUNBOOK_DIR"
cd "$RUNBOOK_DIR"

curl --fail --location --remote-name "$BASE_URL/azure-cross-tenant-vm-migrate.sh"
curl --fail --location --remote-name "$BASE_URL/GUIA-MIGRACION-VM-CROSS-TENANT-SCRIPT-v1.1.0.md"
curl --fail --location --remote-name "$BASE_URL/GUIA-MIGRACION-VM-CROSS-TENANT-NOTEBOOK.md"
curl --fail --location --remote-name "$BASE_URL/SHA256SUMS"
chmod 700 azure-cross-tenant-vm-migrate.sh
grep -E ' (azure-cross-tenant-vm-migrate\.sh|GUIA-MIGRACION-VM-CROSS-TENANT-SCRIPT-v1\.1\.0\.md|GUIA-MIGRACION-VM-CROSS-TENANT-NOTEBOOK\.md)$' SHA256SUMS | sha256sum -c -
```

La verificación debe mostrar `OK` para los tres artefactos. No ejecute ninguna
celda si falta un archivo o aparece `FAILED`.

## 0. Inventario aprobado

| VM | RG origen/destino | IP | Red destino | Tamaño destino propuesto | Discos |
| --- | --- | --- | --- | --- | ---: |
| `MINFO-VM-P` | `MAINFO-RG` | `172.17.38.4` | `cdc-vnet-spoke3/cdc-snet-spoke3` | `Standard_D2s_v5` | 3 |
| `AZINTBK-VM-P` | `INTBK-RG` | `172.17.44.100` | `cdc-vnet-spoke4/cdc-snet-spoke4` | `Standard_D2s_v5` | 5 |
| `AZINTCDC-VM-P` | `INTCDC-RG` | `172.17.44.101` | `cdc-vnet-spoke4/cdc-snet-spoke4` | `Standard_D2s_v5` | 5 |
| `LSR-DB-VM-P` | `LSRDB-PROD-RG` | `172.17.20.4` | `cdc-vnet-spoke1/cdc-snet-spoke1` | `Standard_D4s_v5` | 5 |
| `RECAZSRVHO-VM-P` | `RECAZSRVHO-RG` | `172.22.10.4` | `rec-vnet-spoke1/rec-snet-spoke1` | `Standard_D4s_v5` | 3 |
| `ADCDCDC-VM-P` | `VMADDSCDC-PRO-RG` | `172.17.70.4` | `cdc-vnet-spoke6/cdc-snet-spoke6` | `Standard_D2s_v5` | 2 |

Total: **6 VMs, 23 discos, aproximadamente 1.79 TiB**.

`Standard_B2ms` y `Standard_B4ms` estaban restringidos en la suscripción
destino al momento de la revisión. Los tamaños D son propuestas y requieren
aprobación explícita de costo/rendimiento. Todas las redes destino, incluida
`rec-vnet-spoke1`, se verificaron en `network-rg-cdc`.

---

## 1. Preparar la terminal

### Celda 1A — macOS

Ejecute esta variante únicamente en macOS:

```bash
brew install azure-cli jq azcopy tmux
command -v az jq curl azcopy tmux
az version
azcopy --version
```

Inicie una terminal persistente:

```bash
tmux new -s azure-migration
```

Ya dentro de `tmux`, impida la suspensión mientras viva esta terminal:

```bash
caffeinate -dimsu -w $$ &
echo "caffeinate PID: $!"
```

Use `Ctrl-b d` para desconectarse de `tmux` y:

```bash
tmux attach -t azure-migration
```

para volver.

### Celda 1B — Windows con WSL2 Ubuntu

PowerShell/CMD nativo y Git Bash no están soportados para este runbook. Instale
WSL2 desde PowerShell elevado:

```powershell
wsl --install -d Ubuntu
```

Dentro de Ubuntu/WSL2:

```bash
sudo apt-get update
sudo apt-get install -y curl jq tmux ca-certificates
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

AZCOPY_TMP="$(mktemp -d)"
curl -L https://aka.ms/downloadazcopy-v10-linux -o "$AZCOPY_TMP/azcopy.tgz"
tar -xzf "$AZCOPY_TMP/azcopy.tgz" -C "$AZCOPY_TMP"
sudo install -m 0755 "$AZCOPY_TMP"/azcopy_linux_*/azcopy /usr/local/bin/azcopy
rm -rf "$AZCOPY_TMP"

command -v az jq curl azcopy tmux
az version
azcopy --version
```

En PowerShell elevado, impida temporalmente suspensión e hibernación:

```powershell
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change hibernate-timeout-dc 0
```

Mantenga el equipo conectado a corriente y restaure después los valores
corporativos. Dentro de WSL2:

```bash
tmux new -s azure-migration
```

---

## 2. Variables globales

### Celda 2 — Configuración de la sesión

Ejecute una vez al inicio de la terminal:

```bash
set -euo pipefail
umask 077

export SOURCE_SUBSCRIPTION="b594755a-639d-4f7b-bb29-c01c9397a87a"
export DESTINATION_SUBSCRIPTION="a4ba9883-6dbb-4184-92a2-6da22dac9c01"
export MANAGING_TENANT="11e34461-47a6-46c4-a3ca-720f77590ccc"
export DESTINATION_TENANT="494bc003-5c4f-4936-ad7d-b4703f6b86f6"
export LOCATION="eastus2"
export NETWORK_RG="network-rg-cdc"

export VM_API="2024-11-01"
export DISK_API="2025-01-02"
export NETWORK_API="2024-05-01"
export RESOURCES_API="2021-04-01"
export SUBSCRIPTIONS_API="2022-12-01"
export SKU_API="2021-07-01"
export USAGE_API="2024-11-01"
export SAS_SECONDS="43200"

export ARM="https://management.azure.com"
export WORKDIR="$HOME/azure-vm-migration-notebook"
mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"

printf 'Directorio de trabajo: %s\n' "$WORKDIR"
```

**Esperado:** se imprime una ruta bajo su directorio personal.

---

## 3. Seleccionar una VM

Ejecute **exactamente una** de las siguientes celdas. Estas variables son
deliberadamente visibles para que el operador compruebe el mapeo.

### Celda 3A — MINFO-VM-P, piloto

```bash
export VM="MINFO-VM-P"
export SOURCE_RG="MAINFO-RG"
export DESTINATION_RG="MAINFO-RG"
export VNET="cdc-vnet-spoke3"
export SUBNET="cdc-snet-spoke3"
export PRIVATE_IP="172.17.38.4"
export TARGET_SIZE="Standard_D2s_v5"
export EXPECTED_DISKS="3"
export NEEDS_PUBLIC_IP="false"
```

### Celda 3B — AZINTBK-VM-P

```bash
export VM="AZINTBK-VM-P"
export SOURCE_RG="INTBK-RG"
export DESTINATION_RG="INTBK-RG"
export VNET="cdc-vnet-spoke4"
export SUBNET="cdc-snet-spoke4"
export PRIVATE_IP="172.17.44.100"
export TARGET_SIZE="Standard_D2s_v5"
export EXPECTED_DISKS="5"
export NEEDS_PUBLIC_IP="false"
```

### Celda 3C — AZINTCDC-VM-P

```bash
export VM="AZINTCDC-VM-P"
export SOURCE_RG="INTCDC-RG"
export DESTINATION_RG="INTCDC-RG"
export VNET="cdc-vnet-spoke4"
export SUBNET="cdc-snet-spoke4"
export PRIVATE_IP="172.17.44.101"
export TARGET_SIZE="Standard_D2s_v5"
export EXPECTED_DISKS="5"
export NEEDS_PUBLIC_IP="false"
```

### Celda 3D — LSR-DB-VM-P, Trusted Launch

```bash
export VM="LSR-DB-VM-P"
export SOURCE_RG="LSRDB-PROD-RG"
export DESTINATION_RG="LSRDB-PROD-RG"
export VNET="cdc-vnet-spoke1"
export SUBNET="cdc-snet-spoke1"
export PRIVATE_IP="172.17.20.4"
export TARGET_SIZE="Standard_D4s_v5"
export EXPECTED_DISKS="5"
export NEEDS_PUBLIC_IP="false"
```

### Celda 3E — RECAZSRVHO-VM-P

```bash
export VM="RECAZSRVHO-VM-P"
export SOURCE_RG="RECAZSRVHO-RG"
export DESTINATION_RG="RECAZSRVHO-RG"
export VNET="rec-vnet-spoke1"
export SUBNET="rec-snet-spoke1"
export PRIVATE_IP="172.22.10.4"
export TARGET_SIZE="Standard_D4s_v5"
export EXPECTED_DISKS="3"
export NEEDS_PUBLIC_IP="true"
```

### Celda 3F — ADCDCDC-VM-P

```bash
export VM="ADCDCDC-VM-P"
export SOURCE_RG="VMADDSCDC-PRO-RG"
export DESTINATION_RG="VMADDSCDC-PRO-RG"
export VNET="cdc-vnet-spoke6"
export SUBNET="cdc-snet-spoke6"
export PRIVATE_IP="172.17.70.4"
export TARGET_SIZE="Standard_D2s_v5"
export EXPECTED_DISKS="2"
export NEEDS_PUBLIC_IP="false"
```

### Celda 4 — Derivar IDs y revisar parámetros

```bash
export STATE="$WORKDIR/$VM"
mkdir -p "$STATE"
chmod 700 "$STATE"

export SOURCE_VM_ID="/subscriptions/$SOURCE_SUBSCRIPTION/resourceGroups/$SOURCE_RG/providers/Microsoft.Compute/virtualMachines/$VM"
export DESTINATION_VM_ID="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$DESTINATION_RG/providers/Microsoft.Compute/virtualMachines/$VM"
export SUBNET_ID="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$NETWORK_RG/providers/Microsoft.Network/virtualNetworks/$VNET/subnets/$SUBNET"
export DESTINATION_NIC_ID="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$DESTINATION_RG/providers/Microsoft.Network/networkInterfaces/$VM-nic"
export DESTINATION_PIP_ID="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$DESTINATION_RG/providers/Microsoft.Network/publicIPAddresses/$VM-pip"

printf '%-24s %s\n' \
  "VM" "$VM" \
  "Source RG" "$SOURCE_RG" \
  "Destination RG" "$DESTINATION_RG" \
  "Network" "$VNET/$SUBNET" \
  "Private IP" "$PRIVATE_IP" \
  "Target size" "$TARGET_SIZE" \
  "Expected disks" "$EXPECTED_DISKS" \
  "Public IP" "$NEEDS_PUBLIC_IP" \
  "State" "$STATE"
```

**PARE:** confirme el tamaño propuesto y todos los valores con el ticket de
cambio antes de continuar.

---

## 4. Autenticación y acceso

### Celda 5 — Iniciar sesión

```bash
az login \
  --tenant "$MANAGING_TENANT" \
  --use-device-code \
  --output none
```

### Celda 6 — Verificar ambas suscripciones

```bash
az rest --method get \
  --url "$ARM/subscriptions/$SOURCE_SUBSCRIPTION?api-version=$SUBSCRIPTIONS_API" \
  --query '{name:displayName,id:subscriptionId,tenant:tenantId,state:state}' \
  --output table

az rest --method get \
  --url "$ARM/subscriptions/$DESTINATION_SUBSCRIPTION?api-version=$SUBSCRIPTIONS_API" \
  --query '{name:displayName,id:subscriptionId,tenant:tenantId,state:state}' \
  --output table
```

**Esperado:** origen `AZPLAN-OSOMCO-CSSA`, destino
`OSOMGROUP-AZPLAN-RESCASA`, ambos `Enabled`.

---

## 5. Inventario de origen

### Celda 7 — Descargar VM, NIC, NSG y extensiones

```bash
az rest --method get \
  --url "$ARM$SOURCE_VM_ID?api-version=$VM_API" \
  --output json > "$STATE/source-vm.json"

SOURCE_NIC_ID="$(jq -r '.properties.networkProfile.networkInterfaces[0].id' "$STATE/source-vm.json")"
export SOURCE_NIC_ID

az rest --method get \
  --url "$ARM$SOURCE_NIC_ID?api-version=$NETWORK_API" \
  --output json > "$STATE/source-nic.json"

SOURCE_NSG_ID="$(jq -r '.properties.networkSecurityGroup.id // empty' "$STATE/source-nic.json")"
export SOURCE_NSG_ID

if [ -n "$SOURCE_NSG_ID" ]; then
  az rest --method get \
    --url "$ARM$SOURCE_NSG_ID?api-version=$NETWORK_API" \
    --output json > "$STATE/source-nsg.json"
else
  printf '{"name":"%s-nsg","properties":{"securityRules":[]}}\n' "$VM" \
    > "$STATE/source-nsg.json"
fi

az rest --method get \
  --url "$ARM$SOURCE_VM_ID/extensions?api-version=$VM_API" \
  --output json > "$STATE/source-extensions.json" ||
  printf '{"value":[]}\n' > "$STATE/source-extensions.json"

chmod 600 "$STATE"/*.json
```

### Celda 8 — Construir inventario de discos

Esta celda consulta cada disco y conserva su configuración de conexión:

```bash
RECORDS="$STATE/disk-records.ndjson"
: > "$RECORDS"

OS_DISK_ID="$(jq -r '.properties.storageProfile.osDisk.managedDisk.id' "$STATE/source-vm.json")"
az rest --method get \
  --url "$ARM$OS_DISK_ID?api-version=$DISK_API" \
  --output json > "$STATE/disk-resource-os.json"

jq -n \
  --slurpfile vm "$STATE/source-vm.json" \
  --slurpfile disk "$STATE/disk-resource-os.json" \
  '{
    index:0,
    role:"OS",
    lun:null,
    config:$vm[0].properties.storageProfile.osDisk,
    resource:$disk[0]
  }' >> "$RECORDS"

jq -c '.properties.storageProfile.dataDisks | to_entries[]' \
  "$STATE/source-vm.json" |
while IFS= read -r entry; do
  DATA_INDEX="$(printf '%s' "$entry" | jq -r '.key + 1')"
  DATA_DISK_ID="$(printf '%s' "$entry" | jq -r '.value.managedDisk.id')"
  DATA_FILE="$STATE/disk-resource-$DATA_INDEX.json"

  az rest --method get \
    --url "$ARM$DATA_DISK_ID?api-version=$DISK_API" \
    --output json > "$DATA_FILE"

  jq -n \
    --argjson index "$DATA_INDEX" \
    --argjson config "$(printf '%s' "$entry" | jq '.value')" \
    --slurpfile disk "$DATA_FILE" \
    '{
      index:$index,
      role:"DATA",
      lun:$config.lun,
      config:$config,
      resource:$disk[0]
    }' >> "$RECORDS"
done

jq -s 'sort_by(.index)' "$RECORDS" > "$STATE/disks.json"
chmod 600 "$STATE/disks.json"

jq -r '
  .[] |
  [
    .index,
    .role,
    (.lun // "-"),
    .resource.name,
    .resource.properties.diskSizeGB,
    .resource.sku.name,
    (.config.caching // "-"),
    (.resource.properties.encryption.type // "MISSING")
  ] | @tsv
' "$STATE/disks.json" |
column -t -s $'\t'
```

**Esperado:** exactamente el número de discos indicado por `EXPECTED_DISKS`.

### Celda 9 — Validar conteo, IP, cifrado, ADE y ASG

```bash
ACTUAL_DISKS="$(jq 'length' "$STATE/disks.json")"
ACTUAL_IP="$(jq -r '.properties.ipConfigurations[0].properties.privateIPAddress' "$STATE/source-nic.json")"
IP_CONFIGS="$(jq '.properties.ipConfigurations | length' "$STATE/source-nic.json")"

[ "$ACTUAL_DISKS" -eq "$EXPECTED_DISKS" ] ||
  { echo "ERROR: discos $ACTUAL_DISKS, esperados $EXPECTED_DISKS"; exit 1; }
[ "$ACTUAL_IP" = "$PRIVATE_IP" ] ||
  { echo "ERROR: IP real $ACTUAL_IP, mapeada $PRIVATE_IP"; exit 1; }
[ "$IP_CONFIGS" -eq 1 ] ||
  { echo "ERROR: la NIC tiene múltiples configuraciones IP"; exit 1; }

BAD_ENCRYPTION="$(jq '
  [
    .[] |
    select(
      (.resource.properties.encryption.type // "") != "EncryptionAtRestWithPlatformKey"
      or (.resource.properties.encryption.diskEncryptionSetId // "") != ""
      or (.resource.properties.encryptionSettingsCollection.enabled // false) == true
    )
  ] | length
' "$STATE/disks.json")"
[ "$BAD_ENCRYPTION" -eq 0 ] ||
  { echo "ERROR: se detectó ADE, DES o cifrado no soportado"; exit 1; }

ADE_EXTENSIONS="$(jq '
  [
    .value[]? |
    select(
      ((.properties.type // "") | ascii_downcase | contains("azurediskencryption"))
      or (
        ((.properties.publisher // "") | ascii_downcase | contains("azure.security"))
        and ((.properties.type // "") | ascii_downcase | contains("diskencryption"))
      )
    )
  ] | length
' "$STATE/source-extensions.json")"
[ "$ADE_EXTENSIONS" -eq 0 ] ||
  { echo "ERROR: extensión Azure Disk Encryption detectada"; exit 1; }

ASG_REFERENCES="$(jq -s '
  (
    [
      .[0].properties.securityRules[]? |
      select(
        ((.properties.sourceApplicationSecurityGroups // []) | length) > 0
        or ((.properties.destinationApplicationSecurityGroups // []) | length) > 0
      )
    ] | length
  ) +
  (
    [
      .[1].properties.ipConfigurations[]? |
      select(((.properties.applicationSecurityGroups // []) | length) > 0)
    ] | length
  )
' "$STATE/source-nsg.json" "$STATE/source-nic.json")"
[ "$ASG_REFERENCES" -eq 0 ] ||
  { echo "ERROR: existen referencias ASG que deben remapearse"; exit 1; }

echo "OK: inventario, IP, cifrado, ADE y ASG"
```

### Celda 10 — Revisar advertencias no bloqueantes

```bash
jq '{
  sourceSize:.properties.hardwareProfile.vmSize,
  targetSize:env.TARGET_SIZE,
  securityType:(.properties.securityProfile.securityType // "Standard"),
  zones:(.zones // ["Regional"]),
  identity:(.identity.type // "None"),
  bootDiagnostics:(.properties.diagnosticsProfile.bootDiagnostics // null),
  licenseType:(.properties.licenseType // "None")
}' "$STATE/source-vm.json"

jq -r '
  .value[]? |
  [.name, .properties.publisher, .properties.type] | @tsv
' "$STATE/source-extensions.json" |
column -t -s $'\t'
```

Las identidades administradas son específicas del tenant y deben recrearse.
Boot Diagnostics destino será administrado por Azure. `licenseType` no se
copiará salvo aprobación explícita.

---

## 6. Preflight de destino

### Celda 11 — RG, subred y ausencia de VM destino

```bash
az rest --method get \
  --url "$ARM/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$DESTINATION_RG?api-version=$RESOURCES_API" \
  --query '{name:name,location:location,state:properties.provisioningState}' \
  --output table

az rest --method get \
  --url "$ARM$SUBNET_ID?api-version=$NETWORK_API" \
  --query '{name:name,prefix:properties.addressPrefix,state:properties.provisioningState}' \
  --output table

if az rest --method get \
  --url "$ARM$DESTINATION_VM_ID?api-version=$VM_API" \
  --output none 2>/dev/null; then
  echo "ERROR: la VM destino ya existe"
  exit 1
else
  echo "OK: la VM destino no existe"
fi
```

### Celda 12 — Verificar que la IP no esté ocupada

```bash
NIC_URL="$ARM/subscriptions/$DESTINATION_SUBSCRIPTION/providers/Microsoft.Network/networkInterfaces?api-version=$NETWORK_API"
printf '{"value":[]}\n' > "$STATE/destination-nics.json"

while [ -n "$NIC_URL" ]; do
  az rest --method get --url "$NIC_URL" --output json > "$STATE/nic-page.json"
  jq -s '{value:((.[0].value // []) + (.[1].value // []))}' \
    "$STATE/destination-nics.json" "$STATE/nic-page.json" \
    > "$STATE/destination-nics.tmp"
  mv "$STATE/destination-nics.tmp" "$STATE/destination-nics.json"
  NIC_URL="$(jq -r '.nextLink // empty' "$STATE/nic-page.json")"
done

IP_MATCHES="$(jq --arg ip "$PRIVATE_IP" --arg target "$DESTINATION_NIC_ID" '
  [
    .value[] |
    select((.id | ascii_downcase) != ($target | ascii_downcase)) |
    .properties.ipConfigurations[]? |
    select(.properties.privateIPAddress == $ip)
  ] | length
' "$STATE/destination-nics.json")"

[ "$IP_MATCHES" -eq 0 ] ||
  { echo "ERROR: IP destino $PRIVATE_IP ya está asignada"; exit 1; }
echo "OK: IP destino disponible"
```

### Celda 13 — SKU y cuota en vivo

```bash
SKU_URL="$ARM/subscriptions/$DESTINATION_SUBSCRIPTION/providers/Microsoft.Compute/skus?api-version=$SKU_API&%24filter=location%20eq%20%27$LOCATION%27"
printf '{"value":[]}\n' > "$STATE/destination-skus.json"

while [ -n "$SKU_URL" ]; do
  az rest --method get --url "$SKU_URL" --output json > "$STATE/sku-page.json"
  jq -s '{value:((.[0].value // []) + (.[1].value // []))}' \
    "$STATE/destination-skus.json" "$STATE/sku-page.json" \
    > "$STATE/destination-skus.tmp"
  mv "$STATE/destination-skus.tmp" "$STATE/destination-skus.json"
  SKU_URL="$(jq -r '.nextLink // empty' "$STATE/sku-page.json")"
done

jq --arg size "$TARGET_SIZE" '
  [.value[] | select(.resourceType=="virtualMachines" and .name==$size)][0]
' "$STATE/destination-skus.json" > "$STATE/target-sku.json"

jq -e '.name != null' "$STATE/target-sku.json" >/dev/null ||
  { echo "ERROR: SKU no encontrado"; exit 1; }

LOCATION_RESTRICTED="$(jq --arg location "$LOCATION" '
  [
    .restrictions[]? |
    select(
      .type=="Location"
      and (((.restrictionInfo.locations // .values // []) | index($location)) != null)
    )
  ] | length
' "$STATE/target-sku.json")"
[ "$LOCATION_RESTRICTED" -eq 0 ] ||
  { echo "ERROR: $TARGET_SIZE restringido en $LOCATION"; exit 1; }

FAMILY="$(jq -r '.family' "$STATE/target-sku.json")"
VCPUS="$(jq -r '[.capabilities[] | select(.name=="vCPUs") | .value][0]' "$STATE/target-sku.json")"
export FAMILY VCPUS

az rest --method get \
  --url "$ARM/subscriptions/$DESTINATION_SUBSCRIPTION/providers/Microsoft.Compute/locations/$LOCATION/usages?api-version=$USAGE_API" \
  --output json > "$STATE/destination-usages.json"

REGIONAL_CURRENT="$(jq -r '
  [.value[] | select((.name.value|ascii_downcase)=="cores") | .currentValue][0]
' "$STATE/destination-usages.json")"
REGIONAL_LIMIT="$(jq -r '
  [.value[] | select((.name.value|ascii_downcase)=="cores") | .limit][0]
' "$STATE/destination-usages.json")"
FAMILY_CURRENT="$(jq -r --arg family "$FAMILY" '
  [.value[] | select((.name.value|ascii_downcase)==($family|ascii_downcase)) | .currentValue][0]
' "$STATE/destination-usages.json")"
FAMILY_LIMIT="$(jq -r --arg family "$FAMILY" '
  [.value[] | select((.name.value|ascii_downcase)==($family|ascii_downcase)) | .limit][0]
' "$STATE/destination-usages.json")"

printf 'SKU=%s vCPU=%s family=%s\n' "$TARGET_SIZE" "$VCPUS" "$FAMILY"
printf 'Regional: current=%s required=%s limit=%s\n' \
  "$REGIONAL_CURRENT" "$VCPUS" "$REGIONAL_LIMIT"
printf 'Family:   current=%s required=%s limit=%s\n' \
  "$FAMILY_CURRENT" "$VCPUS" "$FAMILY_LIMIT"

[ $((REGIONAL_CURRENT + VCPUS)) -le "$REGIONAL_LIMIT" ] ||
  { echo "ERROR: cuota regional insuficiente"; exit 1; }
[ $((FAMILY_CURRENT + VCPUS)) -le "$FAMILY_LIMIT" ] ||
  { echo "ERROR: cuota familiar insuficiente"; exit 1; }
echo "OK: SKU y cuota"
```

Para la oleada AZINT, sume los vCPU de ambas VMs antes de comparar cuota.

---

## 7. Prueba opcional de escritura y Azure Policy

Esta fase **crea y elimina** un disco temporal de 1 GiB. Ejecútela antes de la
ventana una vez por cada RG destino.

### Celda 14 — Crear disco temporal

```bash
export POLICY_DISK="migration-policy-test-$(date -u '+%Y%m%d%H%M%S')"
export POLICY_DISK_ID="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$DESTINATION_RG/providers/Microsoft.Compute/disks/$POLICY_DISK"

jq -n \
  --arg location "$LOCATION" \
  '{
    location:$location,
    sku:{name:"Standard_LRS"},
    properties:{
      creationData:{createOption:"Upload",uploadSizeBytes:1073742336},
      networkAccessPolicy:"AllowAll",
      publicNetworkAccess:"Enabled"
    }
  }' > "$STATE/policy-disk.json"

az rest --method put \
  --url "$ARM$POLICY_DISK_ID?api-version=$DISK_API" \
  --body "@$STATE/policy-disk.json" \
  --output none

until [ "$(az rest --method get \
  --url "$ARM$POLICY_DISK_ID?api-version=$DISK_API" \
  --query properties.provisioningState -o tsv)" = "Succeeded" ]; do
  sleep 5
done
echo "OK: disco temporal creado"
```

### Celda 15 — Solicitar y revocar SAS sin mostrarlo

```bash
set +x
POLICY_ACCESS="$(az rest --method post \
  --url "$ARM$POLICY_DISK_ID/beginGetAccess?api-version=$DISK_API" \
  --body "{\"access\":\"Write\",\"durationInSeconds\":3600,\"fileFormat\":\"VHD\",\"getSecureVMGuestStateSAS\":false}" \
  --output json)"

printf '%s' "$POLICY_ACCESS" | jq -e '.accessSAS != null' >/dev/null

az rest --method post \
  --url "$ARM$POLICY_DISK_ID/endGetAccess?api-version=$DISK_API" \
  --output none
unset POLICY_ACCESS
echo "OK: SAS temporal concedido y revocado"
```

### Celda 16 — Cerrar acceso, eliminar y verificar

```bash
az rest --method patch \
  --url "$ARM$POLICY_DISK_ID?api-version=$DISK_API" \
  --body '{"properties":{"networkAccessPolicy":"DenyAll","publicNetworkAccess":"Disabled"}}' \
  --output none

az rest --method delete \
  --url "$ARM$POLICY_DISK_ID?api-version=$DISK_API" \
  --output none

while az rest --method get \
  --url "$ARM$POLICY_DISK_ID?api-version=$DISK_API" \
  --output none 2>/dev/null; do
  sleep 5
done
echo "OK: prueba eliminada"
```

---

## 8. Inicio de la ventana de cambio

### Celda 17 — Confirmación humana

Antes de continuar:

- Aplicación/SQL detenidos limpiamente.
- Backup requerido completado.
- Monitoreo del cambio activo.
- Equipo de red disponible.
- Para AD: `dcdiag`, `repadmin`, System State y VM-Generation ID verificados.

Registre la confirmación:

```bash
read -r -p "Escriba exactamente 'SERVICES STOPPED $VM': " CONFIRM
[ "$CONFIRM" = "SERVICES STOPPED $VM" ] ||
  { echo "Confirmación incorrecta"; exit 1; }
unset CONFIRM
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STATE/services-stopped-at"
```

### Celda 18 — Deallocate del origen

```bash
az rest --method post \
  --url "$ARM$SOURCE_VM_ID/deallocate?api-version=$VM_API" \
  --output none

until [ "$(az rest --method get \
  --url "$ARM$SOURCE_VM_ID/instanceView?api-version=$VM_API" \
  --query "statuses[?starts_with(code,'PowerState/')].code | [0]" \
  -o tsv)" = "PowerState/deallocated" ]; do
  sleep 10
done

date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STATE/source-deallocated-at"
echo "OK: origen deallocated"
```

> **Oleada AZINT:** ejecute esta celda para `AZINTBK-VM-P` y
> `AZINTCDC-VM-P` antes de crear snapshots de cualquiera. No continúe si una de
> las dos permanece encendida.

---

## 9. Snapshot y copia de cada disco

Repita las celdas 19 a 27 para cada índice desde `0` hasta
`EXPECTED_DISKS - 1`. El índice `0` siempre corresponde al disco OS.

### Celda 19 — Elegir un disco

Cambie únicamente `DISK_INDEX`:

```bash
export DISK_INDEX="0"
unset DISK_ALREADY_COPIED 2>/dev/null || true

export DISK_ROLE="$(jq -r --argjson i "$DISK_INDEX" '.[$i].role' "$STATE/disks.json")"
export SOURCE_DISK_ID="$(jq -r --argjson i "$DISK_INDEX" '.[$i].resource.id' "$STATE/disks.json")"
export DESTINATION_DISK_NAME="$(jq -r --argjson i "$DISK_INDEX" '.[$i].resource.name' "$STATE/disks.json")"
export DESTINATION_DISK_ID="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$DESTINATION_RG/providers/Microsoft.Compute/disks/$DESTINATION_DISK_NAME"

if [ ! -s "$STATE/run-id" ]; then
  date -u '+%Y%m%dT%H%M%SZ' > "$STATE/run-id"
fi
RUN_ID="$(cat "$STATE/run-id")"
VM_LOWER="$(printf '%s' "$VM" | tr '[:upper:]' '[:lower:]')"
printf -v SNAPSHOT_NAME 'mig-%s-%02d-%s' "$VM_LOWER" "$DISK_INDEX" "$RUN_ID"
export SNAPSHOT_NAME
export SNAPSHOT_ID="/subscriptions/$SOURCE_SUBSCRIPTION/resourceGroups/$SOURCE_RG/providers/Microsoft.Compute/snapshots/$SNAPSHOT_NAME"
export DISK_STATE_FILE="$STATE/disk-$DISK_INDEX-state.json"

printf 'Index=%s Role=%s Source=%s Snapshot=%s Destination=%s\n' \
  "$DISK_INDEX" "$DISK_ROLE" "$(basename "$SOURCE_DISK_ID")" \
  "$SNAPSHOT_NAME" "$DESTINATION_DISK_NAME"

if [ -f "$DISK_STATE_FILE" ]; then
  jq . "$DISK_STATE_FILE"
fi
```

### Celda 20 — Crear snapshot consistente

```bash
jq -n \
  --arg location "$LOCATION" \
  --arg source "$SOURCE_DISK_ID" \
  '{
    location:$location,
    sku:{name:"Standard_LRS"},
    properties:{
      creationData:{createOption:"Copy",sourceResourceId:$source},
      incremental:false,
      networkAccessPolicy:"AllowAll",
      publicNetworkAccess:"Enabled"
    }
  }' > "$STATE/snapshot-$DISK_INDEX.json"

if az rest --method get \
  --url "$ARM$SNAPSHOT_ID?api-version=$DISK_API" \
  --output none 2>/dev/null; then
  echo "Snapshot existente; se reutiliza solamente porque origen sigue deallocated"
else
  az rest --method put \
    --url "$ARM$SNAPSHOT_ID?api-version=$DISK_API" \
    --body "@$STATE/snapshot-$DISK_INDEX.json" \
    --output none
fi

until [ "$(az rest --method get \
  --url "$ARM$SNAPSHOT_ID?api-version=$DISK_API" \
  --query properties.provisioningState -o tsv)" = "Succeeded" ]; do
  sleep 5
done

if [ -f "$DISK_STATE_FILE" ]; then
  TRACKED_RUN="$(jq -r '.runId // empty' "$DISK_STATE_FILE")"
  TRACKED_SNAPSHOT="$(jq -r '.snapshotId // empty' "$DISK_STATE_FILE")"
  [ "$TRACKED_RUN" = "$RUN_ID" ] && [ "$TRACKED_SNAPSHOT" = "$SNAPSHOT_ID" ] ||
    { echo "ERROR: marcador de disco pertenece a otra ejecución"; exit 1; }
else
  jq -n \
    --arg runId "$RUN_ID" \
    --arg snapshotId "$SNAPSHOT_ID" \
    --arg destinationDiskId "$DESTINATION_DISK_ID" \
    '{
      runId:$runId,
      snapshotId:$snapshotId,
      destinationDiskId:$destinationDiskId,
      status:"Snapshotted"
    }' > "$DISK_STATE_FILE"
  chmod 600 "$DISK_STATE_FILE"
fi

echo "OK: snapshot listo"
```

### Celda 21 — Crear el Managed Disk de carga

```bash
DISK_SIZE_BYTES="$(jq -r --argjson i "$DISK_INDEX" '.[$i].resource.properties.diskSizeBytes' "$STATE/disks.json")"
UPLOAD_SIZE_BYTES=$((DISK_SIZE_BYTES + 512))
DISK_SKU="$(jq -r --argjson i "$DISK_INDEX" '.[$i].resource.sku.name' "$STATE/disks.json")"
OS_TYPE="$(jq -r --argjson i "$DISK_INDEX" '.[$i].resource.properties.osType // empty' "$STATE/disks.json")"
HYPERV="$(jq -r --argjson i "$DISK_INDEX" '.[$i].resource.properties.hyperVGeneration // empty' "$STATE/disks.json")"
SECURITY_TYPE="$(jq -r --argjson i "$DISK_INDEX" '.[$i].resource.properties.securityProfile.securityType // empty' "$STATE/disks.json")"
SECURITY_PROFILE="$(jq -c --argjson i "$DISK_INDEX" '.[$i].resource.properties.securityProfile // null' "$STATE/disks.json")"
ZONES="$(jq -c --argjson i "$DISK_INDEX" '.[$i].resource.zones // null' "$STATE/disks.json")"

CREATE_OPTION="Upload"
SECURE="false"
if [ "$SECURITY_TYPE" = "TrustedLaunch" ]; then
  [ "$DISK_ROLE" = "OS" ] ||
    { echo "ERROR: perfil seguro en disco no OS"; exit 1; }
  CREATE_OPTION="UploadPreparedSecure"
  SECURE="true"
fi
case "$SECURITY_TYPE" in
  ConfidentialVM_*)
    echo "ERROR: Confidential VM no soportada por este runbook"
    exit 1
    ;;
esac
export SECURE

if [ "$DISK_ROLE" = "OS" ]; then
  jq -n \
    --arg location "$LOCATION" \
    --arg sku "$DISK_SKU" \
    --arg osType "$OS_TYPE" \
    --arg hyperV "$HYPERV" \
    --arg createOption "$CREATE_OPTION" \
    --argjson uploadSize "$UPLOAD_SIZE_BYTES" \
    --argjson securityProfile "$SECURITY_PROFILE" \
    --argjson zones "$ZONES" \
    '{
      location:$location,
      sku:{name:$sku},
      properties:{
        osType:$osType,
        hyperVGeneration:$hyperV,
        creationData:{createOption:$createOption,uploadSizeBytes:$uploadSize},
        networkAccessPolicy:"AllowAll",
        publicNetworkAccess:"Enabled"
      }
    }
    | if $securityProfile != null then .properties.securityProfile=$securityProfile else . end
    | if $zones != null then .zones=$zones else . end' \
    > "$STATE/destination-disk-$DISK_INDEX.json"
else
  jq -n \
    --arg location "$LOCATION" \
    --arg sku "$DISK_SKU" \
    --argjson uploadSize "$UPLOAD_SIZE_BYTES" \
    --argjson zones "$ZONES" \
    '{
      location:$location,
      sku:{name:$sku},
      properties:{
        creationData:{createOption:"Upload",uploadSizeBytes:$uploadSize},
        networkAccessPolicy:"AllowAll",
        publicNetworkAccess:"Enabled"
      }
    }
    | if $zones != null then .zones=$zones else . end' \
    > "$STATE/destination-disk-$DISK_INDEX.json"
fi

CREATE_DESTINATION_DISK="true"
if az rest --method get \
  --url "$ARM$DESTINATION_DISK_ID?api-version=$DISK_API" \
  --output json > "$STATE/existing-destination-disk.json" 2>/dev/null; then
  EXISTING_DISK_STATE="$(jq -r '.properties.diskState' "$STATE/existing-destination-disk.json")"
  TRACKED_STATUS="$(jq -r '.status // empty' "$DISK_STATE_FILE")"
  TRACKED_RUN="$(jq -r '.runId // empty' "$DISK_STATE_FILE")"

  printf 'Existing disk state=%s tracked status=%s run=%s\n' \
    "$EXISTING_DISK_STATE" "$TRACKED_STATUS" "$TRACKED_RUN"
  [ "$TRACKED_RUN" = "$RUN_ID" ] ||
    { echo "ERROR: disco existente pertenece a otra ejecución"; exit 1; }

  case "$EXISTING_DISK_STATE:$TRACKED_STATUS" in
    ReadyToUpload:Snapshotted|ActiveUpload:Snapshotted)
      CREATE_DESTINATION_DISK="false"
      echo "Se reanudará la carga incompleta de esta ejecución"
      ;;
    Unattached:Copied|Attached:Copied)
      CREATE_DESTINATION_DISK="false"
      export DISK_ALREADY_COPIED="true"
      echo "DISCO YA COPIADO: no ejecute las celdas 22-27; seleccione otro índice"
      ;;
    Unattached:*|ReadyToUpload:*|ActiveUpload:*)
      echo "Eliminando disco no verificable antes de recrearlo"
      az rest --method post \
        --url "$ARM$DESTINATION_DISK_ID/endGetAccess?api-version=$DISK_API" \
        --output none 2>/dev/null || true
      az rest --method delete \
        --url "$ARM$DESTINATION_DISK_ID?api-version=$DISK_API" \
        --output none
      while az rest --method get \
        --url "$ARM$DESTINATION_DISK_ID?api-version=$DISK_API" \
        --output none 2>/dev/null; do
        sleep 5
      done
      ;;
    Attached:*)
      echo "ERROR: disco adjunto sin marcador Copied válido"
      exit 1
      ;;
    *)
      echo "ERROR: estado de disco no soportado: $EXISTING_DISK_STATE"
      exit 1
      ;;
  esac
fi

if [ "$CREATE_DESTINATION_DISK" = "true" ]; then
  unset DISK_ALREADY_COPIED 2>/dev/null || true
  jq '.status="Snapshotted" | del(.completedAt)' \
    "$DISK_STATE_FILE" > "$DISK_STATE_FILE.tmp"
  mv "$DISK_STATE_FILE.tmp" "$DISK_STATE_FILE"
  az rest --method put \
    --url "$ARM$DESTINATION_DISK_ID?api-version=$DISK_API" \
    --body "@$STATE/destination-disk-$DISK_INDEX.json" \
    --output none
fi

if [ "${DISK_ALREADY_COPIED:-false}" != "true" ]; then
  until [ "$(az rest --method get \
    --url "$ARM$DESTINATION_DISK_ID?api-version=$DISK_API" \
    --query properties.provisioningState -o tsv)" = "Succeeded" ]; do
    sleep 5
  done
fi
```

Si aparece `DISCO YA COPIADO`, no ejecute las celdas 22–27. Regrese a la celda
19 y seleccione el siguiente índice.

### Celda 22 — Abrir acceso público temporal

```bash
[ "${DISK_ALREADY_COPIED:-false}" != "true" ] ||
  { echo "ERROR: este disco ya estaba copiado; seleccione otro índice"; exit 1; }

OPEN_BODY='{"properties":{"networkAccessPolicy":"AllowAll","publicNetworkAccess":"Enabled"}}'

az rest --method patch \
  --url "$ARM$SNAPSHOT_ID?api-version=$DISK_API" \
  --body "$OPEN_BODY" --output none

az rest --method patch \
  --url "$ARM$DESTINATION_DISK_ID?api-version=$DISK_API" \
  --body "$OPEN_BODY" --output none

unset OPEN_BODY
echo "Acceso temporal abierto"
```

### Celda 23 — Obtener SAS sin imprimirlos

```bash
set +x
SOURCE_ACCESS="$(az rest --method post \
  --url "$ARM$SNAPSHOT_ID/beginGetAccess?api-version=$DISK_API" \
  --body "{\"access\":\"Read\",\"durationInSeconds\":$SAS_SECONDS,\"fileFormat\":\"VHD\",\"getSecureVMGuestStateSAS\":$SECURE}" \
  --output json)"

DESTINATION_ACCESS="$(az rest --method post \
  --url "$ARM$DESTINATION_DISK_ID/beginGetAccess?api-version=$DISK_API" \
  --body "{\"access\":\"Write\",\"durationInSeconds\":$SAS_SECONDS,\"fileFormat\":\"VHD\",\"getSecureVMGuestStateSAS\":$SECURE}" \
  --output json)"

SOURCE_SAS="$(printf '%s' "$SOURCE_ACCESS" | jq -r '.accessSAS // empty')"
DESTINATION_SAS="$(printf '%s' "$DESTINATION_ACCESS" | jq -r '.accessSAS // empty')"
[ -n "$SOURCE_SAS" ] && [ -n "$DESTINATION_SAS" ] ||
  { echo "ERROR: Azure no devolvió ambos SAS VHD"; exit 1; }

if [ "$SECURE" = "true" ]; then
  SOURCE_VMGS_SAS="$(printf '%s' "$SOURCE_ACCESS" | jq -r '.securityDataAccessSAS // empty')"
  DESTINATION_VMGS_SAS="$(printf '%s' "$DESTINATION_ACCESS" | jq -r '.securityDataAccessSAS // empty')"
  [ -n "$SOURCE_VMGS_SAS" ] && [ -n "$DESTINATION_VMGS_SAS" ] ||
    { echo "ERROR: Azure no devolvió ambos SAS VMGS"; exit 1; }
fi

unset SOURCE_ACCESS DESTINATION_ACCESS
echo "OK: SAS en memoria; no se muestran"
```

Si Azure devuelve una operación aún en curso o no devuelve `accessSAS`, espere
10 segundos y repita esta celda. No continúe con variables vacías.

### Celda 24 — Copiar VHD y, si aplica, VMGS

```bash
azcopy copy "$SOURCE_SAS" "$DESTINATION_SAS" \
  --blob-type PageBlob \
  --check-length=true \
  --output-type text

if [ "$SECURE" = "true" ]; then
  azcopy copy "$SOURCE_VMGS_SAS" "$DESTINATION_VMGS_SAS" \
    --blob-type PageBlob \
    --check-length=true \
    --output-type text
fi
```

**Esperado:** `Final Job Status: Completed` en cada transferencia.

### Celda 25 — Revocar SAS inmediatamente

Ejecute esta celda tanto después de éxito como después de un error de AzCopy:

```bash
az rest --method post \
  --url "$ARM$DESTINATION_DISK_ID/endGetAccess?api-version=$DISK_API" \
  --output none || true

az rest --method post \
  --url "$ARM$SNAPSHOT_ID/endGetAccess?api-version=$DISK_API" \
  --output none || true

unset SOURCE_SAS DESTINATION_SAS
unset SOURCE_VMGS_SAS DESTINATION_VMGS_SAS 2>/dev/null || true
echo "SAS revocados y variables eliminadas"
```

### Celda 26 — Esperar disco adjuntable y cerrar acceso público

```bash
until [ "$(az rest --method get \
  --url "$ARM$DESTINATION_DISK_ID?api-version=$DISK_API" \
  --query properties.diskState -o tsv)" = "Unattached" ]; do
  sleep 5
done

CLOSED_BODY='{"properties":{"networkAccessPolicy":"DenyAll","publicNetworkAccess":"Disabled"}}'

az rest --method patch \
  --url "$ARM$DESTINATION_DISK_ID?api-version=$DISK_API" \
  --body "$CLOSED_BODY" --output none

az rest --method patch \
  --url "$ARM$SNAPSHOT_ID?api-version=$DISK_API" \
  --body "$CLOSED_BODY" --output none

unset CLOSED_BODY

az rest --method get \
  --url "$ARM$DESTINATION_DISK_ID?api-version=$DISK_API" \
  --query '{state:properties.diskState,network:properties.networkAccessPolicy,public:properties.publicNetworkAccess}' \
  --output table
```

**Esperado:** `Unattached`, `DenyAll`, `Disabled`.

### Celda 27 — Registrar disco copiado

```bash
jq \
  --arg completedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '.status="Copied" | .completedAt=$completedAt' \
  "$DISK_STATE_FILE" > "$DISK_STATE_FILE.tmp"
mv "$DISK_STATE_FILE.tmp" "$DISK_STATE_FILE"

chmod 600 "$DISK_STATE_FILE"
jq . "$DISK_STATE_FILE"
```

Cambie `DISK_INDEX` en la celda 19 y repita hasta completar todos los discos.

### Celda 28 — Confirmar que todos fueron copiados

```bash
COPIED="$(
  find "$STATE" -name 'disk-*-state.json' -type f -exec \
    jq -r '.status' {} \; |
  awk '$0=="Copied"{n++} END{print n+0}'
)"

printf 'Copied=%s Expected=%s\n' "$COPIED" "$EXPECTED_DISKS"
[ "$COPIED" -eq "$EXPECTED_DISKS" ] ||
  { echo "ERROR: faltan discos"; exit 1; }
```

---

## 10. Crear red de la VM destino

### Celda 29 — Recrear NSG

```bash
NSG_NAME="$(jq -r '.name // empty' "$STATE/source-nsg.json")"
[ -n "$NSG_NAME" ] || NSG_NAME="$VM-nsg"
export NSG_NAME
export DESTINATION_NSG_ID="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$DESTINATION_RG/providers/Microsoft.Network/networkSecurityGroups/$NSG_NAME"

jq --arg location "$LOCATION" '{
  location:$location,
  tags:(.tags // {}),
  properties:{securityRules:(.properties.securityRules // [])}
}' "$STATE/source-nsg.json" > "$STATE/destination-nsg.json"

if ! az rest --method get \
  --url "$ARM$DESTINATION_NSG_ID?api-version=$NETWORK_API" \
  --output none 2>/dev/null; then
  az rest --method put \
    --url "$ARM$DESTINATION_NSG_ID?api-version=$NETWORK_API" \
    --body "@$STATE/destination-nsg.json" \
    --output none
fi

until [ "$(az rest --method get \
  --url "$ARM$DESTINATION_NSG_ID?api-version=$NETWORK_API" \
  --query properties.provisioningState -o tsv)" = "Succeeded" ]; do
  sleep 5
done
echo "OK: NSG $NSG_NAME"
```

### Celda 30 — IP pública solo para RECAZ

```bash
PUBLIC_IP_ID=""
if [ "$NEEDS_PUBLIC_IP" = "true" ]; then
  jq -n --arg location "$LOCATION" '{
    location:$location,
    sku:{name:"Standard"},
    properties:{
      publicIPAllocationMethod:"Static",
      publicIPAddressVersion:"IPv4",
      idleTimeoutInMinutes:4
    }
  }' > "$STATE/destination-pip.json"

  if ! az rest --method get \
    --url "$ARM$DESTINATION_PIP_ID?api-version=$NETWORK_API" \
    --output none 2>/dev/null; then
    az rest --method put \
      --url "$ARM$DESTINATION_PIP_ID?api-version=$NETWORK_API" \
      --body "@$STATE/destination-pip.json" \
      --output none
  fi
  PUBLIC_IP_ID="$DESTINATION_PIP_ID"
fi
export PUBLIC_IP_ID
```

### Celda 31 — Crear NIC con IP estática

```bash
ACCELERATED="$(jq -r '.properties.enableAcceleratedNetworking // false' "$STATE/source-nic.json")"
IP_FORWARDING="$(jq -r '.properties.enableIPForwarding // false' "$STATE/source-nic.json")"
DNS_SERVERS="$(jq -c '.properties.dnsSettings.dnsServers // []' "$STATE/source-nic.json")"

jq -n \
  --arg location "$LOCATION" \
  --arg privateIp "$PRIVATE_IP" \
  --arg subnetId "$SUBNET_ID" \
  --arg nsgId "$DESTINATION_NSG_ID" \
  --arg publicIpId "$PUBLIC_IP_ID" \
  --argjson accelerated "$ACCELERATED" \
  --argjson ipForwarding "$IP_FORWARDING" \
  --argjson dnsServers "$DNS_SERVERS" \
  '{
    location:$location,
    properties:{
      enableAcceleratedNetworking:$accelerated,
      enableIPForwarding:$ipForwarding,
      networkSecurityGroup:{id:$nsgId},
      ipConfigurations:[{
        name:"ipconfig1",
        properties:{
          primary:true,
          privateIPAddress:$privateIp,
          privateIPAllocationMethod:"Static",
          privateIPAddressVersion:"IPv4",
          subnet:{id:$subnetId}
        }
      }]
    }
  }
  | if $publicIpId != ""
    then .properties.ipConfigurations[0].properties.publicIPAddress={id:$publicIpId}
    else .
    end
  | if ($dnsServers | length) > 0
    then .properties.dnsSettings={dnsServers:$dnsServers}
    else .
    end' > "$STATE/destination-nic.json"

if ! az rest --method get \
  --url "$ARM$DESTINATION_NIC_ID?api-version=$NETWORK_API" \
  --output none 2>/dev/null; then
  az rest --method put \
    --url "$ARM$DESTINATION_NIC_ID?api-version=$NETWORK_API" \
    --body "@$STATE/destination-nic.json" \
    --output none
fi

until [ "$(az rest --method get \
  --url "$ARM$DESTINATION_NIC_ID?api-version=$NETWORK_API" \
  --query properties.provisioningState -o tsv)" = "Succeeded" ]; do
  sleep 5
done

az rest --method get \
  --url "$ARM$DESTINATION_NIC_ID?api-version=$NETWORK_API" \
  --query '{name:name,ip:properties.ipConfigurations[0].properties.privateIPAddress,state:properties.provisioningState}' \
  --output table
```

---

## 11. Punto de control de red

**PARE AQUÍ.** Los discos y la NIC están preparados, pero la VM destino aún no
debe arrancar.

Antes del corte, desde un host de prueba en destino valide dependencias que
continúan en origen:

```powershell
Test-NetConnection <IP-DNS-ORIGEN> -Port 53
Test-NetConnection <IP-DC-ORIGEN> -Port 88
Test-NetConnection <IP-DC-ORIGEN> -Port 389
Test-NetConnection <IP-DC-ORIGEN> -Port 445
Resolve-DnsName <DOMINIO-AD> -Server <IP-DNS-ORIGEN>
```

Solicite al equipo de red el corte del prefijo correspondiente. No permita
anuncio simultáneo desde ambos tenants.

### Celda 32 — Registrar confirmación de red

```bash
read -r -p "Escriba exactamente 'NETWORK CUTOVER COMPLETE $VM': " CONFIRM
[ "$CONFIRM" = "NETWORK CUTOVER COMPLETE $VM" ] ||
  { echo "Confirmación incorrecta"; exit 1; }
unset CONFIRM
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STATE/network-cutover-at"
```

Para la oleada AZINT, confirme el corte de `172.17.44.96/27` solo después de
copiar ambos servidores y crear ambas NICs.

---

## 12. Crear la VM especializada

### Celda 33 — Generar payload

```bash
DISK_PREFIX="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$DESTINATION_RG/providers/Microsoft.Compute/disks/"

jq -n \
  --arg location "$LOCATION" \
  --arg nicId "$DESTINATION_NIC_ID" \
  --arg diskPrefix "$DISK_PREFIX" \
  --arg targetSize "$TARGET_SIZE" \
  --slurpfile vm "$STATE/source-vm.json" \
  --slurpfile disks "$STATE/disks.json" \
  '
  def destinationDisk($name): {id:($diskPrefix + $name)};
  ($vm[0]) as $source |
  ($disks[0]) as $allDisks |
  ($allDisks[] | select(.role=="OS")) as $os |
  {
    location:$location,
    tags:($source.tags // {}),
    properties:{
      hardwareProfile:{vmSize:$targetSize},
      storageProfile:{
        osDisk:{
          osType:$os.config.osType,
          name:$os.resource.name,
          createOption:"Attach",
          caching:($os.config.caching // "ReadWrite"),
          deleteOption:"Detach",
          managedDisk:destinationDisk($os.resource.name)
        },
        dataDisks:[
          $allDisks[] |
          select(.role=="DATA") |
          {
            lun:.config.lun,
            name:.resource.name,
            createOption:"Attach",
            caching:(.config.caching // "None"),
            deleteOption:"Detach",
            writeAcceleratorEnabled:(.config.writeAcceleratorEnabled // false),
            managedDisk:destinationDisk(.resource.name)
          }
        ]
      },
      networkProfile:{
        networkInterfaces:[{id:$nicId,properties:{primary:true}}]
      },
      diagnosticsProfile:{
        bootDiagnostics:{enabled:true}
      }
    }
  }
  | if $source.properties.securityProfile != null
      then .properties.securityProfile=$source.properties.securityProfile
      else .
    end
  | if $source.zones != null then .zones=$source.zones else . end
  ' > "$STATE/destination-vm.json"

jq '{
  location,
  size:.properties.hardwareProfile.vmSize,
  osDisk:.properties.storageProfile.osDisk.name,
  dataDisks:[.properties.storageProfile.dataDisks[] | {name,lun,caching}],
  security:.properties.securityProfile,
  diagnostics:.properties.diagnosticsProfile,
  identity:.identity,
  licenseType:.properties.licenseType
}' "$STATE/destination-vm.json"
```

**Esperado:** identidad y `licenseType` ausentes; Boot Diagnostics administrado;
LUN/caché correctos; Trusted Launch presente únicamente donde corresponde.

### Celda 34 — Crear VM

```bash
az rest --method put \
  --url "$ARM$DESTINATION_VM_ID?api-version=$VM_API" \
  --body "@$STATE/destination-vm.json" \
  --output none

until [ "$(az rest --method get \
  --url "$ARM$DESTINATION_VM_ID?api-version=$VM_API" \
  --query properties.provisioningState -o tsv)" = "Succeeded" ]; do
  sleep 10
done

until [ "$(az rest --method get \
  --url "$ARM$DESTINATION_VM_ID/instanceView?api-version=$VM_API" \
  --query "statuses[?starts_with(code,'PowerState/')].code | [0]" \
  -o tsv)" = "PowerState/running" ]; do
  sleep 10
done
echo "OK: VM destino running"
```

### Celda 35 — Validación automática

```bash
az rest --method get \
  --url "$ARM$DESTINATION_VM_ID?api-version=$VM_API" \
  --output json > "$STATE/deployed-vm.json"

az rest --method get \
  --url "$ARM$DESTINATION_NIC_ID?api-version=$NETWORK_API" \
  --output json > "$STATE/deployed-nic.json"

ATTACHED_DISKS="$(jq '1 + (.properties.storageProfile.dataDisks | length)' "$STATE/deployed-vm.json")"
DEPLOYED_IP="$(jq -r '.properties.ipConfigurations[0].properties.privateIPAddress' "$STATE/deployed-nic.json")"

printf 'Attached=%s Expected=%s IP=%s ExpectedIP=%s\n' \
  "$ATTACHED_DISKS" "$EXPECTED_DISKS" "$DEPLOYED_IP" "$PRIVATE_IP"

[ "$ATTACHED_DISKS" -eq "$EXPECTED_DISKS" ] ||
  { echo "ERROR: cantidad de discos incorrecta"; exit 1; }
[ "$DEPLOYED_IP" = "$PRIVATE_IP" ] ||
  { echo "ERROR: IP incorrecta"; exit 1; }
```

---

## 13. Validación dentro del guest

En Windows:

```powershell
Get-Service WindowsAzureGuestAgent
Get-Content 'C:\WindowsAzure\Logs\WaAppAgent.log' -Tail 100
Get-Disk
Get-Volume
Get-NetIPConfiguration
```

Compruebe:

1. Azure VM Agent en `Ready`.
2. Todos los discos online, letras y LUN correctos.
3. DNS directo/inverso, dominio y sincronización de hora.
4. Servicios de aplicación/SQL, bases, jobs, logins y respaldos.
5. Prueba funcional aprobada por propietario.
6. Defender/MDE, monitoreo, alertas, backup y SQL IaaS Agent recreados.
7. Identidades administradas nuevas y RBAC/Key Vault reasignados, si aplican.
8. Para Trusted Launch: Secure Boot y vTPM.
9. Para RECAZ: registrar nueva IP pública y actualizar DNS/allowlists.
10. Para AD: `dcdiag`, `repadmin`, `SYSVOL`, `NETLOGON`, DNS y eventos.

### Celda 36 — Aceptación formal local

```bash
read -r -p "Escriba exactamente 'VALIDATION ACCEPTED $VM': " CONFIRM
[ "$CONFIRM" = "VALIDATION ACCEPTED $VM" ] ||
  { echo "Confirmación incorrecta"; exit 1; }
unset CONFIRM
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STATE/accepted-at"
chmod 600 "$STATE/accepted-at"
echo "Aceptación registrada; conservar origen deallocated durante rollback"
```

---

## 14. Rollback completo

Use esta sección únicamente si destino no puede aceptarse.

> **Controlador de dominio:** un rollback puede descartar cambios de directorio
> recibidos por el DC destino o provocar divergencia de replicación. Obtenga
> aprobación del propietario de AD, determine qué DC contiene los cambios
> autoritativos y confirme VM-Generation ID. Si no es seguro, no encienda el
> origen clonado.

### Celda R1 — Confirmar y apagar destino

```bash
read -r -p "Escriba exactamente 'ROLLBACK $VM': " CONFIRM
[ "$CONFIRM" = "ROLLBACK $VM" ] ||
  { echo "Confirmación incorrecta"; exit 1; }
unset CONFIRM

az rest --method post \
  --url "$ARM$DESTINATION_VM_ID/deallocate?api-version=$VM_API" \
  --output none

until [ "$(az rest --method get \
  --url "$ARM$DESTINATION_VM_ID/instanceView?api-version=$VM_API" \
  --query "statuses[?starts_with(code,'PowerState/')].code | [0]" \
  -o tsv)" = "PowerState/deallocated" ]; do
  sleep 10
done
echo "OK: destino deallocated"
```

Para la oleada AZINT, deallocate **ambas** VMs destino y verifique ambas antes
de pedir el rollback de `172.17.44.96/27`.

### Celda R2 — Restaurar red al origen

Solicite al equipo de red restaurar el prefijo al tenant origen. Después:

```bash
read -r -p "Escriba exactamente 'SOURCE NETWORK RESTORED $VM': " CONFIRM
[ "$CONFIRM" = "SOURCE NETWORK RESTORED $VM" ] ||
  { echo "Confirmación incorrecta"; exit 1; }
unset CONFIRM
```

### Celda R3 — Encender origen y marcar rollback

```bash
az rest --method post \
  --url "$ARM$SOURCE_VM_ID/start?api-version=$VM_API" \
  --output none

until [ "$(az rest --method get \
  --url "$ARM$SOURCE_VM_ID/instanceView?api-version=$VM_API" \
  --query "statuses[?starts_with(code,'PowerState/')].code | [0]" \
  -o tsv)" = "PowerState/running" ]; do
  sleep 10
done

date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STATE/rolled-back-at"
rm -f "$STATE/accepted-at"
echo "ROLLBACK COMPLETO: snapshots y discos copiados son ahora obsoletos"
```

Para AZINT, encienda ambos orígenes únicamente después de restaurar la red.

---

## 15. Reintento después de rollback

Después de volver a encender origen, su información puede cambiar. Antes de una
nueva captura deben eliminarse la VM destino obsoleta, sus discos, snapshots
anteriores y marcadores locales.

### Celda RR1 — Confirmación destructiva

```bash
[ -f "$STATE/rolled-back-at" ] ||
  { echo "ERROR: no existe marcador rolled-back-at"; exit 1; }

read -r -p "Escriba exactamente 'RESET STALE MIGRATION $VM': " CONFIRM
[ "$CONFIRM" = "RESET STALE MIGRATION $VM" ] ||
  { echo "Confirmación incorrecta"; exit 1; }
unset CONFIRM
```

### Celda RR2 — Eliminar recursos obsoletos

```bash
if az rest --method get \
  --url "$ARM$DESTINATION_VM_ID?api-version=$VM_API" \
  --output none 2>/dev/null; then
  az rest --method delete \
    --url "$ARM$DESTINATION_VM_ID?api-version=$VM_API" \
    --output none
  while az rest --method get \
    --url "$ARM$DESTINATION_VM_ID?api-version=$VM_API" \
    --output none 2>/dev/null; do
    sleep 10
  done
fi

for STATE_FILE in "$STATE"/disk-*-state.json; do
  [ -f "$STATE_FILE" ] || continue
  STALE_DISK_ID="$(jq -r '.destinationDiskId' "$STATE_FILE")"
  STALE_SNAPSHOT_ID="$(jq -r '.snapshotId' "$STATE_FILE")"

  az rest --method post \
    --url "$ARM$STALE_DISK_ID/endGetAccess?api-version=$DISK_API" \
    --output none 2>/dev/null || true
  az rest --method delete \
    --url "$ARM$STALE_DISK_ID?api-version=$DISK_API" \
    --output none 2>/dev/null || true

  az rest --method post \
    --url "$ARM$STALE_SNAPSHOT_ID/endGetAccess?api-version=$DISK_API" \
    --output none 2>/dev/null || true
  az rest --method delete \
    --url "$ARM$STALE_SNAPSHOT_ID?api-version=$DISK_API" \
    --output none 2>/dev/null || true
done

rm -f "$STATE"/disk-*-state.json
rm -f "$STATE/run-id" "$STATE/accepted-at" "$STATE/rolled-back-at"
echo "Estado obsoleto eliminado; reinicie desde inventario y snapshots nuevos"
```

---

## 16. Limpieza después de aceptación formal

No elimine recursos de origen hasta cerrar el periodo de rollback y obtener
autorización separada. Esta limpieza elimina únicamente snapshots temporales.

### Celda C1 — Eliminar snapshots de migración aceptada

```bash
[ -f "$STATE/accepted-at" ] ||
  { echo "ERROR: no existe aceptación formal"; exit 1; }
[ ! -f "$STATE/rolled-back-at" ] ||
  { echo "ERROR: la VM fue revertida; use limpieza de reintento"; exit 1; }

read -r -p "Escriba exactamente 'DELETE MIGRATION SNAPSHOTS $VM': " CONFIRM
[ "$CONFIRM" = "DELETE MIGRATION SNAPSHOTS $VM" ] ||
  { echo "Confirmación incorrecta"; exit 1; }
unset CONFIRM

for STATE_FILE in "$STATE"/disk-*-state.json; do
  [ -f "$STATE_FILE" ] || continue
  ACCEPTED_SNAPSHOT_ID="$(jq -r '.snapshotId' "$STATE_FILE")"

  az rest --method post \
    --url "$ARM$ACCEPTED_SNAPSHOT_ID/endGetAccess?api-version=$DISK_API" \
    --output none 2>/dev/null || true
  az rest --method patch \
    --url "$ARM$ACCEPTED_SNAPSHOT_ID?api-version=$DISK_API" \
    --body '{"properties":{"networkAccessPolicy":"DenyAll","publicNetworkAccess":"Disabled"}}' \
    --output none 2>/dev/null || true
  az rest --method delete \
    --url "$ARM$ACCEPTED_SNAPSHOT_ID?api-version=$DISK_API" \
    --output none
done

echo "Snapshots temporales eliminados; origen y discos origen conservados"
```

---

## 17. Secuencia especial para AZINTBK + AZINTCDC

Estas VMs comparten `172.17.44.96/27`. La secuencia obligatoria es:

1. Ejecutar inventario/preflight para ambas.
2. Detener aplicaciones/SQL de ambas.
3. Deallocate de ambos orígenes.
4. Crear y copiar los cinco discos de `AZINTBK-VM-P`.
5. Cambiar a la celda 3C y crear/copiar los cinco discos de `AZINTCDC-VM-P`.
6. Crear ambas NICs.
7. Confirmar ambas VMs origen deallocated y ambas VMs destino inexistentes.
8. Cortar `172.17.44.96/27` una sola vez hacia destino.
9. Crear ambas VMs destino.
10. Validar ambas antes de aceptar la oleada.

Rollback:

1. Deallocate de ambas VMs destino.
2. Confirmar ambas deallocated.
3. Restaurar `172.17.44.96/27` al origen.
4. Encender ambos orígenes.
5. Escribir `rolled-back-at` en los dos directorios de estado.

---

## 18. Evidencias que deben adjuntarse al cambio

- Salida de acceso a ambas suscripciones.
- Inventario `disks.json` por VM.
- Resultado de IP, cifrado, ADE y ASG.
- SKU y cuota en vivo.
- Hora de deallocation del origen.
- IDs y estado de todos los snapshots.
- `Final Job Status: Completed` por VHD y VMGS.
- Evidencia `Unattached`, `DenyAll`, `Disabled` por disco destino.
- Confirmación del corte de red.
- VM destino `running`, cantidad de discos e IP.
- Validación guest y aceptación del propietario.
- Evidencia de rollback o limpieza, si aplica.

No adjunte SAS ni archivos que los contengan.
