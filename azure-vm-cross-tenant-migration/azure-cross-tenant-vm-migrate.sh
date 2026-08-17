#!/usr/bin/env bash
#
# Interactive Azure-to-Azure cross-tenant VM migration using:
#   - ARM REST API through an Azure CLI token
#   - Managed disk snapshots
#   - Temporary read/write SAS URLs
#   - AzCopy server-to-server transfer
#
# The script is intentionally interactive. It never changes VPN routes and never
# deletes source VMs or source disks.

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.1.0"

SOURCE_SUBSCRIPTION="b594755a-639d-4f7b-bb29-c01c9397a87a"
DESTINATION_SUBSCRIPTION="a4ba9883-6dbb-4184-92a2-6da22dac9c01"
MANAGING_TENANT="11e34461-47a6-46c4-a3ca-720f77590ccc"
LOCATION="eastus2"

VM_API="2024-11-01"
DISK_API="2025-01-02"
NETWORK_API="2024-05-01"
RESOURCES_API="2021-04-01"
SUBSCRIPTIONS_API="2022-12-01"
COMPUTE_SKU_API="2021-07-01"
COMPUTE_USAGE_API="2024-11-01"

SAS_DURATION_SECONDS="${SAS_DURATION_SECONDS:-43200}"
COPY_CONCURRENCY="${COPY_CONCURRENCY:-4}"
STATE_DIR="${MIGRATION_STATE_DIR:-$PWD/azure-vm-migration-state}"
KEEP_LICENSE_TYPE="${KEEP_LICENSE_TYPE:-0}"
INTERACTIVE_AUTH_ALLOWED=1

VM_NAMES=(
  "MINFO-VM-P"
  "AZINTBK-VM-P"
  "AZINTCDC-VM-P"
  "LSR-DB-VM-P"
  "RECAZSRVHO-VM-P"
  "ADCDCDC-VM-P"
)

ARM_TOKEN=""
TOKEN_ACQUIRED_AT=0
LAST_STATUS=""
LAST_BODY=""
LAST_HEADERS=""
TMP_DIR=""

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup_tmp() {
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup_tmp EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_base_tools() {
  require_command az
  require_command curl
  require_command jq
}

require_azcopy() {
  if ! command -v azcopy >/dev/null 2>&1; then
    cat >&2 <<'EOF'
AzCopy is required for disk transfer but was not found.

Install it before using the copy phase:
  https://learn.microsoft.com/azure/storage/common/storage-use-azcopy-v10

On macOS with Homebrew:
  brew install azcopy
EOF
    exit 1
  fi
}

init_runtime() {
  require_base_tools
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/azure-vm-migration.XXXXXX")"
  chmod 700 "$TMP_DIR"
}

source_resource_group() {
  case "$1" in
    MINFO-VM-P) echo "MAINFO-RG" ;;
    AZINTBK-VM-P) echo "INTBK-RG" ;;
    AZINTCDC-VM-P) echo "INTCDC-RG" ;;
    LSR-DB-VM-P) echo "LSRDB-PROD-RG" ;;
    RECAZSRVHO-VM-P) echo "RECAZSRVHO-RG" ;;
    ADCDCDC-VM-P) echo "VMADDSCDC-PRO-RG" ;;
    *) die "Unsupported VM: $1" ;;
  esac
}

destination_resource_group() {
  source_resource_group "$1"
}

destination_vnet() {
  case "$1" in
    MINFO-VM-P) echo "cdc-vnet-spoke3" ;;
    AZINTBK-VM-P|AZINTCDC-VM-P) echo "cdc-vnet-spoke4" ;;
    LSR-DB-VM-P) echo "cdc-vnet-spoke1" ;;
    RECAZSRVHO-VM-P) echo "rec-vnet-spoke1" ;;
    ADCDCDC-VM-P) echo "cdc-vnet-spoke6" ;;
    *) die "Unsupported VM: $1" ;;
  esac
}

destination_subnet() {
  case "$1" in
    MINFO-VM-P) echo "cdc-snet-spoke3" ;;
    AZINTBK-VM-P|AZINTCDC-VM-P) echo "cdc-snet-spoke4" ;;
    LSR-DB-VM-P) echo "cdc-snet-spoke1" ;;
    RECAZSRVHO-VM-P) echo "rec-snet-spoke1" ;;
    ADCDCDC-VM-P) echo "cdc-snet-spoke6" ;;
    *) die "Unsupported VM: $1" ;;
  esac
}

destination_private_ip() {
  case "$1" in
    MINFO-VM-P) echo "172.17.38.4" ;;
    AZINTBK-VM-P) echo "172.17.44.100" ;;
    AZINTCDC-VM-P) echo "172.17.44.101" ;;
    LSR-DB-VM-P) echo "172.17.20.4" ;;
    RECAZSRVHO-VM-P) echo "172.22.10.4" ;;
    ADCDCDC-VM-P) echo "172.17.70.4" ;;
    *) die "Unsupported VM: $1" ;;
  esac
}

destination_vm_size() {
  local vm="$1"
  local state source_size override=""

  state="$(vm_state_dir "$vm")"
  [ -f "$state/source-vm.json" ] ||
    die "Source manifest is missing; run inventory first: $vm"
  source_size="$(jq -r '.properties.hardwareProfile.vmSize' "$state/source-vm.json")"

  case "$vm" in
    MINFO-VM-P) override="${TARGET_SIZE_MINFO_VM_P:-}" ;;
    AZINTBK-VM-P) override="${TARGET_SIZE_AZINTBK_VM_P:-}" ;;
    AZINTCDC-VM-P) override="${TARGET_SIZE_AZINTCDC_VM_P:-}" ;;
    LSR-DB-VM-P) override="${TARGET_SIZE_LSR_DB_VM_P:-}" ;;
    RECAZSRVHO-VM-P) override="${TARGET_SIZE_RECAZSRVHO_VM_P:-}" ;;
    ADCDCDC-VM-P) override="${TARGET_SIZE_ADCDCDC_VM_P:-}" ;;
    *) die "Unsupported VM: $vm" ;;
  esac

  printf '%s' "${override:-$source_size}"
}

destination_subnet_id() {
  local vm="$1"
  printf '/subscriptions/%s/resourceGroups/network-rg-cdc/providers/Microsoft.Network/virtualNetworks/%s/subnets/%s' \
    "$DESTINATION_SUBSCRIPTION" "$(destination_vnet "$vm")" "$(destination_subnet "$vm")"
}

vm_state_dir() {
  printf '%s/%s' "$STATE_DIR" "$1"
}

source_vm_id() {
  local vm="$1"
  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Compute/virtualMachines/%s' \
    "$SOURCE_SUBSCRIPTION" "$(source_resource_group "$vm")" "$vm"
}

destination_vm_id() {
  local vm="$1"
  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Compute/virtualMachines/%s' \
    "$DESTINATION_SUBSCRIPTION" "$(destination_resource_group "$vm")" "$vm"
}

destination_nic_id() {
  local vm="$1"
  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Network/networkInterfaces/%s-nic' \
    "$DESTINATION_SUBSCRIPTION" "$(destination_resource_group "$vm")" "$vm"
}

destination_pip_id() {
  local vm="$1"
  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Network/publicIPAddresses/%s-pip' \
    "$DESTINATION_SUBSCRIPTION" "$(destination_resource_group "$vm")" "$vm"
}

resource_url() {
  local id="$1"
  local api="$2"
  printf 'https://management.azure.com%s?api-version=%s' "$id" "$api"
}

header_value() {
  local name="$1"
  awk -F': *' -v target="$name" '
    tolower($1) == tolower(target) {
      sub(/\r$/, "", $2)
      value=$2
    }
    END { print value }
  ' "$LAST_HEADERS"
}

refresh_token() {
  local now token_json expires
  now="$(date +%s)"
  if [ -n "$ARM_TOKEN" ] && [ $((now - TOKEN_ACQUIRED_AT)) -lt 2700 ]; then
    return
  fi

  token_json="$(az account get-access-token \
    --tenant "$MANAGING_TENANT" \
    --resource https://management.azure.com/ \
    --output json 2>/dev/null)" || {
      if [ "$INTERACTIVE_AUTH_ALLOWED" -ne 1 ]; then
        die "Azure authentication expired during a copy. Re-run the script after a fresh az login; completed disks will be reused."
      fi
      warn "Azure CLI authentication is missing or expired."
      az login --tenant "$MANAGING_TENANT" >/dev/null
      token_json="$(az account get-access-token \
        --tenant "$MANAGING_TENANT" \
        --resource https://management.azure.com/ \
        --output json)"
    }

  ARM_TOKEN="$(printf '%s' "$token_json" | jq -r '.accessToken')"
  expires="$(printf '%s' "$token_json" | jq -r '.expires_on // .expiresOn // empty')"
  [ -n "$ARM_TOKEN" ] && [ "$ARM_TOKEN" != "null" ] || die "Could not obtain an ARM token"
  TOKEN_ACQUIRED_AT="$now"
  if [ -n "$expires" ]; then
    log "ARM token refreshed"
  fi
}

arm_raw() {
  local method="$1"
  local url="$2"
  local body_file="${3:-}"
  local suffix

  refresh_token
  suffix="$(date +%s)-$RANDOM-$RANDOM"
  LAST_HEADERS="$TMP_DIR/headers-$suffix"
  LAST_BODY="$TMP_DIR/body-$suffix"

  if [ -n "$body_file" ]; then
    LAST_STATUS="$(curl --silent --show-error \
      --request "$method" \
      --header "Authorization: Bearer $ARM_TOKEN" \
      --header "Content-Type: application/json" \
      --dump-header "$LAST_HEADERS" \
      --output "$LAST_BODY" \
      --write-out '%{http_code}' \
      --data-binary "@$body_file" \
      "$url")"
  else
    LAST_STATUS="$(curl --silent --show-error \
      --request "$method" \
      --header "Authorization: Bearer $ARM_TOKEN" \
      --header "Content-Type: application/json" \
      --dump-header "$LAST_HEADERS" \
      --output "$LAST_BODY" \
      --write-out '%{http_code}' \
      "$url")"
  fi
}

print_arm_error() {
  local body="$1"
  jq -r '
    if .error then
      "Code: \(.error.code // "Unknown")\nMessage: \(.error.message // "No message")"
    else
      "Unexpected ARM response"
    end
  ' "$body" 2>/dev/null || echo "Unexpected ARM response" >&2
}

arm_get_to_file() {
  local id="$1"
  local api="$2"
  local output="$3"

  arm_raw GET "$(resource_url "$id" "$api")"
  if [ "$LAST_STATUS" != "200" ]; then
    print_arm_error "$LAST_BODY" >&2
    return 1
  fi
  cp "$LAST_BODY" "$output"
  chmod 600 "$output"
}

resource_exists() {
  local id="$1"
  local api="$2"

  arm_raw GET "$(resource_url "$id" "$api")"
  case "$LAST_STATUS" in
    200) return 0 ;;
    404) return 1 ;;
    *)
      print_arm_error "$LAST_BODY" >&2
      die "Could not determine whether the resource exists: $id"
      ;;
  esac
}

arm_list_to_file() {
  local url="$1"
  local output="$2"
  local accumulator page merged next

  accumulator="$TMP_DIR/list-accumulator-$RANDOM.json"
  printf '{"value":[]}' > "$accumulator"

  while [ -n "$url" ]; do
    arm_raw GET "$url"
    if [ "$LAST_STATUS" != "200" ]; then
      print_arm_error "$LAST_BODY" >&2
      return 1
    fi

    page="$LAST_BODY"
    merged="$TMP_DIR/list-merged-$RANDOM.json"
    jq -s '{value:((.[0].value // []) + (.[1].value // []))}' \
      "$accumulator" "$page" > "$merged"
    mv "$merged" "$accumulator"
    next="$(jq -r '.nextLink // empty' "$page")"
    url="$next"
  done

  cp "$accumulator" "$output"
  chmod 600 "$output"
}

poll_arm_url() {
  local poll_url="$1"
  local output="$2"
  local attempts=0
  local status

  while [ "$attempts" -lt 360 ]; do
    arm_raw GET "$poll_url"
    case "$LAST_STATUS" in
      200|201)
        status="$(jq -r '.status // empty' "$LAST_BODY" 2>/dev/null || true)"
        case "$status" in
          Failed|Canceled|Cancelled)
            print_arm_error "$LAST_BODY" >&2
            return 1
            ;;
          InProgress|Running|Accepted)
            ;;
          *)
            cp "$LAST_BODY" "$output"
            chmod 600 "$output"
            return 0
            ;;
        esac
        ;;
      202) ;;
      204)
        : > "$output"
        chmod 600 "$output"
        return 0
        ;;
      *)
        print_arm_error "$LAST_BODY" >&2
        return 1
        ;;
    esac
    attempts=$((attempts + 1))
    sleep 5
  done
  return 1
}

arm_operation() {
  local method="$1"
  local url="$2"
  local body_file="${3:-}"
  local output="$4"
  local location async_url poll_url status

  arm_raw "$method" "$url" "$body_file"
  case "$LAST_STATUS" in
    200|201)
      cp "$LAST_BODY" "$output"
      chmod 600 "$output"
      return 0
      ;;
    202)
      location="$(header_value Location)"
      async_url="$(header_value Azure-AsyncOperation)"
      poll_url="${location:-$async_url}"
      [ -n "$poll_url" ] || die "ARM returned 202 without a polling URL"
      log "Waiting for Azure operation"
      poll_arm_url "$poll_url" "$output" || die "Azure asynchronous operation failed"

      status="$(jq -r '.status // empty' "$output" 2>/dev/null || true)"
      if [ "$status" = "Succeeded" ] && [ -n "$location" ] && [ "$poll_url" != "$location" ]; then
        poll_arm_url "$location" "$output" || true
      fi
      return 0
      ;;
    204)
      : > "$output"
      chmod 600 "$output"
      return 0
      ;;
    *)
      print_arm_error "$LAST_BODY" >&2
      return 1
      ;;
  esac
}

wait_for_provisioning() {
  local id="$1"
  local api="$2"
  local attempts=0
  local state

  while [ "$attempts" -lt 180 ]; do
    arm_raw GET "$(resource_url "$id" "$api")"
    [ "$LAST_STATUS" = "200" ] || return 1
    state="$(jq -r '.properties.provisioningState // "Succeeded"' "$LAST_BODY")"
    case "$state" in
      Succeeded) return 0 ;;
      Failed|Canceled|Cancelled)
        print_arm_error "$LAST_BODY" >&2
        return 1
        ;;
    esac
    attempts=$((attempts + 1))
    sleep 5
  done
  return 1
}

wait_for_resource_absent() {
  local id="$1"
  local api="$2"
  local timeout="${3:-900}"
  local waited=0

  while resource_exists "$id" "$api"; do
    [ "$waited" -lt "$timeout" ] || return 1
    sleep 5
    waited=$((waited + 5))
  done
}

put_resource() {
  local id="$1"
  local api="$2"
  local body="$3"
  local result="$TMP_DIR/put-result-$RANDOM.json"

  arm_operation PUT "$(resource_url "$id" "$api")" "$body" "$result" ||
    die "Failed to create or update $id"
  wait_for_provisioning "$id" "$api" ||
    die "Resource did not reach Succeeded: $id"
}

patch_resource() {
  local id="$1"
  local api="$2"
  local body="$3"
  local result="$TMP_DIR/patch-result-$RANDOM.json"

  arm_operation PATCH "$(resource_url "$id" "$api")" "$body" "$result" ||
    die "Failed to update $id"
  wait_for_provisioning "$id" "$api" ||
    die "Resource update did not reach Succeeded: $id"
}

post_action() {
  local url="$1"
  local body_file="${2:-}"
  local result="$TMP_DIR/post-result-$RANDOM.json"
  arm_operation POST "$url" "$body_file" "$result"
}

delete_resource() {
  local id="$1"
  local api="$2"
  local result="$TMP_DIR/delete-result-$RANDOM.json"
  arm_operation DELETE "$(resource_url "$id" "$api")" "" "$result"
}

grant_access_json() {
  local id="$1"
  local access="$2"
  local secure="${3:-false}"
  local result body_file sas
  result="$TMP_DIR/grant-result-$RANDOM.json"
  body_file="$TMP_DIR/grant-body-$RANDOM.json"

  jq -n \
    --arg access "$access" \
    --argjson secure "$secure" \
    --argjson duration "$SAS_DURATION_SECONDS" \
    '{
      access:$access,
      durationInSeconds:$duration,
      fileFormat:"VHD",
      getSecureVMGuestStateSAS:$secure
    }' > "$body_file"

  arm_operation POST \
    "https://management.azure.com${id}/beginGetAccess?api-version=${DISK_API}" \
    "$body_file" "$result" || return 1

  sas="$(jq -r '
    .accessSAS
    // .output.accessSAS
    // .properties.output.accessSAS
    // empty
  ' "$result" 2>/dev/null || true)"
  if [ -z "$sas" ]; then
    # Some ARM operation endpoints return only Succeeded on the first poll.
    sleep 3
    arm_raw POST \
      "https://management.azure.com${id}/beginGetAccess?api-version=${DISK_API}" \
      "$body_file"
    if [ "$LAST_STATUS" = "200" ]; then
      cp "$LAST_BODY" "$result"
      sas="$(jq -r '.accessSAS // empty' "$result")"
    fi
  fi

  [ -n "$sas" ] || return 1
  jq -c '
    .properties.output
    // .output
    // .
    | {
        accessSAS,
        securityDataAccessSAS,
        securityMetadataAccessSAS
      }
  ' "$result"
}

revoke_access() {
  local id="$1"
  local result="$TMP_DIR/revoke-result-$RANDOM.json"
  arm_operation POST \
    "https://management.azure.com${id}/endGetAccess?api-version=${DISK_API}" \
    "" "$result" >/dev/null 2>&1 || warn "Could not revoke access for $id"
}

set_data_access() {
  local id="$1"
  local mode="$2"
  local body="$TMP_DIR/data-access-$RANDOM.json"

  case "$mode" in
    open)
      jq -n '{
        properties:{
          networkAccessPolicy:"AllowAll",
          publicNetworkAccess:"Enabled"
        }
      }' > "$body"
      ;;
    closed)
      jq -n '{
        properties:{
          networkAccessPolicy:"DenyAll",
          publicNetworkAccess:"Disabled"
        }
      }' > "$body"
      ;;
    *)
      die "Unsupported data-access mode: $mode"
      ;;
  esac

  patch_resource "$id" "$DISK_API" "$body"
}

close_data_access_best_effort() {
  local id="$1"
  local body="$TMP_DIR/close-data-access-$RANDOM.json"
  local result="$TMP_DIR/close-data-access-result-$RANDOM.json"

  jq -n '{
    properties:{
      networkAccessPolicy:"DenyAll",
      publicNetworkAccess:"Disabled"
    }
  }' > "$body"
  if ! arm_operation PATCH "$(resource_url "$id" "$DISK_API")" "$body" "$result"; then
    warn "Could not close public network access automatically: $id"
    return 1
  fi
}

wait_for_disk_unattached() {
  local id="$1"
  local attempts=0
  local state

  while [ "$attempts" -lt 120 ]; do
    arm_raw GET "$(resource_url "$id" "$DISK_API")"
    [ "$LAST_STATUS" = "200" ] || return 1
    state="$(jq -r '.properties.diskState // empty' "$LAST_BODY")"
    case "$state" in
      Unattached|Attached) return 0 ;;
      ActiveUpload|ReadyToUpload|Reserved) ;;
      *) log "Disk state for $(basename "$id"): ${state:-unknown}" ;;
    esac
    attempts=$((attempts + 1))
    sleep 5
  done
  return 1
}

vm_power_state() {
  local vm_id="$1"
  arm_raw GET "https://management.azure.com${vm_id}/instanceView?api-version=${VM_API}"
  if [ "$LAST_STATUS" != "200" ]; then
    echo "unknown"
    return
  fi
  jq -r '
    [.statuses[]? | select(.code | startswith("PowerState/")) | .code][0]
    // "PowerState/unknown"
  ' "$LAST_BODY"
}

wait_for_power_state() {
  local vm_id="$1"
  local expected="$2"
  local attempts=0
  local state

  while [ "$attempts" -lt 180 ]; do
    state="$(vm_power_state "$vm_id")"
    if [ "$state" = "PowerState/$expected" ]; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 5
  done
  return 1
}

deallocate_vm() {
  local vm_id="$1"
  local result="$TMP_DIR/deallocate-$RANDOM.json"
  log "Deallocating $(basename "$vm_id")"
  arm_operation POST \
    "https://management.azure.com${vm_id}/deallocate?api-version=${VM_API}" \
    "" "$result" || die "Could not deallocate $(basename "$vm_id")"
  wait_for_power_state "$vm_id" deallocated ||
    die "VM did not reach PowerState/deallocated: $(basename "$vm_id")"
}

start_vm() {
  local vm_id="$1"
  local result="$TMP_DIR/start-$RANDOM.json"
  log "Starting $(basename "$vm_id")"
  arm_operation POST \
    "https://management.azure.com${vm_id}/start?api-version=${VM_API}" \
    "" "$result" || die "Could not start $(basename "$vm_id")"
  wait_for_power_state "$vm_id" running ||
    die "VM did not reach PowerState/running: $(basename "$vm_id")"
}

confirm_phrase() {
  local phrase="$1"
  local entered
  printf '\nType exactly: %s\n> ' "$phrase"
  IFS= read -r entered
  [ "$entered" = "$phrase" ] || die "Confirmation did not match; no action was taken"
}

ask_yes_no() {
  local prompt="$1"
  local answer
  while true; do
    printf '%s [y/n]: ' "$prompt"
    IFS= read -r answer
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

ensure_access() {
  local source_file="$TMP_DIR/source-subscription.json"
  local destination_file="$TMP_DIR/destination-subscription.json"

  refresh_token
  arm_get_to_file "/subscriptions/$SOURCE_SUBSCRIPTION" "$SUBSCRIPTIONS_API" "$source_file" ||
    die "No access to source subscription $SOURCE_SUBSCRIPTION"
  arm_get_to_file "/subscriptions/$DESTINATION_SUBSCRIPTION" "$SUBSCRIPTIONS_API" "$destination_file" ||
    die "No Lighthouse access to destination subscription $DESTINATION_SUBSCRIPTION"

  log "Source: $(jq -r '.displayName' "$source_file")"
  log "Destination: $(jq -r '.displayName' "$destination_file")"
}

get_or_create_run_id() {
  local vm="$1"
  local state run_file
  state="$(vm_state_dir "$vm")"
  run_file="$state/run-id"
  mkdir -p "$state"
  chmod 700 "$state"
  if [ ! -s "$run_file" ]; then
    date -u '+%Y%m%dT%H%M%SZ' > "$run_file"
    chmod 600 "$run_file"
  fi
  cat "$run_file"
}

inventory_vm() {
  local vm="$1"
  local state source_rg vm_id nic_id nsg_id extensions_id
  local disk_ids disk_id disk_file disk_config disk_record
  local records_dir index

  state="$(vm_state_dir "$vm")"
  source_rg="$(source_resource_group "$vm")"
  vm_id="$(source_vm_id "$vm")"
  records_dir="$TMP_DIR/disk-records-$vm-$RANDOM"
  mkdir -p "$state" "$records_dir"
  chmod 700 "$state"

  log "Reading source manifest for $vm"
  arm_get_to_file "$vm_id" "$VM_API" "$state/source-vm.json" ||
    die "Source VM not found: $vm"

  nic_id="$(jq -r '.properties.networkProfile.networkInterfaces[0].id' "$state/source-vm.json")"
  arm_get_to_file "$nic_id" "$NETWORK_API" "$state/source-nic.json" ||
    die "Could not read source NIC for $vm"
  [ "$(jq '.properties.ipConfigurations | length' "$state/source-nic.json")" -eq 1 ] ||
    die "Source VM has multiple IP configurations; explicit mapping is required: $vm"

  nsg_id="$(jq -r '.properties.networkSecurityGroup.id // empty' "$state/source-nic.json")"
  if [ -n "$nsg_id" ]; then
    arm_get_to_file "$nsg_id" "$NETWORK_API" "$state/source-nsg.json" ||
      die "Could not read source NSG for $vm"
  else
    printf '{"properties":{"securityRules":[]}}' > "$state/source-nsg.json"
  fi

  extensions_id="${vm_id}/extensions"
  arm_get_to_file "$extensions_id" "$VM_API" "$state/source-extensions.json" ||
    printf '{"value":[]}' > "$state/source-extensions.json"

  disk_ids="$(jq -r '
    .properties.storageProfile.osDisk.managedDisk.id,
    (.properties.storageProfile.dataDisks[]?.managedDisk.id)
  ' "$state/source-vm.json")"

  index=0
  while IFS= read -r disk_id; do
    [ -n "$disk_id" ] || continue
    disk_file="$records_dir/disk-$index-source.json"
    arm_get_to_file "$disk_id" "$DISK_API" "$disk_file" ||
      die "Could not read disk: $disk_id"

    if [ "$index" -eq 0 ]; then
      disk_config="$(jq -c '.properties.storageProfile.osDisk' "$state/source-vm.json")"
      disk_record="$records_dir/record-$index.json"
      jq -n \
        --arg role "OS" \
        --argjson index "$index" \
        --argjson config "$disk_config" \
        --slurpfile resource "$disk_file" \
        '{index:$index,role:$role,lun:null,config:$config,resource:$resource[0]}' \
        > "$disk_record"
    else
      disk_config="$(jq -c --arg id "$disk_id" '
        .properties.storageProfile.dataDisks[]
        | select(.managedDisk.id == $id)
      ' "$state/source-vm.json")"
      disk_record="$records_dir/record-$index.json"
      jq -n \
        --arg role "DATA" \
        --argjson index "$index" \
        --argjson config "$disk_config" \
        --slurpfile resource "$disk_file" \
        '{index:$index,role:$role,lun:$config.lun,config:$config,resource:$resource[0]}' \
        > "$disk_record"
    fi
    index=$((index + 1))
  done <<EOF
$disk_ids
EOF

  jq -s 'sort_by(.index)' "$records_dir"/record-*.json > "$state/disks.json"
  chmod 600 "$state"/*.json

  jq -n \
    --arg capturedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg sourceSubscription "$SOURCE_SUBSCRIPTION" \
    --arg destinationSubscription "$DESTINATION_SUBSCRIPTION" \
    --arg sourceResourceGroup "$source_rg" \
    --arg destinationResourceGroup "$(destination_resource_group "$vm")" \
    --arg privateIp "$(destination_private_ip "$vm")" \
    --arg vnet "$(destination_vnet "$vm")" \
    --arg subnet "$(destination_subnet "$vm")" \
    '{
      capturedAt:$capturedAt,
      sourceSubscription:$sourceSubscription,
      destinationSubscription:$destinationSubscription,
      sourceResourceGroup:$sourceResourceGroup,
      destinationResourceGroup:$destinationResourceGroup,
      privateIp:$privateIp,
      destinationVnet:$vnet,
      destinationSubnet:$subnet
    }' > "$state/migration.json"

  log "Manifest saved in $state"
}

check_private_ip_available() {
  local vm="$1"
  local target_ip target_nic all_nics count
  target_ip="$(destination_private_ip "$vm")"
  target_nic="$(destination_nic_id "$vm")"
  all_nics="$TMP_DIR/all-destination-nics-$RANDOM.json"

  arm_list_to_file \
    "https://management.azure.com/subscriptions/$DESTINATION_SUBSCRIPTION/providers/Microsoft.Network/networkInterfaces?api-version=$NETWORK_API" \
    "$all_nics" || return 1

  count="$(jq --arg ip "$target_ip" --arg target "$target_nic" '
    [
      .value[]
      | select(.id != $target)
      | .properties.ipConfigurations[]?
      | select(.properties.privateIPAddress == $ip)
    ] | length
  ' "$all_nics")"

  [ "$count" -eq 0 ] ||
    die "Destination private IP is already assigned: $target_ip"
}

validate_source_safety() {
  local vm="$1"
  local state expected_ip actual_ip bad_disks ade_extensions asg_references
  local storage_uri license_type identity_type

  state="$(vm_state_dir "$vm")"
  expected_ip="$(destination_private_ip "$vm")"
  actual_ip="$(jq -r '.properties.ipConfigurations[0].properties.privateIPAddress' "$state/source-nic.json")"
  [ "$actual_ip" = "$expected_ip" ] ||
    die "Mapped destination IP $expected_ip does not match source NIC IP $actual_ip for $vm"

  bad_disks="$(jq '
    [
      .[]
      | select(
          (.resource.properties.encryption.type // "") != "EncryptionAtRestWithPlatformKey"
          or (.resource.properties.encryption.diskEncryptionSetId // "") != ""
          or (.resource.properties.encryptionSettingsCollection.enabled // false) == true
        )
    ] | length
  ' "$state/disks.json")"
  [ "$bad_disks" -eq 0 ] ||
    die "Unsupported disk encryption detected for $vm. Cross-tenant DES/ADE key migration requires a separate plan."

  ade_extensions="$(jq '
    [
      .value[]?
      | select(
          ((.properties.type // "") | ascii_downcase | contains("azurediskencryption"))
          or ((.properties.publisher // "") | ascii_downcase | contains("azure.security"))
             and ((.properties.type // "") | ascii_downcase | contains("diskencryption"))
        )
    ] | length
  ' "$state/source-extensions.json")"
  [ "$ade_extensions" -eq 0 ] ||
    die "Azure Disk Encryption extension detected for $vm. Verify Key Vault and key migration before proceeding."

  asg_references="$(jq -s '
    (
      [
        .[0].properties.securityRules[]?
        | select(
            ((.properties.sourceApplicationSecurityGroups // []) | length) > 0
            or ((.properties.destinationApplicationSecurityGroups // []) | length) > 0
          )
      ] | length
    )
    +
    (
      [
        .[1].properties.ipConfigurations[]?
        | select(((.properties.applicationSecurityGroups // []) | length) > 0)
      ] | length
    )
  ' "$state/source-nsg.json" "$state/source-nic.json")"
  [ "$asg_references" -eq 0 ] ||
    die "Application Security Group references detected for $vm. Create and remap destination ASGs before migration."

  storage_uri="$(jq -r '.properties.diagnosticsProfile.bootDiagnostics.storageUri // empty' "$state/source-vm.json")"
  if [ -n "$storage_uri" ]; then
    warn "$vm uses a source boot-diagnostics storage URI. Destination will use managed boot diagnostics instead."
  fi

  license_type="$(jq -r '.properties.licenseType // empty' "$state/source-vm.json")"
  if [ -n "$license_type" ] && [ "$license_type" != "None" ]; then
    if [ "$KEEP_LICENSE_TYPE" = "1" ]; then
      warn "$vm will preserve licenseType=$license_type because KEEP_LICENSE_TYPE=1."
    else
      warn "$vm source licenseType=$license_type will not be copied. Obtain customer approval before setting KEEP_LICENSE_TYPE=1."
    fi
  fi

  identity_type="$(jq -r '.identity.type // empty' "$state/source-vm.json")"
  if [ -n "$identity_type" ]; then
    warn "$vm has managed identity type '$identity_type'. Managed identities are tenant-bound and must be recreated and rebound in destination."
  fi
}

load_destination_compute_catalog() {
  local sku_file="$TMP_DIR/destination-skus.json"
  local usage_file="$TMP_DIR/destination-usages.json"

  if [ ! -s "$sku_file" ]; then
    arm_list_to_file \
      "https://management.azure.com/subscriptions/$DESTINATION_SUBSCRIPTION/providers/Microsoft.Compute/skus?api-version=$COMPUTE_SKU_API&%24filter=location%20eq%20%27$LOCATION%27" \
      "$sku_file" || die "Could not read destination VM SKU availability"
  fi

  if [ ! -s "$usage_file" ]; then
    arm_raw GET \
      "https://management.azure.com/subscriptions/$DESTINATION_SUBSCRIPTION/providers/Microsoft.Compute/locations/$LOCATION/usages?api-version=$COMPUTE_USAGE_API"
    [ "$LAST_STATUS" = "200" ] || {
      print_arm_error "$LAST_BODY" >&2
      die "Could not read destination compute quota"
    }
    cp "$LAST_BODY" "$usage_file"
    chmod 600 "$usage_file"
  fi

  printf '%s\n%s\n' "$sku_file" "$usage_file"
}

check_destination_compute_capacity() {
  local catalog sku_file usage_file requirements_dir vm size zone sku_record
  local location_restricted zone_restricted family vcpus record requirements
  local total_required total_current total_limit family_required family_current family_limit

  catalog="$(load_destination_compute_catalog)"
  sku_file="$(printf '%s\n' "$catalog" | sed -n '1p')"
  usage_file="$(printf '%s\n' "$catalog" | sed -n '2p')"
  requirements_dir="$TMP_DIR/compute-requirements-$RANDOM"
  mkdir -p "$requirements_dir"

  for vm in "$@"; do
    size="$(destination_vm_size "$vm")"
    zone="$(jq -r '.zones[0] // empty' "$(vm_state_dir "$vm")/source-vm.json")"
    sku_record="$requirements_dir/sku-$vm.json"

    jq --arg size "$size" '
      [.value[] | select(.resourceType=="virtualMachines" and .name==$size)][0] // empty
    ' "$sku_file" > "$sku_record"
    [ -s "$sku_record" ] && [ "$(cat "$sku_record")" != "null" ] ||
      die "Destination VM size was not found in $LOCATION: $size"

    location_restricted="$(jq --arg location "$LOCATION" '
      [
        .restrictions[]?
        | select(
            .type=="Location"
            and (((.restrictionInfo.locations // .values // []) | index($location)) != null)
          )
      ] | length
    ' "$sku_record")"
    [ "$location_restricted" -eq 0 ] ||
      die "VM size $size is restricted for subscription $DESTINATION_SUBSCRIPTION in $LOCATION. Set an approved TARGET_SIZE_* override."

    if [ -n "$zone" ]; then
      zone_restricted="$(jq --arg location "$LOCATION" --arg zone "$zone" '
        [
          .restrictions[]?
          | select(
              .type=="Zone"
              and (((.restrictionInfo.locations // .values // []) | index($location)) != null)
              and (((.restrictionInfo.zones // []) | index($zone)) != null)
            )
        ] | length
      ' "$sku_record")"
      [ "$zone_restricted" -eq 0 ] ||
        die "VM size $size is restricted in availability zone $zone of $LOCATION."
    fi

    family="$(jq -r '.family' "$sku_record")"
    vcpus="$(jq -r '[.capabilities[]? | select(.name=="vCPUs") | .value][0] // empty' "$sku_record")"
    [ -n "$family" ] && [ -n "$vcpus" ] ||
      die "Could not determine family/vCPU requirements for $size"

    record="$requirements_dir/requirement-$vm.json"
    jq -n \
      --arg vm "$vm" \
      --arg size "$size" \
      --arg family "$family" \
      --argjson vcpus "$vcpus" \
      '{vm:$vm,size:$size,family:$family,vcpus:$vcpus}' > "$record"
    log "Destination compute check: $vm -> $size ($vcpus vCPU, $family)"
  done

  requirements="$requirements_dir/requirements.json"
  jq -s '.' "$requirements_dir"/requirement-*.json > "$requirements"

  total_required="$(jq '[.[].vcpus] | add' "$requirements")"
  total_current="$(jq -r '.value[] | select((.name.value|ascii_downcase)=="cores") | .currentValue' "$usage_file")"
  total_limit="$(jq -r '.value[] | select((.name.value|ascii_downcase)=="cores") | .limit' "$usage_file")"
  [ -n "$total_current" ] && [ -n "$total_limit" ] ||
    die "Total regional vCPU quota was not returned for $LOCATION"
  [ $((total_current + total_required)) -le "$total_limit" ] ||
    die "Insufficient regional vCPU quota: current=$total_current required=$total_required limit=$total_limit"

  while IFS=$'\t' read -r family family_required; do
    family_current="$(jq -r --arg family "$family" '
      [.value[] | select((.name.value|ascii_downcase)==($family|ascii_downcase)) | .currentValue][0] // empty
    ' "$usage_file")"
    family_limit="$(jq -r --arg family "$family" '
      [.value[] | select((.name.value|ascii_downcase)==($family|ascii_downcase)) | .limit][0] // empty
    ' "$usage_file")"
    [ -n "$family_current" ] && [ -n "$family_limit" ] ||
      die "Quota entry not found for VM family $family"
    [ $((family_current + family_required)) -le "$family_limit" ] ||
      die "Insufficient $family quota: current=$family_current required=$family_required limit=$family_limit"
  done <<EOF
$(jq -r 'group_by(.family)[] | [.[0].family, ([.[].vcpus] | add)] | @tsv' "$requirements")
EOF
}

preflight_vm() {
  local vm="$1"
  local state vm_id target_vm subnet_id target_rg_id total_bytes total_gib disk_count

  inventory_vm "$vm"
  state="$(vm_state_dir "$vm")"
  vm_id="$(source_vm_id "$vm")"
  target_vm="$(destination_vm_id "$vm")"
  subnet_id="$(destination_subnet_id "$vm")"
  target_rg_id="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$(destination_resource_group "$vm")"

  resource_exists "$target_rg_id" "$RESOURCES_API" ||
    die "Destination resource group does not exist: $(destination_resource_group "$vm")"
  resource_exists "$subnet_id" "$NETWORK_API" ||
    die "Destination subnet does not exist: $(destination_vnet "$vm")/$(destination_subnet "$vm")"
  check_private_ip_available "$vm"

  if resource_exists "$target_vm" "$VM_API"; then
    warn "Destination VM already exists: $vm"
  fi

  validate_source_safety "$vm"
  check_destination_compute_capacity "$vm"

  disk_count="$(jq 'length' "$state/disks.json")"
  total_bytes="$(jq '[.[].resource.properties.diskSizeBytes] | add' "$state/disks.json")"
  total_gib="$(jq -n --argjson bytes "$total_bytes" '$bytes / 1073741824')"

  cat <<EOF

Preflight: $vm
  Source power:        $(vm_power_state "$vm_id")
  Destination RG:     $(destination_resource_group "$vm")
  Destination network:$(destination_vnet "$vm")/$(destination_subnet "$vm")
  Private IP:         $(destination_private_ip "$vm")
  Disks:              $disk_count
  Total provisioned:  $(printf '%.1f' "$total_gib") GiB
  Source VM size:     $(jq -r '.properties.hardwareProfile.vmSize' "$state/source-vm.json")
  Target VM size:     $(destination_vm_size "$vm")
  Security type:      $(jq -r '.properties.securityProfile.securityType // "Standard"' "$state/source-vm.json")
  Zone:               $(jq -r '.zones[0] // "Regional"' "$state/source-vm.json")
EOF
}

snapshot_name() {
  local vm="$1"
  local index="$2"
  local run_id="$3"
  local base
  base="$(printf '%s' "$vm" | tr '[:upper:]' '[:lower:]')"
  printf 'mig-%s-%02d-%s' "$base" "$index" "$run_id"
}

snapshot_all_disks() {
  local vm="$1"
  local state run_id source_rg disk_count index disk_json disk_id
  local snapshot snapshot_id body state_file

  state="$(vm_state_dir "$vm")"
  run_id="$(get_or_create_run_id "$vm")"
  source_rg="$(source_resource_group "$vm")"
  disk_count="$(jq 'length' "$state/disks.json")"

  log "Creating $disk_count snapshots for $vm"
  index=0
  while [ "$index" -lt "$disk_count" ]; do
    disk_json="$TMP_DIR/disk-$vm-$index.json"
    jq ".[$index]" "$state/disks.json" > "$disk_json"
    disk_id="$(jq -r '.resource.id' "$disk_json")"
    snapshot="$(snapshot_name "$vm" "$index" "$run_id")"
    snapshot_id="/subscriptions/$SOURCE_SUBSCRIPTION/resourceGroups/$source_rg/providers/Microsoft.Compute/snapshots/$snapshot"
    state_file="$state/disk-$index-state.json"

    if resource_exists "$snapshot_id" "$DISK_API"; then
      log "Snapshot already exists, reusing: $snapshot"
    else
      body="$TMP_DIR/snapshot-body-$vm-$index.json"
      jq -n \
        --arg location "$LOCATION" \
        --arg source "$disk_id" \
        '{
          location:$location,
          sku:{name:"Standard_LRS"},
          properties:{
            creationData:{createOption:"Copy",sourceResourceId:$source},
            incremental:false,
            networkAccessPolicy:"AllowAll",
            publicNetworkAccess:"Enabled"
          }
        }' > "$body"
      log "Creating snapshot $snapshot"
      put_resource "$snapshot_id" "$DISK_API" "$body"
    fi

    if [ -f "$state_file" ]; then
      jq \
        --arg snapshotId "$snapshot_id" \
        --arg destinationDiskId "/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$(destination_resource_group "$vm")/providers/Microsoft.Compute/disks/$(jq -r '.resource.name' "$disk_json")" \
        '
          .snapshotId=$snapshotId
          | .destinationDiskId=$destinationDiskId
          | if .status == "Copied" then . else .status="Snapshotted" end
        ' "$state_file" > "$state_file.tmp"
      mv "$state_file.tmp" "$state_file"
    else
      jq -n \
        --arg snapshotId "$snapshot_id" \
        --arg destinationDiskId "/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$(destination_resource_group "$vm")/providers/Microsoft.Compute/disks/$(jq -r '.resource.name' "$disk_json")" \
        --arg status "Snapshotted" \
        '{snapshotId:$snapshotId,destinationDiskId:$destinationDiskId,status:$status}' \
        > "$state_file"
    fi
    chmod 600 "$state_file"
    index=$((index + 1))
  done
}

copy_one_disk() (
  set -Eeuo pipefail
  INTERACTIVE_AUTH_ALLOWED=0

  local vm="$1"
  local index="$2"
  local state disk_json state_file snapshot_id destination_disk_id
  local disk_name disk_size_bytes upload_size_bytes sku role os_type hyperv security_profile
  local security_type secure=false create_option
  local zones
  local body source_access="" destination_access=""
  local source_sas="" destination_sas=""
  local source_security_sas="" destination_security_sas=""
  local azcopy_log vmgs_log
  local source_granted=0 destination_granted=0
  local destination_exists=false tracked_status disk_state

  state="$(vm_state_dir "$vm")"
  disk_json="$TMP_DIR/worker-$vm-$index-$RANDOM.json"
  jq ".[$index]" "$state/disks.json" > "$disk_json"
  state_file="$state/disk-$index-state.json"
  snapshot_id="$(jq -r '.snapshotId' "$state_file")"
  destination_disk_id="$(jq -r '.destinationDiskId' "$state_file")"
  disk_name="$(jq -r '.resource.name' "$disk_json")"
  disk_size_bytes="$(jq -r '.resource.properties.diskSizeBytes' "$disk_json")"
  upload_size_bytes=$((disk_size_bytes + 512))
  sku="$(jq -r '.resource.sku.name' "$disk_json")"
  role="$(jq -r '.role' "$disk_json")"
  os_type="$(jq -r '.resource.properties.osType // empty' "$disk_json")"
  hyperv="$(jq -r '.resource.properties.hyperVGeneration // empty' "$disk_json")"
  security_profile="$(jq -c '.resource.properties.securityProfile // null' "$disk_json")"
  security_type="$(printf '%s' "$security_profile" | jq -r '.securityType // empty')"
  zones="$(jq -c '.resource.zones // null' "$disk_json")"
  case "$security_type" in
    TrustedLaunch)
      [ "$role" = "OS" ] ||
        die "[$vm] Secure profile was found on a non-OS disk: $disk_name"
      secure=true
      create_option="UploadPreparedSecure"
      ;;
    ConfidentialVM_*)
      die "[$vm] Confidential VM disks require VM metadata and key handling not implemented by this script"
      ;;
    *)
      create_option="Upload"
      ;;
  esac

  cleanup_disk_access() {
    if [ "$destination_granted" -eq 1 ]; then
      revoke_access "$destination_disk_id"
    fi
    if [ "$source_granted" -eq 1 ]; then
      revoke_access "$snapshot_id"
    fi
    close_data_access_best_effort "$destination_disk_id" || true
    close_data_access_best_effort "$snapshot_id" || true
  }
  trap cleanup_disk_access EXIT

  tracked_status="$(jq -r '.status // empty' "$state_file")"
  if resource_exists "$destination_disk_id" "$DISK_API"; then
    destination_exists=true
    arm_raw GET "$(resource_url "$destination_disk_id" "$DISK_API")"
    disk_state="$(jq -r '.properties.diskState // empty' "$LAST_BODY")"
    case "$disk_state" in
      Unattached)
        if [ "$tracked_status" = "Copied" ]; then
          log "[$vm] Destination disk already complete, skipping: $disk_name"
          exit 0
        fi
        warn "[$vm] Unverified destination disk will be recreated: $disk_name"
        delete_resource "$destination_disk_id" "$DISK_API" ||
          die "[$vm] Could not remove unverified disk: $disk_name"
        destination_exists=false
        ;;
      Attached)
        [ "$tracked_status" = "Copied" ] ||
          die "[$vm] Destination disk is attached but has no completed-copy marker: $disk_name"
        log "[$vm] Destination disk already attached and verified: $disk_name"
        exit 0
        ;;
      ActiveUpload|ReadyToUpload)
        log "[$vm] Resuming upload to existing disk: $disk_name"
        ;;
      *)
        die "[$vm] Destination disk has an unsupported state: $disk_name"
        ;;
    esac
  fi

  if [ "$destination_exists" = false ]; then
    body="$TMP_DIR/upload-disk-body-$vm-$index-$RANDOM.json"
    if [ "$role" = "OS" ]; then
      jq -n \
        --arg location "$LOCATION" \
        --arg sku "$sku" \
        --arg osType "$os_type" \
        --arg hyperVGeneration "$hyperv" \
        --arg createOption "$create_option" \
        --argjson uploadSizeBytes "$upload_size_bytes" \
        --argjson securityProfile "$security_profile" \
        --argjson zones "$zones" \
        '{
          location:$location,
          sku:{name:$sku},
          properties:{
            osType:$osType,
            hyperVGeneration:$hyperVGeneration,
            creationData:{createOption:$createOption,uploadSizeBytes:$uploadSizeBytes},
            networkAccessPolicy:"AllowAll",
            publicNetworkAccess:"Enabled"
          }
        }
        | if $securityProfile != null
          then .properties.securityProfile=$securityProfile
          else .
          end
        | if $zones != null
          then .zones=$zones
          else .
          end' > "$body"
    else
      jq -n \
        --arg location "$LOCATION" \
        --arg sku "$sku" \
        --argjson uploadSizeBytes "$upload_size_bytes" \
        --argjson zones "$zones" \
        '{
          location:$location,
          sku:{name:$sku},
          properties:{
            creationData:{createOption:"Upload",uploadSizeBytes:$uploadSizeBytes},
            networkAccessPolicy:"AllowAll",
            publicNetworkAccess:"Enabled"
          }
        }
        | if $zones != null
          then .zones=$zones
          else .
          end' > "$body"
    fi

    log "[$vm] Creating upload disk: $disk_name"
    put_resource "$destination_disk_id" "$DISK_API" "$body"
  fi

  log "[$vm] Opening temporary public SAS access for: $disk_name"
  set_data_access "$snapshot_id" open
  set_data_access "$destination_disk_id" open

  log "[$vm] Granting temporary access for: $disk_name"
  source_access="$(grant_access_json "$snapshot_id" Read "$secure")" ||
    die "[$vm] Could not grant read access to snapshot for $disk_name"
  source_granted=1
  destination_access="$(grant_access_json "$destination_disk_id" Write "$secure")" ||
    die "[$vm] Could not grant write access to destination disk $disk_name"
  destination_granted=1
  source_sas="$(printf '%s' "$source_access" | jq -r '.accessSAS // empty')"
  destination_sas="$(printf '%s' "$destination_access" | jq -r '.accessSAS // empty')"
  [ -n "$source_sas" ] && [ -n "$destination_sas" ] ||
    die "[$vm] OS/data SAS pair was not returned for $disk_name"

  if [ "$secure" = true ]; then
    source_security_sas="$(printf '%s' "$source_access" | jq -r '.securityDataAccessSAS // empty')"
    destination_security_sas="$(printf '%s' "$destination_access" | jq -r '.securityDataAccessSAS // empty')"
    [ -n "$source_security_sas" ] && [ -n "$destination_security_sas" ] ||
      die "[$vm] Trusted Launch VMGS SAS pair was not returned for $disk_name"
  fi

  azcopy_log="$TMP_DIR/azcopy-$vm-$index-$RANDOM.log"
  log "[$vm] Copying disk $disk_name"
  if ! azcopy copy "$source_sas" "$destination_sas" \
    --blob-type PageBlob \
    --check-length=true \
    --output-type text >"$azcopy_log" 2>&1; then
    sed -E 's#https://[^[:space:]]+#<redacted-sas>#g' "$azcopy_log" >&2
    die "[$vm] AzCopy failed for $disk_name"
  fi

  grep -E 'Final Job Status|Number of File Transfers|Number of Folder Transfers|Total Number of Transfers' \
    "$azcopy_log" >&2 || true

  if [ "$secure" = true ]; then
    vmgs_log="$TMP_DIR/azcopy-vmgs-$vm-$index-$RANDOM.log"
    log "[$vm] Copying Trusted Launch VM guest state for $disk_name"
    if ! azcopy copy "$source_security_sas" "$destination_security_sas" \
      --blob-type PageBlob \
      --check-length=true \
      --output-type text >"$vmgs_log" 2>&1; then
      sed -E 's#https://[^[:space:]]+#<redacted-sas>#g' "$vmgs_log" >&2
      die "[$vm] AzCopy failed for Trusted Launch VM guest state: $disk_name"
    fi
    grep -E 'Final Job Status|Number of File Transfers|Number of Folder Transfers|Total Number of Transfers' \
      "$vmgs_log" >&2 || true
  fi

  revoke_access "$destination_disk_id"
  destination_granted=0
  revoke_access "$snapshot_id"
  source_granted=0
  wait_for_disk_unattached "$destination_disk_id" ||
    die "[$vm] Destination disk did not leave upload state: $disk_name"
  set_data_access "$destination_disk_id" closed
  set_data_access "$snapshot_id" closed

  jq --arg status "Copied" --arg completedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.status=$status | .completedAt=$completedAt' "$state_file" > "$state_file.tmp"
  mv "$state_file.tmp" "$state_file"
  chmod 600 "$state_file"
  log "[$vm] Disk copy complete: $disk_name"
)

copy_all_disks() {
  local vm="$1"
  local state disk_count index running pid failed=0
  local pids=()

  require_azcopy
  state="$(vm_state_dir "$vm")"
  disk_count="$(jq 'length' "$state/disks.json")"
  [ "$disk_count" -gt 0 ] || die "No source disks were found for $vm"

  log "Copying $disk_count disks with concurrency $COPY_CONCURRENCY"
  index=0
  while [ "$index" -lt "$disk_count" ]; do
    while true; do
      running="$(jobs -pr | wc -l | tr -d ' ')"
      [ "$running" -lt "$COPY_CONCURRENCY" ] && break
      sleep 2
    done
    refresh_token
    copy_one_disk "$vm" "$index" &
    pid=$!
    pids+=("$pid")
    index=$((index + 1))
  done

  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      failed=1
    fi
  done

  [ "$failed" -eq 0 ] || die "One or more disk transfers failed for $vm"
}

copy_nsg() {
  local vm="$1"
  local state source_nsg nsg_name destination_nsg_id body

  state="$(vm_state_dir "$vm")"
  source_nsg="$state/source-nsg.json"
  nsg_name="$(jq -r '.name // empty' "$source_nsg")"
  [ -n "$nsg_name" ] || nsg_name="$vm-nsg"
  destination_nsg_id="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$(destination_resource_group "$vm")/providers/Microsoft.Network/networkSecurityGroups/$nsg_name"

  if resource_exists "$destination_nsg_id" "$NETWORK_API"; then
    log "Destination NSG already exists: $nsg_name"
  else
    body="$TMP_DIR/nsg-body-$vm.json"
    jq --arg location "$LOCATION" '{
      location:$location,
      properties:{securityRules:(.properties.securityRules // [])},
      tags:(.tags // {})
    }' "$source_nsg" > "$body"
    log "Creating destination NSG: $nsg_name"
    put_resource "$destination_nsg_id" "$NETWORK_API" "$body"
  fi
  printf '%s' "$destination_nsg_id"
}

create_public_ip_if_required() {
  local vm="$1"
  local pip_id body

  [ "$vm" = "RECAZSRVHO-VM-P" ] || return 0
  pip_id="$(destination_pip_id "$vm")"
  if resource_exists "$pip_id" "$NETWORK_API"; then
    log "Destination public IP already exists: $vm-pip"
  else
    body="$TMP_DIR/pip-body-$vm.json"
    jq -n --arg location "$LOCATION" '{
      location:$location,
      sku:{name:"Standard"},
      properties:{
        publicIPAllocationMethod:"Static",
        publicIPAddressVersion:"IPv4",
        idleTimeoutInMinutes:4
      }
    }' > "$body"
    log "Creating new public IP: $vm-pip"
    put_resource "$pip_id" "$NETWORK_API" "$body"
  fi
  printf '%s' "$pip_id"
}

create_destination_nic() {
  local vm="$1"
  local state source_nic nsg_id pip_id nic_id body accelerated
  local ip_forwarding dns_servers

  state="$(vm_state_dir "$vm")"
  source_nic="$state/source-nic.json"
  nic_id="$(destination_nic_id "$vm")"
  nsg_id="$(copy_nsg "$vm")"
  pip_id="$(create_public_ip_if_required "$vm")"
  accelerated="$(jq -r '.properties.enableAcceleratedNetworking // false' "$source_nic")"
  ip_forwarding="$(jq -r '.properties.enableIPForwarding // false' "$source_nic")"
  dns_servers="$(jq -c '.properties.dnsSettings.dnsServers // []' "$source_nic")"

  if resource_exists "$nic_id" "$NETWORK_API"; then
    log "Destination NIC already exists: $vm-nic"
    return
  fi

  body="$TMP_DIR/nic-body-$vm.json"
  jq -n \
    --arg location "$LOCATION" \
    --arg privateIp "$(destination_private_ip "$vm")" \
    --arg subnetId "$(destination_subnet_id "$vm")" \
    --arg nsgId "$nsg_id" \
    --arg pipId "$pip_id" \
    --argjson accelerated "$accelerated" \
    --argjson ipForwarding "$ip_forwarding" \
    --argjson dnsServers "$dns_servers" \
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
    | if $pipId != ""
      then .properties.ipConfigurations[0].properties.publicIPAddress={id:$pipId}
      else .
      end
    | if ($dnsServers | length) > 0
      then .properties.dnsSettings={dnsServers:$dnsServers}
      else .
      end' > "$body"

  log "Creating destination NIC with IP $(destination_private_ip "$vm")"
  put_resource "$nic_id" "$NETWORK_API" "$body"
}

create_destination_vm() {
  local vm="$1"
  local state source_vm disks vm_id nic_id disk_prefix body keep_license

  state="$(vm_state_dir "$vm")"
  source_vm="$state/source-vm.json"
  disks="$state/disks.json"
  vm_id="$(destination_vm_id "$vm")"
  nic_id="$(destination_nic_id "$vm")"
  disk_prefix="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$(destination_resource_group "$vm")/providers/Microsoft.Compute/disks/"

  if resource_exists "$vm_id" "$VM_API"; then
    log "Destination VM already exists: $vm"
    return
  fi

  body="$TMP_DIR/vm-body-$vm.json"
  keep_license=false
  [ "$KEEP_LICENSE_TYPE" = "1" ] && keep_license=true
  jq -n \
    --arg location "$LOCATION" \
    --arg nicId "$nic_id" \
    --arg diskPrefix "$disk_prefix" \
    --arg targetSize "$(destination_vm_size "$vm")" \
    --argjson keepLicenseType "$keep_license" \
    --slurpfile vm "$source_vm" \
    --slurpfile disks "$disks" \
    '
    def destinationDisk($name): {id:($diskPrefix + $name)};
    ($vm[0]) as $source
    | ($disks[0]) as $allDisks
    | ($allDisks[] | select(.role=="OS")) as $os
    | {
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
              $allDisks[]
              | select(.role=="DATA")
              | {
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
          }
        }
      }
    | if $source.properties.securityProfile != null
      then .properties.securityProfile=$source.properties.securityProfile
      else .
      end
    | if ($source.properties.diagnosticsProfile.bootDiagnostics.enabled // false) == true
      then .properties.diagnosticsProfile={bootDiagnostics:{enabled:true}}
      else .
      end
    | if $keepLicenseType
         and ($source.properties.licenseType // "") != ""
         and $source.properties.licenseType != "None"
      then .properties.licenseType=$source.properties.licenseType
      else .
      end
    | if $source.zones != null
      then .zones=$source.zones
      else .
      end
    ' > "$body"

  log "Creating destination VM: $vm"
  put_resource "$vm_id" "$VM_API" "$body"
  wait_for_power_state "$vm_id" running ||
    die "Destination VM did not reach PowerState/running: $vm"
}

print_post_deployment_actions() {
  local vm="$1"
  local state
  state="$(vm_state_dir "$vm")"

  cat <<EOF

Destination VM is running: $vm

Required manual validation:
  1. Boot diagnostics and Windows event logs.
  2. All volumes, drive letters, LUNs and services.
  3. DNS, domain authentication and application dependencies.
  4. Application owner functional test.
  5. Backup, monitoring, Defender and SQL IaaS registration.

Source extensions to recreate deliberately:
EOF
  jq -r '.value[]? | "  - \(.name): \(.properties.publisher)/\(.properties.type)"' \
    "$state/source-extensions.json"

  if [ "$vm" = "RECAZSRVHO-VM-P" ]; then
    arm_raw GET "$(resource_url "$(destination_pip_id "$vm")" "$NETWORK_API")"
    if [ "$LAST_STATUS" = "200" ]; then
      printf '\nNew public IP: %s\n' "$(jq -r '.properties.ipAddress // "Pending"' "$LAST_BODY")"
      echo "Update public DNS, firewall rules and allowlists."
    fi
  fi
}

reset_rolled_back_migration() {
  local vm="$1"
  local state destination_id state_file snapshot_id destination_disk_id

  state="$(vm_state_dir "$vm")"
  [ -f "$state/rolled-back-at" ] || return 0

  cat <<EOF

$vm was rolled back at $(cat "$state/rolled-back-at").

The source VM has been allowed to change since that point. Existing migration
snapshots, destination disks and Copied markers are stale and MUST NOT be reused.
This reset permanently deletes the stale destination VM, destination disks and
source migration snapshots before creating a new run.
EOF
  confirm_phrase "RESET STALE MIGRATION $vm"

  destination_id="$(destination_vm_id "$vm")"
  if resource_exists "$destination_id" "$VM_API"; then
    if [ "$(vm_power_state "$destination_id")" != "PowerState/deallocated" ]; then
      deallocate_vm "$destination_id"
    fi
    log "Deleting stale destination VM: $vm"
    delete_resource "$destination_id" "$VM_API" ||
      die "Could not delete stale destination VM: $vm"
    wait_for_resource_absent "$destination_id" "$VM_API" ||
      die "Timed out waiting for stale destination VM deletion: $vm"
  fi

  for state_file in "$state"/disk-*-state.json; do
    [ -f "$state_file" ] || continue
    destination_disk_id="$(jq -r '.destinationDiskId // empty' "$state_file")"
    snapshot_id="$(jq -r '.snapshotId // empty' "$state_file")"

    if [ -n "$destination_disk_id" ] && resource_exists "$destination_disk_id" "$DISK_API"; then
      revoke_access "$destination_disk_id" || true
      close_data_access_best_effort "$destination_disk_id" || true
      log "Deleting stale destination disk: $(basename "$destination_disk_id")"
      delete_resource "$destination_disk_id" "$DISK_API" ||
        die "Could not delete stale destination disk: $(basename "$destination_disk_id")"
    fi

    if [ -n "$snapshot_id" ] && resource_exists "$snapshot_id" "$DISK_API"; then
      revoke_access "$snapshot_id" || true
      close_data_access_best_effort "$snapshot_id" || true
      log "Deleting stale source snapshot: $(basename "$snapshot_id")"
      delete_resource "$snapshot_id" "$DISK_API" ||
        die "Could not delete stale source snapshot: $(basename "$snapshot_id")"
    fi
  done

  for state_file in "$state"/disk-*-state.json; do
    [ -f "$state_file" ] && rm -f "$state_file"
  done
  rm -f "$state/run-id" "$state/accepted-at" "$state/rolled-back-at"
  log "Stale migration state reset for $vm"
}

migrate_vm() {
  local vm="$1"
  local source_id destination_id

  case "$vm" in
    AZINTBK-VM-P|AZINTCDC-VM-P)
      die "Use the internal database wave; these VMs share one routed subnet"
      ;;
  esac

  reset_rolled_back_migration "$vm"
  preflight_vm "$vm"
  require_azcopy
  source_id="$(source_vm_id "$vm")"
  destination_id="$(destination_vm_id "$vm")"

  if resource_exists "$destination_id" "$VM_API"; then
    die "Destination VM already exists. Use status or validation instead."
  fi

  cat <<EOF

This operation will:
  - Deallocate the source VM.
  - Snapshot every attached managed disk.
  - Copy each snapshot to a managed disk in the destination tenant.
  - Recreate the NSG and NIC with the original private IP.
  - Pause for the separate network cutover.
  - Create and start the destination VM.

The source VM will remain deallocated for rollback.
EOF

  if [ "$vm" = "ADCDCDC-VM-P" ]; then
    cat <<'EOF'

Before continuing, validate AD DS and DNS health with dcdiag and repadmin,
confirm VM-Generation ID support, and create a current System State backup.
If these safeguards cannot be confirmed, do not clone this domain controller;
deploy and promote a new DC instead.
EOF
    confirm_phrase "AD HEALTH AND SYSTEM STATE VERIFIED $vm"
  fi

  confirm_phrase "SERVICES STOPPED $vm"
  deallocate_vm "$source_id"
  snapshot_all_disks "$vm"
  copy_all_disks "$vm"
  create_destination_nic "$vm"

  cat <<EOF

Disk and NIC preparation is complete.

STOP HERE and ask the network team to execute the approved routing/VPN cutover
for $(destination_vnet "$vm")/$(destination_subnet "$vm").

Do not continue while the source and destination paths advertise the same
prefix simultaneously.
EOF
  confirm_phrase "NETWORK CUTOVER COMPLETE $vm"
  create_destination_vm "$vm"
  print_post_deployment_actions "$vm"
}

migrate_internal_database_wave() {
  local vm destination_id
  local wave_vms=("AZINTBK-VM-P" "AZINTCDC-VM-P")

  require_azcopy
  for vm in "${wave_vms[@]}"; do
    reset_rolled_back_migration "$vm"
    preflight_vm "$vm"
    destination_id="$(destination_vm_id "$vm")"
    if resource_exists "$destination_id" "$VM_API"; then
      warn "Destination VM already exists and will be reused: $vm"
    fi
  done
  check_destination_compute_capacity "${wave_vms[@]}"

  cat <<'EOF'

This coordinated wave migrates AZINTBK-VM-P and AZINTCDC-VM-P together because
both use cdc-vnet-spoke4/cdc-snet-spoke4 (172.17.44.96/27).

Both source VMs will remain deallocated for rollback.
EOF
  confirm_phrase "SERVICES STOPPED AZINT DATABASE WAVE"

  for vm in "${wave_vms[@]}"; do
    if [ "$(vm_power_state "$(source_vm_id "$vm")")" != "PowerState/deallocated" ]; then
      deallocate_vm "$(source_vm_id "$vm")"
    fi
  done

  for vm in "${wave_vms[@]}"; do
    snapshot_all_disks "$vm"
  done
  for vm in "${wave_vms[@]}"; do
    copy_all_disks "$vm"
  done
  for vm in "${wave_vms[@]}"; do
    create_destination_nic "$vm"
  done

  cat <<'EOF'

Both VMs are copied and their destination NICs are ready.

STOP HERE and ask the network team to cut 172.17.44.96/27 to the destination
tenant. Do not continue while both environments advertise this prefix.
EOF
  confirm_phrase "NETWORK CUTOVER COMPLETE AZINT DATABASE WAVE"

  for vm in "${wave_vms[@]}"; do
    create_destination_vm "$vm"
    print_post_deployment_actions "$vm"
  done
}

validate_vm() {
  local vm="$1"
  local state vm_id expected_disks actual_disks ip power accepted=1

  state="$(vm_state_dir "$vm")"
  [ -f "$state/disks.json" ] || inventory_vm "$vm"
  vm_id="$(destination_vm_id "$vm")"
  resource_exists "$vm_id" "$VM_API" ||
    die "Destination VM does not exist: $vm"

  power="$(vm_power_state "$vm_id")"
  expected_disks="$(jq 'length' "$state/disks.json")"
  arm_raw GET "$(resource_url "$vm_id" "$VM_API")"
  actual_disks="$(jq '1 + (.properties.storageProfile.dataDisks | length)' "$LAST_BODY")"
  arm_raw GET "$(resource_url "$(destination_nic_id "$vm")" "$NETWORK_API")"
  ip="$(jq -r '.properties.ipConfigurations[0].properties.privateIPAddress' "$LAST_BODY")"

  cat <<EOF

Automated validation for $vm:
  Power state:    $power
  Attached disks: $actual_disks / $expected_disks
  Private IP:     $ip / $(destination_private_ip "$vm")
EOF

  [ "$power" = "PowerState/running" ] || accepted=0
  [ "$actual_disks" -eq "$expected_disks" ] || accepted=0
  [ "$ip" = "$(destination_private_ip "$vm")" ] || accepted=0

  ask_yes_no "Did Windows boot without critical errors?" || accepted=0
  ask_yes_no "Are all volumes and drive letters correct?" || accepted=0
  ask_yes_no "Are DNS, domain and required network paths working?" || accepted=0
  ask_yes_no "Did the application owner approve the functional test?" || accepted=0
  ask_yes_no "Are security, monitoring and backup actions complete?" || accepted=0

  if [ "$accepted" -eq 1 ]; then
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$state/accepted-at"
    chmod 600 "$state/accepted-at"
    log "Validation accepted for $vm"
  else
    warn "Validation is incomplete or failed. Do not clean up source resources."
    return 1
  fi
}

rollback_vm() {
  local vm="$1"
  local source_id destination_id

  case "$vm" in
    AZINTBK-VM-P|AZINTCDC-VM-P)
      die "Use the internal database wave rollback; these VMs share one routed subnet"
      ;;
  esac

  source_id="$(source_vm_id "$vm")"
  destination_id="$(destination_vm_id "$vm")"
  resource_exists "$destination_id" "$VM_API" ||
    die "Destination VM does not exist: $vm"

  cat <<EOF

Rollback will deallocate the destination VM. Destination disks and snapshots
will be retained for analysis. The source VM will only be started after you
confirm that the network team restored routing/VPN to the source subscription.
EOF
  if [ "$vm" = "ADCDCDC-VM-P" ]; then
    cat <<'EOF'

DOMAIN CONTROLLER WARNING:
Rollback can discard directory changes accepted by the destination DC and can
cause USN/replication divergence if AD virtualization safeguards are not valid.
Confirm which DC owns the authoritative post-cutover changes, verify no source
and destination instance can run simultaneously, and obtain AD owner approval.
EOF
    confirm_phrase "AD ROLLBACK APPROVED $vm"
  fi
  confirm_phrase "ROLLBACK $vm"
  deallocate_vm "$destination_id"

  echo
  echo "Ask the network team to restore the source route now."
  confirm_phrase "SOURCE NETWORK RESTORED $vm"
  start_vm "$source_id"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$(vm_state_dir "$vm")/rolled-back-at"
  chmod 600 "$(vm_state_dir "$vm")/rolled-back-at"
  rm -f "$(vm_state_dir "$vm")/accepted-at"
  log "Rollback completed. Source VM is running: $vm"
}

rollback_internal_database_wave() {
  local vm destination_id
  local wave_vms=("AZINTBK-VM-P" "AZINTCDC-VM-P")

  cat <<'EOF'

This rolls back the complete 172.17.44.96/27 internal database wave.
Destination disks and snapshots will be retained for analysis.
EOF
  confirm_phrase "ROLLBACK AZINT DATABASE WAVE"

  for vm in "${wave_vms[@]}"; do
    destination_id="$(destination_vm_id "$vm")"
    if resource_exists "$destination_id" "$VM_API"; then
      deallocate_vm "$destination_id"
    fi
  done

  echo
  echo "Ask the network team to restore 172.17.44.96/27 to the source tenant."
  confirm_phrase "SOURCE NETWORK RESTORED AZINT DATABASE WAVE"

  for vm in "${wave_vms[@]}"; do
    start_vm "$(source_vm_id "$vm")"
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$(vm_state_dir "$vm")/rolled-back-at"
    chmod 600 "$(vm_state_dir "$vm")/rolled-back-at"
    rm -f "$(vm_state_dir "$vm")/accepted-at"
  done
  log "Internal database wave rollback completed"
}

test_destination_disk_policy() (
  set -Eeuo pipefail

  local vm="$1"
  local rg disk_name disk_id body access
  local disk_created=0

  rg="$(destination_resource_group "$vm")"
  disk_name="migration-policy-test-$(date -u '+%Y%m%d%H%M%S')"
  disk_id="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$rg/providers/Microsoft.Compute/disks/$disk_name"
  body="$TMP_DIR/policy-test-disk-$RANDOM.json"

  cleanup_policy_test() {
    if [ "$disk_created" -eq 1 ] && resource_exists "$disk_id" "$DISK_API"; then
      revoke_access "$disk_id" || true
      close_data_access_best_effort "$disk_id" || true
      delete_resource "$disk_id" "$DISK_API" || true
    fi
  }
  trap cleanup_policy_test EXIT

  cat <<EOF

This write test creates a temporary 1 GiB upload disk in destination RG $rg,
grants and revokes a write SAS, disables public access, and deletes the disk.
It validates destination RBAC and Azure Policy behavior without copying data.
EOF
  confirm_phrase "CREATE POLICY TEST DISK $vm"

  jq -n \
    --arg location "$LOCATION" \
    --argjson uploadSizeBytes 1073742336 \
    '{
      location:$location,
      sku:{name:"Standard_LRS"},
      properties:{
        creationData:{createOption:"Upload",uploadSizeBytes:$uploadSizeBytes},
        networkAccessPolicy:"AllowAll",
        publicNetworkAccess:"Enabled"
      }
    }' > "$body"

  log "Creating temporary destination policy-test disk: $disk_name"
  put_resource "$disk_id" "$DISK_API" "$body"
  disk_created=1
  access="$(grant_access_json "$disk_id" Write false)" ||
    die "Destination policy test could not grant a write SAS"
  [ -n "$(printf '%s' "$access" | jq -r '.accessSAS // empty')" ] ||
    die "Destination policy test did not return a write SAS"
  revoke_access "$disk_id"
  set_data_access "$disk_id" closed
  delete_resource "$disk_id" "$DISK_API" ||
    die "Could not delete temporary destination policy-test disk"
  disk_created=0
  log "Destination disk write-policy test passed for RG $rg"
)

cleanup_snapshots() {
  local vm="$1"
  local state disk_count index state_file snapshot_id

  state="$(vm_state_dir "$vm")"
  [ -f "$state/accepted-at" ] ||
    die "No formal validation marker exists for $vm"
  [ -f "$state/disks.json" ] || die "No state exists for $vm"

  cat <<EOF

This cleanup only removes temporary migration snapshots in the source
subscription. It does not delete source VMs, source disks, destination VMs or
destination disks.
EOF
  confirm_phrase "DELETE MIGRATION SNAPSHOTS $vm"

  disk_count="$(jq 'length' "$state/disks.json")"
  index=0
  while [ "$index" -lt "$disk_count" ]; do
    state_file="$state/disk-$index-state.json"
    if [ -f "$state_file" ]; then
      snapshot_id="$(jq -r '.snapshotId' "$state_file")"
      if resource_exists "$snapshot_id" "$DISK_API"; then
        revoke_access "$snapshot_id"
        log "Deleting snapshot $(basename "$snapshot_id")"
        delete_resource "$snapshot_id" "$DISK_API" ||
          die "Could not delete snapshot $(basename "$snapshot_id")"
      fi
    fi
    index=$((index + 1))
  done
  log "Temporary snapshots removed for $vm"
}

show_status() {
  local vm source_state destination_state destination_id state copied total accepted

  printf '\n%-20s %-24s %-24s %-12s %-12s\n' \
    "VM" "SOURCE" "DESTINATION" "DISKS" "ACCEPTED"
  printf '%s\n' "------------------------------------------------------------------------------------------------"

  for vm in "${VM_NAMES[@]}"; do
    source_state="$(vm_power_state "$(source_vm_id "$vm")")"
    destination_id="$(destination_vm_id "$vm")"
    if resource_exists "$destination_id" "$VM_API"; then
      destination_state="$(vm_power_state "$destination_id")"
    else
      destination_state="NotCreated"
    fi

    state="$(vm_state_dir "$vm")"
    if [ -f "$state/disks.json" ]; then
      total="$(jq 'length' "$state/disks.json")"
      copied="$(find "$state" -name 'disk-*-state.json' -type f -exec jq -r '.status' {} \; 2>/dev/null |
        awk '$0=="Copied"{n++} END{print n+0}')"
    else
      total="-"
      copied="-"
    fi

    if [ -f "$state/rolled-back-at" ]; then
      accepted="RolledBack"
    elif [ -f "$state/accepted-at" ]; then
      accepted="Yes"
    else
      accepted="No"
    fi

    printf '%-20s %-24s %-24s %-12s %-12s\n' \
      "$vm" "$source_state" "$destination_state" "$copied/$total" "$accepted"
  done
}

select_vm() {
  local number=1 vm choice
  echo >&2
  for vm in "${VM_NAMES[@]}"; do
    printf '  %d) %s\n' "$number" "$vm" >&2
    number=$((number + 1))
  done
  printf 'Select VM: ' >&2
  IFS= read -r choice
  case "$choice" in
    1) echo "MINFO-VM-P" ;;
    2) echo "AZINTBK-VM-P" ;;
    3) echo "AZINTCDC-VM-P" ;;
    4) echo "LSR-DB-VM-P" ;;
    5) echo "RECAZSRVHO-VM-P" ;;
    6) echo "ADCDCDC-VM-P" ;;
    *) die "Invalid VM selection" ;;
  esac
}

show_help() {
  cat <<EOF
Azure cross-tenant VM migration $VERSION

Usage:
  $(basename "$0")
  $(basename "$0") --help

Environment variables:
  MIGRATION_STATE_DIR    State directory (default: ./azure-vm-migration-state)
  COPY_CONCURRENCY       Parallel disk copies (default: 4)
  SAS_DURATION_SECONDS   Temporary SAS lifetime (default: 43200)
  KEEP_LICENSE_TYPE      Copy a non-empty source licenseType only when set to 1
  TARGET_SIZE_MINFO_VM_P
  TARGET_SIZE_AZINTBK_VM_P
  TARGET_SIZE_AZINTCDC_VM_P
  TARGET_SIZE_LSR_DB_VM_P
  TARGET_SIZE_RECAZSRVHO_VM_P
  TARGET_SIZE_ADCDCDC_VM_P
                          Approved destination VM-size overrides

The script is interactive and supports:
  - Preflight and source manifest capture
  - Deallocation and full snapshots
  - Cross-tenant disk copy using AzCopy
  - NSG, NIC, public IP and specialized VM creation
  - Validation checkpoints
  - Rollback to the deallocated source VM
  - Cleanup of temporary migration snapshots

It does not modify VPN routes and does not delete source VMs or disks.
EOF
}

main_menu() {
  local choice vm

  while true; do
    cat <<'EOF'

Azure cross-tenant VM migration

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
EOF
    printf 'Select action: '
    IFS= read -r choice

    case "$choice" in
      1)
        vm="$(select_vm)"
        preflight_vm "$vm"
        ;;
      2)
        migrate_vm "MINFO-VM-P"
        ;;
      3)
        migrate_internal_database_wave
        ;;
      4)
        vm="$(select_vm)"
        migrate_vm "$vm"
        ;;
      5)
        vm="$(select_vm)"
        validate_vm "$vm" || true
        ;;
      6)
        vm="$(select_vm)"
        rollback_vm "$vm"
        ;;
      7)
        rollback_internal_database_wave
        ;;
      8)
        show_status
        ;;
      9)
        vm="$(select_vm)"
        cleanup_snapshots "$vm"
        ;;
      10)
        vm="$(select_vm)"
        test_destination_disk_policy "$vm"
        ;;
      0)
        exit 0
        ;;
      *)
        echo "Invalid action."
        ;;
    esac
  done
}

main() {
  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
  fi
  [ "$#" -eq 0 ] || die "Unknown arguments. Use --help."

  init_runtime
  ensure_access

  cat <<EOF
State directory: $STATE_DIR
Disk-copy concurrency: $COPY_CONCURRENCY
Temporary SAS lifetime: $SAS_DURATION_SECONDS seconds
Source licenseType copy: $KEEP_LICENSE_TYPE
EOF
  main_menu
}

main "$@"
