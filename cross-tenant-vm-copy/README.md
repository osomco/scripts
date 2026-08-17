# Migración de VMs Azure entre tenants

Artefactos operativos para migrar seis VMs Azure entre tenants mediante
snapshots, SAS temporales y copias AzCopy server-to-server.

## Artefactos

| Archivo | Uso |
| --- | --- |
| `azure-cross-tenant-vm-migrate.sh` | Runbook Bash interactivo v1.1.0 con preflight, copia, reanudación, rollback y limpieza controlada. |
| `GUIA-MIGRACION-VM-CROSS-TENANT-SCRIPT-v1.1.0.md` | Guía operativa del script, preparación y secuencia recomendada. |
| `GUIA-MIGRACION-VM-CROSS-TENANT-NOTEBOOK.md` | Runbook manual comando por comando, independiente del script. |

## Plataformas

- macOS con Bash.
- Windows 10/11 mediante WSL2 Ubuntu.
- WSL2/Linux con Bash.
- PowerShell y CMD nativos no están soportados para el runbook Bash.

> **Advertencia:** estos artefactos ejecutan operaciones de infraestructura
> sensibles, incluido el apagado de VMs, creación de snapshots, copia de discos
> y corte coordinado de red. Lea la guía completa, valide el inventario y use una
> ventana de cambio aprobada. Nunca ejecute origen y destino simultáneamente con
> el mismo nombre o IP.

## Descargar y verificar en macOS

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
shasum -a 256 -c SHA256SUMS
```

## Descargar y verificar en WSL2 Ubuntu o Linux

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
sha256sum -c SHA256SUMS
```

La verificación debe mostrar `OK` para los tres artefactos antes de ejecutar el
script o seguir el notebook. No continúe si falta un archivo o aparece `FAILED`.
