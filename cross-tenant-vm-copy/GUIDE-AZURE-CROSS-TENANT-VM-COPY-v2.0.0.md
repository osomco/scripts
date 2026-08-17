# Generic Azure cross-tenant VM copy v2.0.0

This guide covers `azure-cross-tenant-vm-copy.sh`, the generic interactive tool
for copying one Azure VM between subscriptions or tenants. It discovers the
source VM at runtime and does not use the six VM mappings embedded in the legacy
v1.1.0 runbook.

The tool is conservative by design. If it cannot prove that a source feature can
be recreated safely, preflight blocks the migration.

## Safety model

The normal migration sequence is:

```text
inventory and read-only destination checks
  -> explicit destination size selection
  -> operator reviews the resolved manifest
  -> source services stopped
  -> source VM deallocated
  -> full managed-disk snapshots
  -> temporary SAS and AzCopy PageBlob copies
  -> SAS revoked and public disk access disabled
  -> destination network resources prepared
  -> external network cutover checkpoint
  -> destination VM created and started
  -> validation or controlled rollback
```

The tool never performs the external VPN, route, firewall, or DNS cutover. The
source and destination instances must never run simultaneously.

> SAS URLs are secrets. Do not enable `set -x`, paste console output into a
> ticket, or run the tool through a wrapper that records command arguments.

## Supported operator platforms

- macOS with the system Bash 3.2 or newer.
- Windows 10/11 with WSL2 Ubuntu.
- Linux with Bash.

Native Windows PowerShell and CMD are not supported for this Bash runbook.

## Prerequisites

Install:

- Azure CLI (`az`)
- `curl`
- `jq`
- AzCopy v10 for migration and resume modes

The signed-in identity must be able to read the source VM, NIC, subnet, NSG,
extensions, disks, Compute Resource SKUs, destination resource group/network,
provider registration, permissions, quotas, and existing destination resources.
Mutating modes additionally need the corresponding Microsoft.Compute,
Microsoft.Network, snapshot, disk SAS, VM, and delete permissions.

For cross-tenant use, authenticate from a managing tenant that can reach both
subscriptions, normally through Azure Lighthouse or equivalent delegated
administration. Direct access to both subscriptions is also supported when Azure
CLI exposes them to the same signed-in operator.

```bash
az login --tenant "<managing-tenant-id>"
az account list --output table
```

Confirm that both source and destination subscription IDs are visible before
starting.

## Download and verify

### macOS

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

### WSL2 Ubuntu or Linux

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

All distributed artifacts must report `OK`. Stop if a checksum is missing or
fails.

## Source selection

Use a full ARM resource ID whenever possible:

```bash
./azure-cross-tenant-vm-copy.sh \
  --preflight-only \
  --source-vm-id "/subscriptions/<source-subscription>/resourceGroups/<source-rg>/providers/Microsoft.Compute/virtualMachines/<vm-name>"
```

The convenience form is also explicit:

```bash
./azure-cross-tenant-vm-copy.sh \
  --preflight-only \
  --source-subscription "<source-subscription>" \
  --source-resource-group "<source-rg>" \
  --vm-name "<vm-name>"
```

If a value is omitted, the tool prompts for it. A VM name alone is not accepted
without resolving it in a selected subscription. Multiple exact name matches
require an explicit resource group or full resource ID. The tool retrieves and
displays Azure's canonical source resource ID before preflight.

## Destination inputs

The tool accepts flags and prompts for anything missing:

```text
--destination-subscription
--managing-tenant
--location
--destination-resource-group
--network-resource-group
--vnet
--subnet
--private-ip
--target-size
--currency
```

The source location and source private IPv4 can be proposed, but the operator
must confirm them. No destination resource group, VNet, subnet, or network
resource group is inferred from a source name.

Use `--config <file.json>` for a reviewed pilot configuration and
`--save-config <file.json>` to save resolved nonsecret inputs. CLI flags override
config values; prompts fill the rest. Config values receive the same validation
as interactive input.

Resolved nonsecret state is stored under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/azure-cross-tenant-vm-copy/
```

Use the documented state-directory override only when operational procedures
require another protected location. State and config files never intentionally
contain ARM tokens or SAS URLs.

## Read-only preflight

`--preflight-only` permits Azure GET requests only. It can write local temporary
files and sanitized state, but its request guard rejects Azure PUT, PATCH, POST,
and DELETE operations.

Preflight checks current values on every run:

- source and destination access;
- provider registration and visible permissions;
- source VM, NIC, subnet, NSG, extension, disk, security, and tag inventory;
- destination resource conflicts;
- destination subnet and private IPv4 membership/availability;
- Compute Resource SKU location and zone restrictions;
- regional and VM-family vCPU quota;
- disk SKU, zone, and feature compatibility;
- Trusted Launch, Hyper-V generation, architecture, Premium IO, data-disk count,
  write accelerator, and accelerated-networking requirements;
- current public Azure retail price estimates.

Read-only checks cannot prove every Azure Policy or RBAC write decision. Use the
separate destination policy-test mode only when the change owner approves a
temporary resource mutation.

```bash
./azure-cross-tenant-vm-copy.sh \
  --destination-policy-test \
  --config pilot.json
```

That mode explains its temporary disk operation, requires a typed confirmation,
tests upload-disk creation and SAS behavior, closes access, and deletes the test
disk.

## Unsupported or blocked source features

Preflight blocks:

- more than one NIC or IP configuration;
- IPv6-only or multi-address configurations;
- unmanaged disks or ephemeral OS disks;
- Confidential VM security types;
- Azure Disk Encryption;
- Disk Encryption Sets or customer-managed disk keys without a separate key
  migration plan;
- Application Security Group references without an explicit mapping;
- unsupported combined or subnet-only NSG topology;
- any required capability that cannot be validated in the destination.

Managed identities are tenant-bound and are not copied. VM extensions are
inventoried but are not copied automatically. Recreate each identity, role
assignment, extension, Key Vault permission, backup/monitoring agent, and
application credential deliberately after migration.

A source boot-diagnostics storage URI is not copied; the destination uses managed
boot diagnostics. A nonempty `licenseType` is copied only when the explicit
license option is supplied and approved.

## Destination size and pricing

The tool derives the source vCPU, memory, architecture, disk count, Premium IO,
accelerated networking, Hyper-V, zone, and security requirements from current
Compute Resource SKU data.

Only candidates that satisfy those requirements, current destination
restrictions, and quota are selectable. If source vCPU or memory metadata cannot
be resolved, the operator must enter explicit minimums. Requirements are never
silently reduced.

Prices come from the public Azure Retail Prices API at runtime. USD is the default
currency. The tool follows API pagination and filters to primary pay-as-you-go
consumption VM meters, excluding Spot, Low Priority, reservation, Dev/Test, and
savings-plan variants. Source OS type is used to distinguish Windows from base
Linux consumption as accurately as public meter metadata permits.

The candidate table uses a 730-hour month. A missing or ambiguous price is shown
as `Unavailable`, never as zero. The operator must explicitly choose a compatible
size, including when `--target-size` was supplied.

> Prices are estimates, not a quote. They exclude negotiated discounts, taxes,
> reservations, savings plans, licenses, managed disks, snapshots, public IPs,
> network/data transfer, backup, monitoring, and other resources.

## Public IP, NSG, identity, and extensions

The tool always asks whether the destination needs a public IP. It never clones
the source public IP resource or address. With approval, it creates a new
Standard, static IPv4 public IP and reports the assigned address for external
DNS, firewall, and allowlist changes.

Supported NIC-level NSG custom rules and tags are copied to the destination NSG.
ASG references block migration. Source DNS servers, accelerated networking, and
IP forwarding are preserved only after destination-size compatibility checks.

Managed identities and extensions are not copied. Their inventory is printed as
a post-deployment action list.

## Normal interactive migration

Destination values can be prompted:

```bash
./azure-cross-tenant-vm-copy.sh \
  --source-vm-id "/subscriptions/<source-subscription>/resourceGroups/<source-rg>/providers/Microsoft.Compute/virtualMachines/<vm-name>"
```

Or destination values can be supplied while size remains interactive:

```bash
./azure-cross-tenant-vm-copy.sh \
  --source-subscription "<source-subscription>" \
  --source-resource-group "<source-rg>" \
  --vm-name "<vm-name>" \
  --destination-subscription "<destination-subscription>" \
  --managing-tenant "<managing-tenant>" \
  --location "<destination-region>" \
  --destination-resource-group "<destination-rg>" \
  --network-resource-group "<network-rg>" \
  --vnet "<vnet>" \
  --subnet "<subnet>" \
  --private-ip "<private-ip>"
```

Before mutation, review:

1. Canonical source and destination resource IDs.
2. Source inventory and all warnings.
3. Target size, compatibility evidence, and estimated price.
4. Disk names, LUNs, caching, SKUs, zones, and total bytes.
5. Destination subnet, private IP, NSG, and public-IP choice.
6. Identity, extension, boot diagnostics, and `licenseType` actions.
7. State directory and migration ID.

The start phrase confirms that application services are stopped. The source is
then deallocated and must remain deallocated throughout snapshot, copy, cutover,
and destination validation.

## Disk copy behavior

For every attached managed disk, the tool:

1. Creates a full snapshot in the source disk's location.
2. Creates a destination upload disk with
   `uploadSizeBytes=diskSizeBytes+512`.
3. Opens temporary public disk data access only for the transfer.
4. Keeps returned SAS values in memory and temporary process arguments.
5. Runs AzCopy server-to-server with `--blob-type PageBlob`.
6. For a Trusted Launch OS disk, uses `UploadPreparedSecure` and copies both the
   VHD and VM guest state (VMGS).
7. Revokes source and destination SAS access.
8. Disables public access on both resources.
9. Marks the disk complete in nonsecret persistent state.

Do not inspect AzCopy process arguments or collect a process dump while a transfer
is active.

## Network cutover checkpoint

After disks and destination networking are prepared, the tool stops. The network
team must execute the separately approved route/VPN/firewall/DNS cutover.

Continue only after confirming:

- the source VM remains deallocated;
- the destination VM does not yet run;
- the source path is no longer advertised where it would conflict;
- the destination route is active and exclusive;
- DNS/firewall changes are coordinated.

The destination VM is created and started only after the exact cutover phrase is
entered.

## Resume

Use resume only with the original protected state:

```bash
./azure-cross-tenant-vm-copy.sh --resume --config pilot.json
```

Resume verifies the manifest fingerprint, source/destination IDs, per-disk state,
and that the source is still deallocated. Completed disks can be reused; an
unverified or conflicting resource blocks or is removed only after an explicit
stale-state reset.

Never resume old copied disks after the source has been restarted. The disk
contents may no longer represent one consistent source point in time.

## Validation

Run validation after the destination starts:

```bash
./azure-cross-tenant-vm-copy.sh --validate --config pilot.json
```

Validate at minimum:

- boot diagnostics and system/event logs;
- all attached disks, LUNs, volumes, and drive letters/mount points;
- DNS, domain authentication, routes, firewall, and application dependencies;
- application-owner functional tests;
- recreated managed identities, role assignments, and extensions;
- backup, monitoring, Defender, vulnerability management, and SQL IaaS
  registration where applicable.

Snapshot cleanup remains blocked until validation is explicitly accepted.

## Domain controllers

The operator must identify whether the VM is a domain controller. Before a DC
migration, confirm:

- current `dcdiag` and `repadmin` health;
- healthy DNS and SYSVOL/NETLOGON;
- VM-Generation ID support;
- a current System State backup with a tested recovery path;
- AD owner approval and an authoritative rollback decision.

If those safeguards cannot be confirmed, deploy and promote a new destination DC
instead of cloning the existing VM.

## Rollback

Rollback deallocates the destination before the source can start:

```bash
./azure-cross-tenant-vm-copy.sh --rollback --config pilot.json
```

The network team must restore the source route first. The exact source-network
restoration phrase is required before the tool starts the source VM.

After rollback, the tool marks snapshots and destination disks stale. A retry
must delete the stale destination VM/disks and source migration snapshots, then
take a new source snapshot set. Never reuse pre-rollback `Copied` markers.

DC rollback requires an additional AD-owner confirmation because directory
changes accepted by the destination can create replication divergence.

## Cleanup

Only after accepted validation:

```bash
./azure-cross-tenant-vm-copy.sh --cleanup-snapshots --config pilot.json
```

Cleanup removes temporary source migration snapshots. It does not delete the
source VM, source disks, destination VM, or destination disks.

Retain the migration manifest and validation record according to the approved
change and audit policy.

## Troubleshooting

### Price is unavailable

Compatibility and quota checks remain authoritative. Review the selected size
explicitly; do not interpret `Unavailable` as free. Retry when access to
`https://prices.azure.com` is restored.

### No compatible size

Read each exclusion reason. Do not disable a requirement merely to force a
candidate. Request quota, select another approved zone/region, or document a
separate feature migration plan.

### Destination policy is unknown

Read-only preflight intentionally does not create a resource. Obtain approval and
run the separate destination policy test, or have the destination owner validate
the exact disk/network/VM operations independently.

### AzCopy fails

The cleanup trap attempts to revoke SAS access and disable public data access.
Confirm the source remains deallocated, inspect the redacted AzCopy summary, fix
the cause, and use resume with the original state.

### State contains a SAS

Stop immediately, protect and remove the exposed state through the approved
incident process, revoke disk access, and rotate any affected credentials. Do not
resume from contaminated state.
