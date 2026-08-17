# Azure cross-tenant VM copy tools

This folder contains two separate Azure VM migration implementations.

| Artifact | Status | Use |
| --- | --- | --- |
| `azure-cross-tenant-vm-copy.sh` | Generic v2.0.0 | Select one source VM at runtime, re-evaluate the destination, compare compatible sizes and prices, and run an interactive migration. |
| `GUIDE-AZURE-CROSS-TENANT-VM-COPY-v2.0.0.md` | Generic v2 guide | Requirements, preflight, migration, resume, validation, and rollback procedures. |
| `azure-cross-tenant-vm-migrate.sh` | Legacy v1.1.0 | Customer-specific runbook for the original six hardcoded VMs. |
| `GUIA-MIGRACION-VM-CROSS-TENANT-SCRIPT-v1.1.0.md` | Legacy v1.1.0 guide | Instructions for the customer-specific script. |
| `GUIA-MIGRACION-VM-CROSS-TENANT-NOTEBOOK.md` | Legacy manual notebook | Customer-specific command-by-command alternative. |

> The v1.1.0 script is preserved for the original migration only. Do not modify
> its subscriptions, resource mappings, VM list, or workflow for a new pilot.
> Use the generic v2 tool instead.

Both scripts are intentionally interactive. They can deallocate VMs, create
snapshots and destination resources, and coordinate a network cutover. Neither is
an unattended migration tool.

## Download and verify on macOS

```bash
RUNBOOK_DIR="$HOME/AzureMigrationRunbook"
BASE_URL="https://raw.githubusercontent.com/osomco/scripts/main/cross-tenant-vm-copy"

mkdir -p "$RUNBOOK_DIR"
chmod 700 "$RUNBOOK_DIR"
cd "$RUNBOOK_DIR"

curl --fail --location --remote-name "$BASE_URL/azure-cross-tenant-vm-copy.sh"
curl --fail --location --remote-name "$BASE_URL/GUIDE-AZURE-CROSS-TENANT-VM-COPY-v2.0.0.md"
curl --fail --location --remote-name "$BASE_URL/azure-cross-tenant-vm-migrate.sh"
curl --fail --location --remote-name "$BASE_URL/GUIA-MIGRACION-VM-CROSS-TENANT-SCRIPT-v1.1.0.md"
curl --fail --location --remote-name "$BASE_URL/GUIA-MIGRACION-VM-CROSS-TENANT-NOTEBOOK.md"
curl --fail --location --remote-name "$BASE_URL/SHA256SUMS"

chmod 700 azure-cross-tenant-vm-copy.sh azure-cross-tenant-vm-migrate.sh
shasum -a 256 -c SHA256SUMS
```

## Download and verify on WSL2/Linux

```bash
RUNBOOK_DIR="$HOME/AzureMigrationRunbook"
BASE_URL="https://raw.githubusercontent.com/osomco/scripts/main/cross-tenant-vm-copy"

mkdir -p "$RUNBOOK_DIR"
chmod 700 "$RUNBOOK_DIR"
cd "$RUNBOOK_DIR"

curl --fail --location --remote-name "$BASE_URL/azure-cross-tenant-vm-copy.sh"
curl --fail --location --remote-name "$BASE_URL/GUIDE-AZURE-CROSS-TENANT-VM-COPY-v2.0.0.md"
curl --fail --location --remote-name "$BASE_URL/azure-cross-tenant-vm-migrate.sh"
curl --fail --location --remote-name "$BASE_URL/GUIA-MIGRACION-VM-CROSS-TENANT-SCRIPT-v1.1.0.md"
curl --fail --location --remote-name "$BASE_URL/GUIA-MIGRACION-VM-CROSS-TENANT-NOTEBOOK.md"
curl --fail --location --remote-name "$BASE_URL/SHA256SUMS"

chmod 700 azure-cross-tenant-vm-copy.sh azure-cross-tenant-vm-migrate.sh
sha256sum -c SHA256SUMS
```

Do not continue if any artifact reports `FAILED`.

## Generic v2 examples

Read-only preflight using the strongest source selector:

```bash
./azure-cross-tenant-vm-copy.sh \
  --preflight-only \
  --source-vm-id "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/pilot-rg/providers/Microsoft.Compute/virtualMachines/pilot-vm"
```

Read-only preflight using subscription, resource group, and name:

```bash
./azure-cross-tenant-vm-copy.sh \
  --preflight-only \
  --source-subscription "00000000-0000-0000-0000-000000000000" \
  --source-resource-group "pilot-rg" \
  --vm-name "pilot-vm"
```

Normal interactive migration with destination values prompted:

```bash
./azure-cross-tenant-vm-copy.sh \
  --source-vm-id "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/pilot-rg/providers/Microsoft.Compute/virtualMachines/pilot-vm"
```

Destination supplied while the operator still selects the target size:

```bash
./azure-cross-tenant-vm-copy.sh \
  --source-subscription "00000000-0000-0000-0000-000000000000" \
  --source-resource-group "pilot-rg" \
  --vm-name "pilot-vm" \
  --destination-subscription "11111111-1111-1111-1111-111111111111" \
  --managing-tenant "22222222-2222-2222-2222-222222222222" \
  --location "eastus2" \
  --destination-resource-group "pilot-destination-rg" \
  --network-resource-group "network-rg" \
  --vnet "pilot-vnet" \
  --subnet "pilot-subnet" \
  --private-ip "10.20.1.10"
```

The generic tool validates a supplied `--target-size` but still requires explicit
approval. Without it, the tool displays compatible destination sizes and current
estimated retail prices and requires an explicit selection. It never
automatically chooses the cheapest size.

Read the complete v2 guide before running a mutating mode.
