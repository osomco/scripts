#!/usr/bin/env bash
#
# Fixture tests for azure-cross-tenant-vm-copy.sh.
#
# The suite is dependency free (bash + jq + awk) and never touches Azure. It
# sources the tool as a library and exercises only pure parsing, validation,
# candidate-filtering, pricing, read-only guard and secret-handling behaviour.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$ROOT_DIR/azure-cross-tenant-vm-copy.sh"
FIXTURES="$TESTS_DIR/fixtures"
WORK_DIR="$TESTS_DIR/.work"

PASS=0
FAIL=0

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  shift
  [ "$#" -gt 0 ] && printf '       %s\n' "$*"
  return 0
}

assert_equals() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$name"
  else
    fail "$name" "expected [$expected] but got [$actual]"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) pass "$name" ;;
    *) fail "$name" "expected to find [$needle] in [$haystack]" ;;
  esac
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) fail "$name" "did not expect [$needle] in [$haystack]" ;;
    *) pass "$name" ;;
  esac
}

assert_success() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$name"
  else
    fail "$name" "command failed: $*"
  fi
}

assert_failure() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$name" "command unexpectedly succeeded: $*"
  else
    pass "$name"
  fi
}

section() {
  printf '\n%s\n' "$1"
}

# Runs a library function that may call die() without terminating the suite.
in_subshell() (
  "$@"
)

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required test dependency: %s\n' "$1" >&2
    exit 1
  }
}

require_tool jq
require_tool awk

[ -x "$SCRIPT" ] || {
  printf 'Script is not executable: %s\n' "$SCRIPT" >&2
  exit 1
}

# Source the tool as a library. The library guard stops it before main runs.
# shellcheck disable=SC1090
AZ_VM_COPY_LIB=1 . "$SCRIPT"
IFS=$' \t\n'
set +e
# Sourcing installs the tool's own EXIT trap; restore the suite cleanup.
trap cleanup EXIT

TMP_DIR="$WORK_DIR"
STATE_DIR="$WORK_DIR/state"
mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
section 'CLI surface'
# ---------------------------------------------------------------------------

output="$("$SCRIPT" --version 2>&1)"
assert_equals 'version flag' "azure-cross-tenant-vm-copy 2.0.0" "$output"

output="$("$SCRIPT" --help 2>&1)"
assert_contains 'help lists preflight-only' "$output" '--preflight-only'
assert_contains 'help lists policy-test mode' "$output" 'policy-test'
assert_contains 'help lists required network-resource-group flag' "$output" '--network-resource-group'
assert_contains 'help lists required private-ip flag' "$output" '--private-ip'
assert_contains 'help documents the support boundary' "$output" 'Support boundary (fails closed)'

output="$("$SCRIPT" --not-a-flag 2>&1)"
assert_contains 'unknown flag rejected' "$output" 'Unknown argument'

output="$("$SCRIPT" --preflight-only --mode copy 2>&1)"
assert_contains 'preflight-only excludes mutating modes' "$output" 'cannot be combined'

output="$("$SCRIPT" --mode nonsense 2>&1)"
assert_contains 'unknown mode rejected' "$output" 'Unknown mode'

output="$("$SCRIPT" --currency dollars 2>&1)"
assert_contains 'currency validated' "$output" 'three-letter ISO code'

output="$("$SCRIPT" --copy-concurrency 0 2>&1)"
assert_contains 'concurrency validated' "$output" 'at least 1'

output="$("$SCRIPT" --sas-duration 60 2>&1)"
assert_contains 'sas duration validated' "$output" 'at least 3600'

output="$("$SCRIPT" --location 2>&1)"
assert_contains 'missing option value rejected' "$output" 'requires a value'

# Argument parsing side effects, evaluated in-process.
(
  MODE="copy"; PREFLIGHT_ONLY=0; MUTATIONS_ENABLED=1
  parse_arguments --preflight-only >/dev/null 2>&1
  [ "$MODE" = "preflight" ] && [ "$MUTATIONS_ENABLED" = "0" ]
)
assert_equals 'preflight-only forces read-only mode' "0" "$?"

(
  MODE="copy"; PREFLIGHT_ONLY=0; MUTATIONS_ENABLED=0
  parse_arguments --mode copy >/dev/null 2>&1
  [ "$MUTATIONS_ENABLED" = "1" ]
)
assert_equals 'copy mode enables mutations' "0" "$?"

(
  MODE="copy"; MUTATIONS_ENABLED=1
  parse_arguments --mode status >/dev/null 2>&1
  [ "$MUTATIONS_ENABLED" = "0" ]
)
assert_equals 'status mode is read-only' "0" "$?"

(
  MODE="copy"; MUTATIONS_ENABLED=1
  DESTINATION_NETWORK_RESOURCE_GROUP=""; DESTINATION_VNET=""; DESTINATION_SUBNET=""; DESTINATION_PRIVATE_IP=""
  parse_arguments --status --network-resource-group NET-RG --vnet app-vnet \
    --subnet app-subnet --private-ip 10.20.30.40 >/dev/null 2>&1
  [ "$MODE" = "status" ] && [ "$MUTATIONS_ENABLED" = "0" ] &&
    [ "$DESTINATION_NETWORK_RESOURCE_GROUP" = "NET-RG" ] &&
    [ "$DESTINATION_VNET" = "app-vnet" ] && [ "$DESTINATION_SUBNET" = "app-subnet" ] &&
    [ "$DESTINATION_PRIVATE_IP" = "10.20.30.40" ]
)
assert_equals 'required destination flags and status alias parse' "0" "$?"

# ---------------------------------------------------------------------------
section 'Resource id parsing'
# ---------------------------------------------------------------------------

VM_ID='/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/APP-RG/providers/Microsoft.Compute/virtualMachines/APP-VM'

assert_equals 'subscription field' '11111111-2222-3333-4444-555555555555' "$(resource_id_field "$VM_ID" subscription)"
assert_equals 'resource group field' 'APP-RG' "$(resource_id_field "$VM_ID" resourceGroup)"
assert_equals 'provider field' 'Microsoft.Compute' "$(resource_id_field "$VM_ID" provider)"
assert_equals 'type field' 'virtualMachines' "$(resource_id_field "$VM_ID" type)"
assert_equals 'name field' 'APP-VM' "$(resource_id_field "$VM_ID" name)"
assert_equals 'case-insensitive segment names' 'APP-RG' \
  "$(resource_id_field '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/APP-RG/providers/Microsoft.Compute/virtualMachines/APP-VM' resourceGroup)"
assert_equals 'trailing slash tolerated' 'APP-VM' "$(resource_id_field "$VM_ID/" name)"

assert_success 'valid vm resource id' is_vm_resource_id "$VM_ID"
assert_success 'lowercase vm resource id' is_vm_resource_id "$(to_lower "$VM_ID")"
assert_failure 'disk id is not a vm id' is_vm_resource_id \
  '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/APP-RG/providers/Microsoft.Compute/disks/APP-VM-osdisk'
assert_failure 'nested vm child id rejected' is_vm_resource_id "$VM_ID/extensions/foo"
assert_failure 'non-guid subscription rejected' is_vm_resource_id \
  '/subscriptions/not-a-guid/resourceGroups/APP-RG/providers/Microsoft.Compute/virtualMachines/APP-VM'
assert_failure 'empty id rejected' is_vm_resource_id ''

assert_success 'uuid accepted' is_uuid '11111111-2222-3333-4444-555555555555'
assert_success 'uppercase uuid accepted' is_uuid '11111111-2222-3333-4444-55555555555A'
assert_failure 'short uuid rejected' is_uuid '11111111-2222-3333-4444-5555'

first_id="$(migration_id_for "$VM_ID")"
second_id="$(migration_id_for "$(to_lower "$VM_ID")")"
assert_equals 'migration id is deterministic and case-insensitive' "$first_id" "$second_id"
assert_contains 'migration id embeds the vm name' "$first_id" 'app-vm-'
assert_equals 'migration id is filesystem safe' '' "$(printf '%s' "$first_id" | tr -d 'a-z0-9-')"
assert_equals 'snapshot name is padded and stable' 'copy-app-vm-03-20240102T030405Z' \
  "$(snapshot_name_for 'APP-VM' 3 '20240102T030405Z')"

# ---------------------------------------------------------------------------
section 'IPv4 and subnet validation'
# ---------------------------------------------------------------------------

assert_success 'plain address accepted' is_valid_ipv4 '10.10.1.20'
assert_success 'broadcast style address accepted' is_valid_ipv4 '255.255.255.255'
assert_failure 'octet above range rejected' is_valid_ipv4 '10.10.1.256'
assert_failure 'leading zero rejected' is_valid_ipv4 '10.10.01.20'
assert_failure 'three octets rejected' is_valid_ipv4 '10.10.1'
assert_failure 'letters rejected' is_valid_ipv4 '10.10.1.a'

assert_equals 'ipv4 to int' '168430090' "$(ipv4_to_int '10.10.10.10')"
assert_equals 'int to ipv4' '10.10.10.10' "$(int_to_ipv4 168430090)"
assert_equals 'network int' "$(ipv4_to_int '10.10.1.0')" "$(cidr_network_int '10.10.1.37/24')"
assert_equals 'broadcast int' "$(ipv4_to_int '10.10.1.255')" "$(cidr_broadcast_int '10.10.1.37/24')"

assert_success 'address inside prefix' ip_in_cidr '10.10.1.20' '10.10.1.0/24'
assert_failure 'address outside prefix' ip_in_cidr '10.10.2.20' '10.10.1.0/24'
assert_success 'address inside a /27' ip_in_cidr '172.17.44.110' '172.17.44.96/27'
assert_failure 'address outside a /27' ip_in_cidr '172.17.44.130' '172.17.44.96/27'

assert_success 'network address is reserved' ip_is_azure_reserved '10.10.1.0' '10.10.1.0/24'
assert_success 'gateway address is reserved' ip_is_azure_reserved '10.10.1.1' '10.10.1.0/24'
assert_success 'fourth address is reserved' ip_is_azure_reserved '10.10.1.3' '10.10.1.0/24'
assert_success 'broadcast address is reserved' ip_is_azure_reserved '10.10.1.255' '10.10.1.0/24'
assert_failure 'first usable address is not reserved' ip_is_azure_reserved '10.10.1.4' '10.10.1.0/24'
assert_failure 'ordinary address is not reserved' ip_is_azure_reserved '10.10.1.20' '10.10.1.0/24'

assert_success 'valid cidr' is_valid_ipv4_cidr '10.10.1.0/24'
assert_failure 'cidr without prefix rejected' is_valid_ipv4_cidr '10.10.1.0'
assert_failure 'cidr prefix out of range rejected' is_valid_ipv4_cidr '10.10.1.0/33'

# ---------------------------------------------------------------------------
section 'Source requirement derivation'
# ---------------------------------------------------------------------------

requirements="$WORK_DIR/requirements.json"
build_size_requirements "$FIXTURES/source-vm.json" "$FIXTURES/source-nic.json" \
  "$FIXTURES/disks.json" "$FIXTURES/source-skus.json" > "$requirements"

assert_equals 'source size' 'Standard_D4s_v3' "$(jq -r '.sourceSize' "$requirements")"
assert_equals 'source family' 'standardDSv3Family' "$(jq -r '.sourceFamily' "$requirements")"
assert_equals 'vcpus from sku metadata' '4' "$(jq -r '.vcpus' "$requirements")"
assert_equals 'memory from sku metadata' '16' "$(jq -r '.memoryGB' "$requirements")"
assert_equals 'architecture from sku metadata' 'x64' "$(jq -r '.architecture' "$requirements")"
assert_equals 'hyper-v generation from the os disk' 'V2' "$(jq -r '.hyperVGeneration' "$requirements")"
assert_equals 'os type from the os disk' 'Windows' "$(jq -r '.osType' "$requirements")"
assert_equals 'data disk count' '2' "$(jq -r '.dataDiskCount' "$requirements")"
assert_equals 'premium io required' 'true' "$(jq -r '.premiumIO' "$requirements")"
assert_equals 'accelerated networking required' 'true' "$(jq -r '.acceleratedNetworking' "$requirements")"
assert_equals 'trusted launch detected' 'true' "$(jq -r '.trustedLaunch' "$requirements")"
assert_equals 'write accelerator not required' 'false' "$(jq -r '.writeAccelerator' "$requirements")"
assert_equals 'zone preserved' '1' "$(jq -r '.zone' "$requirements")"
assert_equals 'total disk bytes' '274877906944' "$(jq -r '.totalDiskBytes' "$requirements")"
assert_equals 'metadata marked complete' 'true' "$(jq -r '.metadataComplete' "$requirements")"

build_size_requirements "$FIXTURES/source-vm.json" "$FIXTURES/source-nic.json" \
  "$FIXTURES/disks.json" "$FIXTURES/source-skus-empty.json" > "$WORK_DIR/requirements-nometa.json"
assert_equals 'missing sku metadata is not guessed' 'null' "$(jq -r '.vcpus' "$WORK_DIR/requirements-nometa.json")"
assert_equals 'missing sku metadata flagged' 'false' "$(jq -r '.metadataComplete' "$WORK_DIR/requirements-nometa.json")"

# ---------------------------------------------------------------------------
section 'Destination size candidate filtering'
# ---------------------------------------------------------------------------

candidates="$WORK_DIR/candidates.json"
filter_size_candidates "$FIXTURES/destination-skus.json" "$FIXTURES/requirements-base.json" \
  "$FIXTURES/destination-usages.json" eastus2 > "$candidates"

assert_equals 'eligible candidate set' 'Standard_D4s_v3 Standard_E4s_v5 Standard_M8ms' \
  "$(jq -r 'map(.name) | join(" ")' "$candidates")"
assert_equals 'candidates are sorted by size then name' 'Standard_D4s_v3' "$(jq -r '.[0].name' "$candidates")"
assert_equals 'candidate reasons are removed' 'null' "$(jq -r '.[0].reasons // "null"' "$candidates")"

evaluated="$WORK_DIR/evaluated.json"
evaluate_size_candidates "$FIXTURES/destination-skus.json" "$FIXTURES/requirements-base.json" \
  "$FIXTURES/destination-usages.json" eastus2 > "$evaluated"

reason_for() {
  jq -r --arg name "$1" '[.[] | select(.name == $name) | .reasons] | flatten | join("; ")' "$evaluated"
}

assert_contains 'undersized vcpu rejected' "$(reason_for Standard_D2s_v3)" 'fewer vCPUs than required'
assert_contains 'family quota rejection' "$(reason_for Standard_D8s_v3)" 'family quota exceeded'
assert_contains 'non premium storage rejected' "$(reason_for Standard_D4_v3)" 'no premium storage support'
assert_contains 'architecture mismatch rejected' "$(reason_for Standard_D4ps_v5)" 'different CPU architecture'
assert_contains 'missing capability metadata rejected' "$(reason_for Standard_F4s_v2_NoCaps)" 'vCPUs capability missing'
assert_contains 'zone restriction rejected' "$(reason_for Standard_D4as_v5)" 'restricted in zone 1'
assert_contains 'location restriction rejected' "$(reason_for Standard_D4s_v4)" 'restricted in eastus2'
assert_contains 'generation mismatch rejected' "$(reason_for Standard_DS4_v2)" 'no support for generation V2'
assert_equals 'compatible size has no reasons' '' "$(reason_for Standard_D4s_v3)"

filter_size_candidates "$FIXTURES/destination-skus.json" "$FIXTURES/requirements-trusted-launch.json" \
  "$FIXTURES/destination-usages.json" eastus2 > "$WORK_DIR/candidates-tl.json"
assert_equals 'trusted launch excludes disabled sizes' 'Standard_D4s_v3 Standard_E4s_v5' \
  "$(jq -r 'map(.name) | join(" ")' "$WORK_DIR/candidates-tl.json")"

filter_size_candidates "$FIXTURES/destination-skus.json" "$FIXTURES/requirements-write-accelerator.json" \
  "$FIXTURES/destination-usages.json" eastus2 > "$WORK_DIR/candidates-wa.json"
assert_equals 'write accelerator stays inside the source family' 'Standard_D4s_v3' \
  "$(jq -r 'map(.name) | join(" ")' "$WORK_DIR/candidates-wa.json")"

filter_size_candidates "$FIXTURES/destination-skus.json" "$FIXTURES/requirements-regional.json" \
  "$FIXTURES/destination-usages.json" eastus2 > "$WORK_DIR/candidates-regional.json"
assert_contains 'regional deployment allows the zone-restricted size' \
  "$(jq -r 'map(.name) | join(" ")' "$WORK_DIR/candidates-regional.json")" 'Standard_D4as_v5'

filter_size_candidates "$FIXTURES/destination-skus.json" "$FIXTURES/requirements-base.json" \
  "$FIXTURES/destination-usages-no-cores.json" eastus2 > "$WORK_DIR/candidates-noquota.json"
assert_equals 'missing regional quota fails closed' '0' "$(jq 'length' "$WORK_DIR/candidates-noquota.json")"

explanation="$(explain_size_rejection "$FIXTURES/destination-skus.json" "$FIXTURES/requirements-base.json" \
  "$FIXTURES/destination-usages.json" eastus2 Standard_D8s_v3)"
assert_contains 'rejection explanation names the size' "$explanation" 'Standard_D8s_v3'
assert_contains 'rejection explanation gives the reason' "$explanation" 'family quota exceeded'

explanation="$(explain_size_rejection "$FIXTURES/destination-skus.json" "$FIXTURES/requirements-base.json" \
  "$FIXTURES/destination-usages.json" eastus2 Standard_NotOffered)"
assert_contains 'unknown size explained' "$explanation" 'not offered in this region'

# ---------------------------------------------------------------------------
section 'Retail price normalization and pagination'
# ---------------------------------------------------------------------------

merged="$WORK_DIR/retail-merged.json"
printf '{"Items":[]}' > "$WORK_DIR/retail-acc.json"
merge_retail_pages "$WORK_DIR/retail-acc.json" "$FIXTURES/retail-page1.json" > "$WORK_DIR/retail-1.json"
merge_retail_pages "$WORK_DIR/retail-1.json" "$FIXTURES/retail-page2.json" > "$merged"

assert_equals 'pagination merges every item' '16' "$(jq '.Items | length' "$merged")"
assert_equals 'first page link is followed' 'https://prices.azure.com/api/retail/prices?page=2' \
  "$(jq -r '.NextPageLink' "$FIXTURES/retail-page1.json")"
assert_equals 'last page terminates' 'null' "$(jq -r '.NextPageLink // "null"' "$FIXTURES/retail-page2.json")"

linux_prices="$WORK_DIR/prices-linux.json"
normalize_retail_prices "$merged" eastus2 USD Linux > "$linux_prices"
assert_equals 'linux meters normalized' 'Standard_D2s_v3 Standard_D4s_v3 Standard_E4s_v5 Standard_M8ms' \
  "$(jq -r 'map(.armSkuName) | join(" ")' "$linux_prices")"
assert_equals 'linux base price kept' '0.192' \
  "$(jq -r '[.[] | select(.armSkuName == "Standard_D4s_v3") | .retailPrice][0]' "$linux_prices")"
assert_equals 'duplicate meters collapse to the lowest price' '0.252' \
  "$(jq -r '[.[] | select(.armSkuName == "Standard_E4s_v5") | .retailPrice][0]' "$linux_prices")"
assert_equals 'spot and low priority excluded' '0' \
  "$(jq '[.[] | select((.skuName // "") | test("Spot|Low Priority"))] | length' "$linux_prices")"

windows_prices="$WORK_DIR/prices-windows.json"
normalize_retail_prices "$merged" eastus2 USD Windows > "$windows_prices"
assert_equals 'windows meters normalized' 'Standard_D4s_v3' \
  "$(jq -r 'map(.armSkuName) | join(" ")' "$windows_prices")"
assert_equals 'windows price kept' '0.75' "$(jq -r '.[0].retailPrice' "$windows_prices")"

normalize_retail_prices "$merged" westeurope USD Linux > "$WORK_DIR/prices-other-region.json"
assert_equals 'other regions produce no price' '0' "$(jq 'length' "$WORK_DIR/prices-other-region.json")"

normalize_retail_prices "$merged" eastus2 EUR Linux > "$WORK_DIR/prices-eur.json"
assert_equals 'currency filter applies' '1' "$(jq 'length' "$WORK_DIR/prices-eur.json")"

ranked="$WORK_DIR/ranked.json"
rank_size_candidates "$candidates" "$linux_prices" > "$ranked"
assert_equals 'candidates ranked by hourly price' 'Standard_D4s_v3 Standard_E4s_v5 Standard_M8ms' \
  "$(jq -r 'map(.name) | join(" ")' "$ranked")"
assert_equals 'monthly estimate uses 730 hours' '140.16' \
  "$(jq -r '[.[] | select(.name == "Standard_D4s_v3") | .monthly][0] | . * 100 | round / 100' "$ranked")"

jq 'map(select(.armSkuName != "Standard_M8ms"))' "$linux_prices" > "$WORK_DIR/prices-partial.json"
rank_size_candidates "$candidates" "$WORK_DIR/prices-partial.json" > "$WORK_DIR/ranked-partial.json"
assert_equals 'unpriced candidates sort last' 'Standard_M8ms' \
  "$(jq -r '.[-1].name' "$WORK_DIR/ranked-partial.json")"
assert_equals 'unpriced candidates never show a zero price' 'null' \
  "$(jq -r '.[-1].hourly // "null"' "$WORK_DIR/ranked-partial.json")"
assert_equals 'unavailable price rendered as text' 'Unavailable' "$(format_price '')"
assert_equals 'unavailable null price rendered as text' 'Unavailable' "$(format_price 'null')"
assert_equals 'available price formatted' '0.19' "$(format_price '0.192')"

printf '[]' > "$WORK_DIR/prices-empty.json"
rank_size_candidates "$candidates" "$WORK_DIR/prices-empty.json" > "$WORK_DIR/ranked-empty.json"
assert_equals 'no pricing keeps every candidate' '3' "$(jq 'length' "$WORK_DIR/ranked-empty.json")"
assert_equals 'no pricing yields no monthly estimate' '0' \
  "$(jq '[.[] | select(.monthly != null)] | length' "$WORK_DIR/ranked-empty.json")"

# ---------------------------------------------------------------------------
section 'ARM request body construction'
# ---------------------------------------------------------------------------

snapshot_body="$WORK_DIR/snapshot-body.json"
build_snapshot_body eastus \
  '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/APP-RG/providers/Microsoft.Compute/disks/APP-VM-osdisk' \
  > "$snapshot_body"
assert_equals 'snapshot uses the source region' 'eastus' "$(jq -r '.location' "$snapshot_body")"
assert_equals 'snapshot is a full copy' 'false' "$(jq -r '.properties.incremental' "$snapshot_body")"
assert_equals 'snapshot create option' 'Copy' "$(jq -r '.properties.creationData.createOption' "$snapshot_body")"

jq '.[0]' "$FIXTURES/disks.json" > "$WORK_DIR/os-disk-record.json"
jq '.[2]' "$FIXTURES/disks.json" > "$WORK_DIR/data-disk-record.json"

os_body="$WORK_DIR/os-upload-body.json"
build_upload_disk_body "$WORK_DIR/os-disk-record.json" eastus2 UploadPreparedSecure > "$os_body"
assert_equals 'upload size is disk bytes plus the vhd footer' '137438953984' \
  "$(jq -r '.properties.creationData.uploadSizeBytes' "$os_body")"
assert_equals 'trusted launch os disk uses the secure create option' 'UploadPreparedSecure' \
  "$(jq -r '.properties.creationData.createOption' "$os_body")"
assert_equals 'os disk keeps its security profile' 'TrustedLaunch' \
  "$(jq -r '.properties.securityProfile.securityType' "$os_body")"
assert_equals 'os disk keeps its hyper-v generation' 'V2' "$(jq -r '.properties.hyperVGeneration' "$os_body")"
assert_equals 'os disk keeps its os type' 'Windows' "$(jq -r '.properties.osType' "$os_body")"
assert_equals 'os disk keeps its sku' 'Premium_LRS' "$(jq -r '.sku.name' "$os_body")"
assert_equals 'os disk keeps its zone' '1' "$(jq -r '.zones[0]' "$os_body")"
assert_equals 'os disk keeps its tags' 'prod' "$(jq -r '.tags.env' "$os_body")"
assert_equals 'upload disk is created in the destination region' 'eastus2' "$(jq -r '.location' "$os_body")"

data_body="$WORK_DIR/data-upload-body.json"
build_upload_disk_body "$WORK_DIR/data-disk-record.json" eastus2 Upload > "$data_body"
assert_equals 'data disk uses the plain upload option' 'Upload' \
  "$(jq -r '.properties.creationData.createOption' "$data_body")"
assert_equals 'data disk upload size adds the footer' '68719477248' \
  "$(jq -r '.properties.creationData.uploadSizeBytes' "$data_body")"
assert_equals 'data disk carries no os type' 'null' "$(jq -r '.properties.osType // "null"' "$data_body")"
assert_equals 'data disk carries no security profile' 'null' \
  "$(jq -r '.properties.securityProfile // "null"' "$data_body")"
assert_equals 'data disk keeps its standard sku' 'Standard_LRS' "$(jq -r '.sku.name' "$data_body")"

nic_body="$WORK_DIR/nic-body.json"
build_destination_nic_body "$FIXTURES/source-nic.json" eastus2 10.20.30.40 \
  '/subscriptions/dest/resourceGroups/NET-RG/providers/Microsoft.Network/virtualNetworks/app-vnet/subnets/app-subnet' \
  '/subscriptions/dest/resourceGroups/APP-RG/providers/Microsoft.Network/networkSecurityGroups/APP-VM-nsg' \
  '' > "$nic_body"
assert_equals 'nic uses the confirmed destination ip' '10.20.30.40' \
  "$(jq -r '.properties.ipConfigurations[0].properties.privateIPAddress' "$nic_body")"
assert_equals 'nic ip allocation is static' 'Static' \
  "$(jq -r '.properties.ipConfigurations[0].properties.privateIPAllocationMethod' "$nic_body")"
assert_equals 'nic keeps accelerated networking' 'true' \
  "$(jq -r '.properties.enableAcceleratedNetworking' "$nic_body")"
assert_equals 'nic keeps dns servers' '10.10.0.10' "$(jq -r '.properties.dnsSettings.dnsServers[0]' "$nic_body")"
assert_equals 'nic attaches the cloned nsg' 'APP-VM-nsg' \
  "$(jq -r '.properties.networkSecurityGroup.id | split("/") | last' "$nic_body")"
assert_equals 'no public ip is attached unless requested' 'null' \
  "$(jq -r '.properties.ipConfigurations[0].properties.publicIPAddress // "null"' "$nic_body")"
assert_equals 'nic never reuses the source subnet' 'app-subnet' \
  "$(jq -r '.properties.ipConfigurations[0].properties.subnet.id | split("/") | last' "$nic_body")"

build_destination_nic_body "$FIXTURES/source-nic.json" eastus2 10.20.30.40 '/subnets/x' '' \
  '/subscriptions/dest/resourceGroups/APP-RG/providers/Microsoft.Network/publicIPAddresses/APP-VM-pip' \
  > "$WORK_DIR/nic-pip-body.json"
assert_equals 'requested public ip is attached' 'APP-VM-pip' \
  "$(jq -r '.properties.ipConfigurations[0].properties.publicIPAddress.id | split("/") | last' "$WORK_DIR/nic-pip-body.json")"
assert_equals 'no nsg is attached when none is cloned' 'null' \
  "$(jq -r '.properties.networkSecurityGroup // "null"' "$WORK_DIR/nic-pip-body.json")"

cat > "$WORK_DIR/source-nsg.json" <<'JSON'
{
  "name": "APP-VM-nsg",
  "tags": {"env": "prod"},
  "properties": {
    "provisioningState": "Succeeded",
    "securityRules": [
      {
        "name": "allow-rdp",
        "etag": "W/\"abc\"",
        "properties": {
          "protocol": "Tcp",
          "sourcePortRange": "*",
          "destinationPortRange": "3389",
          "sourceAddressPrefix": "10.0.0.0/8",
          "destinationAddressPrefix": "*",
          "access": "Allow",
          "priority": 100,
          "direction": "Inbound",
          "provisioningState": "Succeeded",
          "etag": "W/\"abc\""
        }
      }
    ]
  }
}
JSON
nsg_body="$WORK_DIR/nsg-body.json"
build_destination_nsg_body "$WORK_DIR/source-nsg.json" eastus2 > "$nsg_body"
assert_equals 'nsg rule cloned' 'allow-rdp' "$(jq -r '.properties.securityRules[0].name' "$nsg_body")"
assert_equals 'nsg rule keeps its priority' '100' "$(jq -r '.properties.securityRules[0].properties.priority' "$nsg_body")"
assert_equals 'nsg rule drops provisioning state' 'null' \
  "$(jq -r '.properties.securityRules[0].properties.provisioningState // "null"' "$nsg_body")"
assert_equals 'nsg rule drops etag' 'null' \
  "$(jq -r '.properties.securityRules[0].properties.etag // "null"' "$nsg_body")"
assert_equals 'nsg keeps tags' 'prod' "$(jq -r '.tags.env' "$nsg_body")"

vm_body="$WORK_DIR/vm-body.json"
DISK_PREFIX='/subscriptions/dest/resourceGroups/APP-RG/providers/Microsoft.Compute/disks/'
build_destination_vm_body "$FIXTURES/source-vm.json" "$FIXTURES/disks.json" eastus2 \
  '/subscriptions/dest/resourceGroups/APP-RG/providers/Microsoft.Network/networkInterfaces/APP-VM-nic' \
  "$DISK_PREFIX" Standard_E4s_v5 false > "$vm_body"

assert_equals 'vm uses the approved size' 'Standard_E4s_v5' \
  "$(jq -r '.properties.hardwareProfile.vmSize' "$vm_body")"
assert_equals 'os disk is attached, never created' 'Attach' \
  "$(jq -r '.properties.storageProfile.osDisk.createOption' "$vm_body")"
assert_equals 'os disk keeps its name' 'APP-VM-osdisk' \
  "$(jq -r '.properties.storageProfile.osDisk.name' "$vm_body")"
assert_equals 'os disk points at the destination copy' "${DISK_PREFIX}APP-VM-osdisk" \
  "$(jq -r '.properties.storageProfile.osDisk.managedDisk.id' "$vm_body")"
assert_equals 'os disk keeps caching' 'ReadWrite' \
  "$(jq -r '.properties.storageProfile.osDisk.caching' "$vm_body")"
assert_equals 'disks are detached, never deleted, with the vm' 'Detach' \
  "$(jq -r '.properties.storageProfile.osDisk.deleteOption' "$vm_body")"
assert_equals 'both data disks are attached' '2' \
  "$(jq '.properties.storageProfile.dataDisks | length' "$vm_body")"
assert_equals 'data disk luns are preserved' '0 1' \
  "$(jq -r '[.properties.storageProfile.dataDisks[].lun] | join(" ")' "$vm_body")"
assert_equals 'data disk caching is preserved' 'None ReadOnly' \
  "$(jq -r '[.properties.storageProfile.dataDisks[].caching] | join(" ")' "$vm_body")"
assert_equals 'security profile is preserved' 'TrustedLaunch' \
  "$(jq -r '.properties.securityProfile.securityType' "$vm_body")"
assert_equals 'secure boot is preserved' 'true' \
  "$(jq -r '.properties.securityProfile.uefiSettings.secureBootEnabled' "$vm_body")"
assert_equals 'zone is preserved' '1' "$(jq -r '.zones[0]' "$vm_body")"
assert_equals 'vm tags are preserved' 'prod' "$(jq -r '.tags.env' "$vm_body")"
assert_equals 'boot diagnostics is managed' 'true' \
  "$(jq -r '.properties.diagnosticsProfile.bootDiagnostics.enabled' "$vm_body")"
assert_equals 'source boot diagnostics storage is dropped' 'null' \
  "$(jq -r '.properties.diagnosticsProfile.bootDiagnostics.storageUri // "null"' "$vm_body")"
assert_equals 'license type is not copied by default' 'null' \
  "$(jq -r '.properties.licenseType // "null"' "$vm_body")"
assert_equals 'identity is never copied' 'null' "$(jq -r '.identity // "null"' "$vm_body")"

jq '.properties.licenseType = "Windows_Server"' "$FIXTURES/source-vm.json" > "$WORK_DIR/licensed-vm.json"
build_destination_vm_body "$WORK_DIR/licensed-vm.json" "$FIXTURES/disks.json" eastus2 nic "$DISK_PREFIX" \
  Standard_D4s_v3 false > "$WORK_DIR/vm-body-nolicense.json"
assert_equals 'license type stays out without approval' 'null' \
  "$(jq -r '.properties.licenseType // "null"' "$WORK_DIR/vm-body-nolicense.json")"
build_destination_vm_body "$WORK_DIR/licensed-vm.json" "$FIXTURES/disks.json" eastus2 nic "$DISK_PREFIX" \
  Standard_D4s_v3 true > "$WORK_DIR/vm-body-license.json"
assert_equals 'approved license type is copied' 'Windows_Server' \
  "$(jq -r '.properties.licenseType' "$WORK_DIR/vm-body-license.json")"

jq '.properties.licenseType = "None"' "$FIXTURES/source-vm.json" > "$WORK_DIR/none-license-vm.json"
build_destination_vm_body "$WORK_DIR/none-license-vm.json" "$FIXTURES/disks.json" eastus2 nic "$DISK_PREFIX" \
  Standard_D4s_v3 true > "$WORK_DIR/vm-body-none.json"
assert_equals 'license type None is never propagated' 'null' \
  "$(jq -r '.properties.licenseType // "null"' "$WORK_DIR/vm-body-none.json")"

assert_success 'no request body carries a secret' contains_no_secrets "$vm_body"
assert_success 'no disk body carries a secret' contains_no_secrets "$os_body"

# ---------------------------------------------------------------------------
section 'Read-only mutation guard'
# ---------------------------------------------------------------------------

MUTATIONS_ENABLED=0
assert_success 'read-only mode allows GET' guard_mutation GET 'https://management.azure.com/x'
assert_failure 'read-only mode blocks PUT' guard_mutation PUT 'https://management.azure.com/x'
assert_failure 'read-only mode blocks POST' guard_mutation POST 'https://management.azure.com/x'
assert_failure 'read-only mode blocks PATCH' guard_mutation PATCH 'https://management.azure.com/x'
assert_failure 'read-only mode blocks DELETE' guard_mutation DELETE 'https://management.azure.com/x'
assert_failure 'read-only mode blocks lowercase verbs' guard_mutation post 'https://management.azure.com/x'

output="$(guard_mutation PUT 'https://management.azure.com/subscriptions/x/y?api-version=2024-01-01' 2>&1)"
assert_contains 'blocked request is reported' "$output" 'read-only mode blocked a PUT request'
assert_not_contains 'blocked request hides the query string' "$output" 'api-version'

MUTATIONS_ENABLED=1
assert_success 'copy mode allows PUT' guard_mutation PUT 'https://management.azure.com/x'

# arm_raw must refuse before any token or network call is attempted.
guard_probe="$WORK_DIR/guard-probe"
(
  rm -f "$guard_probe"
  curl() { printf 'curl\n' >> "$guard_probe"; }
  az() { printf 'az\n' >> "$guard_probe"; }
  MUTATIONS_ENABLED=0
  arm_raw POST 'https://management.azure.com/subscriptions/x/y/beginGetAccess' >/dev/null 2>&1
)
status="$?"
assert_equals 'arm_raw refuses non-GET in read-only mode' '1' "$status"
assert_equals 'arm_raw performs no network or auth call when blocked' 'no-calls' \
  "$([ -f "$guard_probe" ] && cat "$guard_probe" || echo 'no-calls')"

# ---------------------------------------------------------------------------
section 'Secret handling'
# ---------------------------------------------------------------------------

SAS_SAMPLE='https://md-abc.blob.core.windows.net/xyz/abcd?sv=2018-03-28&sr=b&si=p&sig=AbCdEf1234567890%3D'
redacted="$(printf 'copy failed for %s\n' "$SAS_SAMPLE" | redact_secrets)"
assert_not_contains 'redaction removes the signature' "$redacted" 'AbCdEf1234567890'
assert_not_contains 'redaction removes the host' "$redacted" 'blob.core.windows.net'
assert_contains 'redaction leaves a marker' "$redacted" '<redacted-url>'

printf 'accessSAS=%s\n' "$SAS_SAMPLE" > "$WORK_DIR/leaky.txt"
assert_failure 'sas bearing file is detected' contains_no_secrets "$WORK_DIR/leaky.txt"
printf '{"vmName":"APP-VM","location":"eastus2"}\n' > "$WORK_DIR/clean.json"
assert_success 'clean file passes the secret scan' contains_no_secrets "$WORK_DIR/clean.json"
printf '{"accessToken":"eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9"}\n' > "$WORK_DIR/token.json"
assert_failure 'token bearing file is detected' contains_no_secrets "$WORK_DIR/token.json"

assert_failure 'state writes refuse secrets' in_subshell write_state_file "$STATE_DIR/leaky.json" "$WORK_DIR/leaky.txt"
assert_equals 'no secret state file is created' 'absent' \
  "$([ -f "$STATE_DIR/leaky.json" ] && echo present || echo absent)"
assert_success 'state writes accept sanitized content' in_subshell write_state_file "$STATE_DIR/clean.json" "$WORK_DIR/clean.json"
assert_equals 'sanitized state file is created' 'present' \
  "$([ -f "$STATE_DIR/clean.json" ] && echo present || echo absent)"
file_mode() {
  if stat -f '%OLp' "$1" >/dev/null 2>&1; then
    stat -f '%OLp' "$1"
  else
    stat -c '%a' "$1"
  fi
}
assert_equals 'state files are private' '600' "$(file_mode "$STATE_DIR/clean.json")"

printf 'not json\n' > "$WORK_DIR/notjson.txt"
mkdir -p "$WORK_DIR/sub"
assert_failure 'invalid json state is refused' bash -c '
  AZ_VM_COPY_LIB=1 . "$1"
  trap - EXIT
  TMP_DIR="$2/sub"
  write_state_json "$2/out.json" < "$3"
' _ "$SCRIPT" "$WORK_DIR" "$WORK_DIR/notjson.txt"
assert_equals 'invalid json state file is not created' 'absent' \
  "$([ -f "$WORK_DIR/out.json" ] && echo present || echo absent)"

# The saved configuration must never contain a secret-shaped value.
(
  SOURCE_VM_ID="$VM_ID"
  SOURCE_SUBSCRIPTION='11111111-2222-3333-4444-555555555555'
  SOURCE_RESOURCE_GROUP='APP-RG'
  SOURCE_VM_NAME='APP-VM'
  DESTINATION_SUBSCRIPTION='66666666-7777-8888-9999-000000000000'
  MANAGING_TENANT='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
  LOCATION='eastus2'
  DESTINATION_RESOURCE_GROUP='APP-RG'
  DESTINATION_NETWORK_RESOURCE_GROUP='NET-RG'
  DESTINATION_VNET='app-vnet'
  DESTINATION_SUBNET='app-subnet'
  DESTINATION_PRIVATE_IP='10.10.1.20'
  CURRENCY='USD'
  SELECTED_SIZE='Standard_D4s_v3'
  save_config_file "$WORK_DIR/saved-config.json" >/dev/null 2>&1
)
assert_equals 'config round trip keeps the size' 'Standard_D4s_v3' \
  "$(jq -r '.targetSize' "$WORK_DIR/saved-config.json")"
assert_success 'saved config has no secrets' contains_no_secrets "$WORK_DIR/saved-config.json"
assert_equals 'saved config has no empty keys' '0' \
  "$(jq '[to_entries[] | select(.value == "")] | length' "$WORK_DIR/saved-config.json")"

# ---------------------------------------------------------------------------
section 'Configuration precedence'
# ---------------------------------------------------------------------------

cat > "$WORK_DIR/config.json" <<'JSON'
{
  "destinationSubscription": "66666666-7777-8888-9999-000000000000",
  "location": "westus3",
  "destinationVnet": "config-vnet",
  "currency": "EUR"
}
JSON

(
  DESTINATION_SUBSCRIPTION=''
  LOCATION='eastus2'
  DESTINATION_VNET=''
  CURRENCY='USD'
  load_config_file "$WORK_DIR/config.json" >/dev/null 2>&1
  [ "$LOCATION" = "eastus2" ] &&
    [ "$DESTINATION_VNET" = "config-vnet" ] &&
    [ "$DESTINATION_SUBSCRIPTION" = "66666666-7777-8888-9999-000000000000" ] &&
    [ "$CURRENCY" = "USD" ]
)
assert_equals 'cli wins over config, config fills the gaps' '0' "$?"

printf '{"accessSAS":"https://x?sig=abc123456"}' > "$WORK_DIR/secret-config.json"
assert_failure 'config carrying a secret is refused' bash -c '
  AZ_VM_COPY_LIB=1 . "$1"
  trap - EXIT
  TMP_DIR="$2/sub"
  load_config_file "$2/secret-config.json"
' _ "$SCRIPT" "$WORK_DIR"

assert_failure 'non object config is refused' bash -c '
  AZ_VM_COPY_LIB=1 . "$1"
  trap - EXIT
  TMP_DIR="$2/sub"
  printf "[1,2,3]" > "$2/array-config.json"
  load_config_file "$2/array-config.json"
' _ "$SCRIPT" "$WORK_DIR"

# ---------------------------------------------------------------------------
section 'Field validators and manifest fingerprint'
# ---------------------------------------------------------------------------

assert_success 'azure name accepted' is_azure_name 'APP-VM_01.prod'
assert_failure 'azure name with a slash rejected' is_azure_name 'APP/VM'
assert_failure 'empty azure name rejected' is_azure_name ''
assert_success 'location accepted' is_location_name 'eastus2'
assert_failure 'location with a space rejected' is_location_name 'east us 2'
assert_success 'currency accepted' is_currency_code 'usd'
assert_failure 'currency too long rejected' is_currency_code 'USDD'
assert_success 'positive integer accepted' is_positive_integer '4'
assert_failure 'zero rejected as a vcpu count' is_positive_integer '0'
assert_success 'decimal memory accepted' is_positive_number '3.5'
assert_failure 'negative memory rejected' is_positive_number '-1'

fingerprint_of() (
  SOURCE_VM_ID="$VM_ID"
  DESTINATION_SUBSCRIPTION='66666666-7777-8888-9999-000000000000'
  LOCATION="$1"
  DESTINATION_RESOURCE_GROUP='APP-RG'
  DESTINATION_NETWORK_RESOURCE_GROUP='NET-RG'
  DESTINATION_VNET='app-vnet'
  DESTINATION_SUBNET='app-subnet'
  DESTINATION_PRIVATE_IP="$2"
  SELECTED_SIZE="$3"
  manifest_fingerprint
)

assert_equals 'fingerprint is stable' "$(fingerprint_of eastus2 10.10.1.20 Standard_D4s_v3)" \
  "$(fingerprint_of eastus2 10.10.1.20 Standard_D4s_v3)"
assert_not_contains 'fingerprint changes with the ip' \
  "$(fingerprint_of eastus2 10.10.1.20 Standard_D4s_v3)" "$(fingerprint_of eastus2 10.10.1.21 Standard_D4s_v3)"
assert_not_contains 'fingerprint changes with the size' \
  "$(fingerprint_of eastus2 10.10.1.20 Standard_D4s_v3)" "$(fingerprint_of eastus2 10.10.1.20 Standard_E4s_v5)"
assert_not_contains 'fingerprint changes with the region' \
  "$(fingerprint_of eastus2 10.10.1.20 Standard_D4s_v3)" "$(fingerprint_of westus3 10.10.1.20 Standard_D4s_v3)"

# ---------------------------------------------------------------------------
section 'Destination identifier construction'
# ---------------------------------------------------------------------------

(
  DESTINATION_SUBSCRIPTION='66666666-7777-8888-9999-000000000000'
  DESTINATION_RESOURCE_GROUP='APP-RG'
  DESTINATION_NETWORK_RESOURCE_GROUP='NET-RG'
  DESTINATION_VNET='app-vnet'
  DESTINATION_SUBNET='app-subnet'
  SOURCE_VM_NAME='APP-VM'
  printf '%s\n%s\n%s\n%s\n' "$(destination_vm_id)" "$(destination_nic_id)" \
    "$(destination_pip_id)" "$(destination_subnet_id)"
) > "$WORK_DIR/ids.txt"

assert_equals 'destination vm id' \
  '/subscriptions/66666666-7777-8888-9999-000000000000/resourceGroups/APP-RG/providers/Microsoft.Compute/virtualMachines/APP-VM' \
  "$(sed -n '1p' "$WORK_DIR/ids.txt")"
assert_equals 'destination nic id' \
  '/subscriptions/66666666-7777-8888-9999-000000000000/resourceGroups/APP-RG/providers/Microsoft.Network/networkInterfaces/APP-VM-nic' \
  "$(sed -n '2p' "$WORK_DIR/ids.txt")"
assert_equals 'destination public ip id' \
  '/subscriptions/66666666-7777-8888-9999-000000000000/resourceGroups/APP-RG/providers/Microsoft.Network/publicIPAddresses/APP-VM-pip' \
  "$(sed -n '3p' "$WORK_DIR/ids.txt")"
assert_equals 'destination subnet id uses the network resource group' \
  '/subscriptions/66666666-7777-8888-9999-000000000000/resourceGroups/NET-RG/providers/Microsoft.Network/virtualNetworks/app-vnet/subnets/app-subnet' \
  "$(sed -n '4p' "$WORK_DIR/ids.txt")"

assert_equals 'source vm id builder' "$VM_ID" \
  "$(vm_resource_id '11111111-2222-3333-4444-555555555555' 'APP-RG' 'APP-VM')"

# The upload disk size must always be the exact byte size plus 512.
assert_equals 'upload size adds the vhd footer' '137438953984' \
  "$(( $(jq -r '.[0].resource.properties.diskSizeBytes' "$FIXTURES/disks.json") + 512 ))"

# ---------------------------------------------------------------------------
section 'Bash 3.2 compatibility'
# ---------------------------------------------------------------------------

incompatible="$(grep -nE 'declare -A|local -A|mapfile|readarray|local -n|declare -n|wait -n|\$\{[A-Za-z_][A-Za-z0-9_]*,,\}|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^\}' "$SCRIPT" |
  grep -vE '^[0-9]+:[[:space:]]*#' || true)"
assert_equals 'no bash 4 only constructs' '' "$incompatible"

assert_success 'script parses with bash' bash -n "$SCRIPT"
assert_success 'test suite parses with bash' bash -n "$TESTS_DIR/run.sh"

printf '\n'
printf 'passed: %s  failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
