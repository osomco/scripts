#!/usr/bin/env bash
#
# azure-cross-tenant-vm-copy.sh
#
# Generic, conservative Azure-to-Azure cross-tenant VM copy using:
#   - ARM REST API through an Azure CLI token
#   - Managed disk snapshots
#   - Temporary in-memory read/write SAS URLs
#   - AzCopy server-to-server PageBlob transfer
#
# Design rules:
#   - Hybrid CLI + prompt. Flags and config files never make a run unattended.
#   - Every mutation is gated by an explicit typed confirmation.
#   - --preflight-only blocks every non-GET ARM request centrally.
#   - Any feature that cannot be inventoried and recreated with confidence
#     blocks the copy instead of degrading silently.
#   - Source VMs and source disks are never deleted by this tool.
#
# Bash 3.2 compatible: no associative arrays, no mapfile, no namerefs,
# no ${var,,}, no wait -n.

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.0.0"
TOOL_NAME="azure-cross-tenant-vm-copy"

VM_API="2024-11-01"
DISK_API="2025-01-02"
NETWORK_API="2024-05-01"
RESOURCES_API="2021-04-01"
SUBSCRIPTIONS_API="2022-12-01"
COMPUTE_SKU_API="2021-07-01"
COMPUTE_USAGE_API="2024-11-01"
AUTHZ_API="2022-04-01"

ARM_ENDPOINT="${ARM_ENDPOINT:-https://management.azure.com}"
RETAIL_PRICES_ENDPOINT="${RETAIL_PRICES_ENDPOINT:-https://prices.azure.com/api/retail/prices}"
RETAIL_PRICES_API_VERSION="${RETAIL_PRICES_API_VERSION:-2023-01-01-preview}"
RETAIL_PRICE_MAX_PAGES="${RETAIL_PRICE_MAX_PAGES:-60}"
MONTHLY_HOURS=730

SAS_DURATION_SECONDS="${SAS_DURATION_SECONDS:-43200}"
COPY_CONCURRENCY="${COPY_CONCURRENCY:-4}"
STATE_ROOT="${AZ_VM_COPY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/azure-cross-tenant-vm-copy}"

MODE="copy"
PREFLIGHT_ONLY=0
MUTATIONS_ENABLED=1
INTERACTIVE_AUTH_ALLOWED=1
KEEP_LICENSE_TYPE=0
CONFIG_FILE=""
SAVE_CONFIG_FILE=""
ASSUME_PUBLIC_IP=""
CURRENCY="USD"

SOURCE_VM_ID=""
SOURCE_SUBSCRIPTION=""
SOURCE_RESOURCE_GROUP=""
SOURCE_VM_NAME=""
SOURCE_LOCATION=""
SOURCE_PRIVATE_IP=""

DESTINATION_SUBSCRIPTION=""
MANAGING_TENANT=""
LOCATION=""
DESTINATION_RESOURCE_GROUP=""
DESTINATION_NETWORK_RESOURCE_GROUP=""
DESTINATION_VNET=""
DESTINATION_SUBNET=""
DESTINATION_PRIVATE_IP=""
TARGET_SIZE=""
SELECTED_SIZE=""

MIGRATION_ID=""
STATE_DIR=""
ARM_TOKEN=""
TOKEN_ACQUIRED_AT=0
LAST_STATUS=""
LAST_BODY=""
LAST_HEADERS=""
TMP_DIR=""
DC_MODE=0
PUBLIC_IP_REQUIRED=0
BLOCKERS_FILE=""
SIZE_REQUIREMENTS_FILE=""

# ---------------------------------------------------------------------------
# Logging and process helpers
# ---------------------------------------------------------------------------

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

note() {
  printf 'NOTE: %s\n' "$*" >&2
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
  require_command awk
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
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${TOOL_NAME}.XXXXXX")"
  chmod 700 "$TMP_DIR"
}

# ---------------------------------------------------------------------------
# Pure string, hash and redaction helpers (unit tested)
# ---------------------------------------------------------------------------

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

to_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

trim() {
  printf '%s' "$1" | awk '{gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, ""); print}'
}

hash_string() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    die "Neither shasum nor sha256sum is available"
  fi
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "Neither shasum nor sha256sum is available"
  fi
}

# Replaces every URL and every SAS-like token with a placeholder. Used before
# any AzCopy or ARM output is echoed to a terminal or a log file.
redact_secrets() {
  sed -E \
    -e 's#https?://[^[:space:]"]+#<redacted-url>#g' \
    -e 's#(sig|se|st|sp|sv|skoid|sktid|signedResource|accessSAS|securityDataAccessSAS|securityMetadataAccessSAS)=[^&[:space:]"]+#\1=<redacted>#g' \
    -e 's#(Bearer|accessToken"?[:=]?)[[:space:]]*[A-Za-z0-9._~+/-]{20,}#\1 <redacted>#g'
}

# Returns 0 when the given file contains no secret-shaped material.
contains_no_secrets() {
  local file="$1"
  [ -f "$file" ] || return 0
  if grep -Eq '(\?|&)(sig|sv|se|skoid|sktid)=|accessSAS|securityDataAccessSAS|securityMetadataAccessSAS|"accessToken"|Bearer [A-Za-z0-9._-]{20,}' "$file"; then
    return 1
  fi
  return 0
}

is_uuid() {
  local value re
  value="$(to_lower "$(trim "$1")")"
  re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  [[ $value =~ $re ]]
}

is_azure_name() {
  local value="$1"
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

is_location_name() {
  local value
  value="$(to_lower "$(trim "$1")")"
  case "$value" in
    ''|*[!a-z0-9]*) return 1 ;;
  esac
  return 0
}

is_currency_code() {
  local value re
  value="$(to_upper "$(trim "$1")")"
  re='^[A-Z]{3}$'
  [[ $value =~ $re ]]
}

# ---------------------------------------------------------------------------
# IPv4 and CIDR helpers (unit tested, no Azure calls)
# ---------------------------------------------------------------------------

is_valid_ipv4() {
  local ip="$1" octet
  case "$ip" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  local IFS=.
  set -- $ip
  [ "$#" -eq 4 ] || return 1
  for octet in "$@"; do
    case "$octet" in
      0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;;
      *) return 1 ;;
    esac
    [ "$octet" -le 255 ] || return 1
  done
  return 0
}

ipv4_to_int() {
  local ip="$1"
  is_valid_ipv4 "$ip" || return 1
  local IFS=.
  set -- $ip
  printf '%s' "$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))"
}

int_to_ipv4() {
  local value="$1"
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$value" -ge 0 ] && [ "$value" -le 4294967295 ] || return 1
  printf '%d.%d.%d.%d' \
    "$(( (value / 16777216) % 256 ))" \
    "$(( (value / 65536) % 256 ))" \
    "$(( (value / 256) % 256 ))" \
    "$(( value % 256 ))"
}

cidr_address() {
  printf '%s' "${1%%/*}"
}

cidr_prefix_length() {
  local cidr="$1"
  case "$cidr" in
    */*) ;;
    *) return 1 ;;
  esac
  printf '%s' "${cidr##*/}"
}

is_valid_ipv4_cidr() {
  local cidr="$1" address prefix
  address="$(cidr_address "$cidr")"
  prefix="$(cidr_prefix_length "$cidr")" || return 1
  is_valid_ipv4 "$address" || return 1
  case "$prefix" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
  return 0
}

cidr_network_int() {
  local cidr="$1" address prefix base size
  is_valid_ipv4_cidr "$cidr" || return 1
  address="$(cidr_address "$cidr")"
  prefix="$(cidr_prefix_length "$cidr")"
  base="$(ipv4_to_int "$address")"
  if [ "$prefix" -eq 0 ]; then
    printf '0'
    return 0
  fi
  size=$(( 1 << (32 - prefix) ))
  printf '%s' "$(( base - (base % size) ))"
}

cidr_broadcast_int() {
  local cidr="$1" prefix network size
  network="$(cidr_network_int "$cidr")" || return 1
  prefix="$(cidr_prefix_length "$cidr")"
  size=$(( 1 << (32 - prefix) ))
  printf '%s' "$(( network + size - 1 ))"
}

ip_in_cidr() {
  local ip="$1" cidr="$2" value network broadcast
  value="$(ipv4_to_int "$ip")" || return 1
  network="$(cidr_network_int "$cidr")" || return 1
  broadcast="$(cidr_broadcast_int "$cidr")" || return 1
  [ "$value" -ge "$network" ] && [ "$value" -le "$broadcast" ]
}

# Azure reserves the first four and the last address of every subnet prefix.
ip_is_azure_reserved() {
  local ip="$1" cidr="$2" value network broadcast
  value="$(ipv4_to_int "$ip")" || return 0
  network="$(cidr_network_int "$cidr")" || return 0
  broadcast="$(cidr_broadcast_int "$cidr")" || return 0
  if [ "$value" -ge "$network" ] && [ "$value" -le "$(( network + 3 ))" ]; then
    return 0
  fi
  [ "$value" -eq "$broadcast" ]
}

# ---------------------------------------------------------------------------
# ARM resource-id helpers (unit tested)
# ---------------------------------------------------------------------------

resource_id_field() {
  local id field
  id="$(trim "$1")"
  field="$2"
  id="${id%/}"
  printf '%s' "$id" | awk -F/ -v field="$field" '
    {
      subscription = ""; group = ""; provider = ""; type = ""
      for (i = 1; i <= NF; i++) {
        low = tolower($i)
        if (low == "subscriptions" && i < NF) subscription = $(i + 1)
        else if (low == "resourcegroups" && i < NF) group = $(i + 1)
        else if (low == "providers" && i < NF) { provider = $(i + 1); type = $(i + 2) }
      }
      if (field == "subscription") print subscription
      else if (field == "resourceGroup") print group
      else if (field == "provider") print provider
      else if (field == "type") print type
      else if (field == "name") print $NF
    }'
}

is_vm_resource_id() {
  local id lower segments
  id="$(trim "$1")"
  id="${id%/}"
  lower="$(to_lower "$id")"
  case "$lower" in
    /subscriptions/*/resourcegroups/*/providers/microsoft.compute/virtualmachines/*) ;;
    *) return 1 ;;
  esac
  segments="$(printf '%s' "$id" | awk -F/ '{print NF}')"
  [ "$segments" -eq 9 ] || return 1
  is_uuid "$(resource_id_field "$id" subscription)" || return 1
  [ -n "$(resource_id_field "$id" resourceGroup)" ] || return 1
  [ -n "$(resource_id_field "$id" name)" ] || return 1
  return 0
}

vm_resource_id() {
  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Compute/virtualMachines/%s' "$1" "$2" "$3"
}

subnet_resource_id() {
  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Network/virtualNetworks/%s/subnets/%s' \
    "$1" "$2" "$3" "$4"
}

destination_resource_id() {
  local provider_type="$1" name="$2"
  printf '/subscriptions/%s/resourceGroups/%s/providers/%s/%s' \
    "$DESTINATION_SUBSCRIPTION" "$DESTINATION_RESOURCE_GROUP" "$provider_type" "$name"
}

destination_vm_id() {
  destination_resource_id "Microsoft.Compute/virtualMachines" "$SOURCE_VM_NAME"
}

destination_nic_id() {
  destination_resource_id "Microsoft.Network/networkInterfaces" "${SOURCE_VM_NAME}-nic"
}

destination_pip_id() {
  destination_resource_id "Microsoft.Network/publicIPAddresses" "${SOURCE_VM_NAME}-pip"
}

destination_subnet_id() {
  subnet_resource_id "$DESTINATION_SUBSCRIPTION" "$DESTINATION_NETWORK_RESOURCE_GROUP" \
    "$DESTINATION_VNET" "$DESTINATION_SUBNET"
}

# Deterministic, filesystem-safe migration identifier derived from the
# canonical source VM resource id.
migration_id_for() {
  local vm_id="$1" name digest
  name="$(to_lower "$(resource_id_field "$vm_id" name)")"
  name="$(printf '%s' "$name" | tr -c 'a-z0-9-' '-')"
  digest="$(hash_string "$(to_lower "$vm_id")" | cut -c1-12)"
  printf '%s-%s' "$name" "$digest"
}

snapshot_name_for() {
  local vm_name="$1" index="$2" run_id="$3" base
  base="$(to_lower "$vm_name")"
  base="$(printf '%s' "$base" | tr -c 'a-z0-9-' '-')"
  printf 'copy-%s-%02d-%s' "$base" "$index" "$run_id"
}

# ---------------------------------------------------------------------------
# Central mutation gate and ARM plumbing
# ---------------------------------------------------------------------------

# Every ARM request passes through this guard. In --preflight-only mode any
# request that is not a GET is refused before a token is requested and before
# any network call is made.
guard_mutation() {
  local method="$1" url="$2"
  case "$(to_upper "$method")" in
    GET|HEAD) return 0 ;;
  esac
  if [ "$MUTATIONS_ENABLED" != "1" ]; then
    printf 'ERROR: read-only mode blocked a %s request to %s\n' \
      "$(to_upper "$method")" "$(printf '%s' "$url" | sed -E 's#\?.*##')" >&2
    return 1
  fi
  return 0
}

resource_url() {
  printf '%s%s?api-version=%s' "$ARM_ENDPOINT" "$1" "$2"
}

header_value() {
  local name="$1"
  awk -F': *' -v target="$name" '
    tolower($1) == tolower(target) {
      sub(/\r$/, "", $2)
      value = $2
    }
    END { print value }
  ' "$LAST_HEADERS"
}

refresh_token() {
  local now token_json tenant_args
  now="$(date +%s)"
  if [ -n "$ARM_TOKEN" ] && [ $((now - TOKEN_ACQUIRED_AT)) -lt 2700 ]; then
    return
  fi

  tenant_args=""
  [ -n "$MANAGING_TENANT" ] && tenant_args="$MANAGING_TENANT"

  if [ -n "$tenant_args" ]; then
    token_json="$(az account get-access-token --tenant "$tenant_args" \
      --resource "$ARM_ENDPOINT/" --output json 2>/dev/null)" || token_json=""
  else
    token_json="$(az account get-access-token \
      --resource "$ARM_ENDPOINT/" --output json 2>/dev/null)" || token_json=""
  fi

  if [ -z "$token_json" ]; then
    if [ "$INTERACTIVE_AUTH_ALLOWED" -ne 1 ]; then
      die "Azure authentication expired during a copy. Re-run after a fresh az login; completed disks are reused."
    fi
    warn "Azure CLI authentication is missing or expired."
    if [ -n "$tenant_args" ]; then
      az login --tenant "$tenant_args" >/dev/null
      token_json="$(az account get-access-token --tenant "$tenant_args" \
        --resource "$ARM_ENDPOINT/" --output json)"
    else
      az login >/dev/null
      token_json="$(az account get-access-token --resource "$ARM_ENDPOINT/" --output json)"
    fi
  fi

  ARM_TOKEN="$(printf '%s' "$token_json" | jq -r '.accessToken')"
  [ -n "$ARM_TOKEN" ] && [ "$ARM_TOKEN" != "null" ] || die "Could not obtain an ARM token"
  TOKEN_ACQUIRED_AT="$now"
  log "ARM token refreshed"
}

arm_raw() {
  local method="$1"
  local url="$2"
  local body_file="${3:-}"
  local suffix

  guard_mutation "$method" "$url" || die "Mutation blocked by read-only mode"

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
  ' "$body" 2>/dev/null | redact_secrets || echo "Unexpected ARM response" >&2
}

arm_get_to_file() {
  local id="$1" api="$2" output="$3"
  arm_raw GET "$(resource_url "$id" "$api")"
  if [ "$LAST_STATUS" != "200" ]; then
    print_arm_error "$LAST_BODY" >&2
    return 1
  fi
  cp "$LAST_BODY" "$output"
  chmod 600 "$output"
}

arm_get_url_to_file() {
  local url="$1" output="$2"
  arm_raw GET "$url"
  if [ "$LAST_STATUS" != "200" ]; then
    print_arm_error "$LAST_BODY" >&2
    return 1
  fi
  cp "$LAST_BODY" "$output"
  chmod 600 "$output"
}

resource_exists() {
  local id="$1" api="$2"
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
  local url="$1" output="$2"
  local accumulator page merged next

  accumulator="$TMP_DIR/list-accumulator-$RANDOM-$RANDOM.json"
  printf '{"value":[]}' > "$accumulator"

  while [ -n "$url" ]; do
    arm_raw GET "$url"
    if [ "$LAST_STATUS" != "200" ]; then
      print_arm_error "$LAST_BODY" >&2
      return 1
    fi
    page="$LAST_BODY"
    merged="$TMP_DIR/list-merged-$RANDOM-$RANDOM.json"
    jq -s '{value:((.[0].value // []) + (.[1].value // []))}' "$accumulator" "$page" > "$merged"
    mv "$merged" "$accumulator"
    next="$(jq -r '.nextLink // empty' "$page")"
    url="$next"
  done

  cp "$accumulator" "$output"
  chmod 600 "$output"
}

poll_arm_url() {
  local poll_url="$1" output="$2"
  local attempts=0 status

  while [ "$attempts" -lt 720 ]; do
    arm_raw GET "$poll_url"
    case "$LAST_STATUS" in
      200|201)
        status="$(jq -r '.status // empty' "$LAST_BODY" 2>/dev/null || true)"
        case "$status" in
          Failed|Canceled|Cancelled)
            print_arm_error "$LAST_BODY" >&2
            return 1
            ;;
          InProgress|Running|Accepted) ;;
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
  local method="$1" url="$2" body_file="${3:-}" output="$4"
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
      poll_arm_url "$poll_url" "$output" || return 1
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
  local id="$1" api="$2"
  local attempts=0 state

  while [ "$attempts" -lt 360 ]; do
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
  local id="$1" api="$2" timeout="${3:-1800}" waited=0
  while resource_exists "$id" "$api"; do
    [ "$waited" -lt "$timeout" ] || return 1
    sleep 5
    waited=$((waited + 5))
  done
}

put_resource() {
  local id="$1" api="$2" body="$3"
  local result="$TMP_DIR/put-result-$RANDOM-$RANDOM.json"
  arm_operation PUT "$(resource_url "$id" "$api")" "$body" "$result" ||
    die "Failed to create or update $id"
  wait_for_provisioning "$id" "$api" || die "Resource did not reach Succeeded: $id"
}

patch_resource() {
  local id="$1" api="$2" body="$3"
  local result="$TMP_DIR/patch-result-$RANDOM-$RANDOM.json"
  arm_operation PATCH "$(resource_url "$id" "$api")" "$body" "$result" ||
    die "Failed to update $id"
  wait_for_provisioning "$id" "$api" || die "Resource update did not reach Succeeded: $id"
}

delete_resource() {
  local id="$1" api="$2"
  local result="$TMP_DIR/delete-result-$RANDOM-$RANDOM.json"
  arm_operation DELETE "$(resource_url "$id" "$api")" "" "$result"
}

# ---------------------------------------------------------------------------
# Disk access, SAS and power-state helpers
# ---------------------------------------------------------------------------

# Returns a compact JSON object with the SAS fields. The caller keeps the value
# in process memory only; it is never written to the state directory or a log.
grant_access_json() {
  local id="$1" access="$2" secure="${3:-false}"
  local result body_file sas
  result="$TMP_DIR/grant-result-$RANDOM-$RANDOM.json"
  body_file="$TMP_DIR/grant-body-$RANDOM-$RANDOM.json"

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
    "$ARM_ENDPOINT${id}/beginGetAccess?api-version=${DISK_API}" \
    "$body_file" "$result" || return 1

  sas="$(jq -r '.accessSAS // .output.accessSAS // .properties.output.accessSAS // empty' "$result" 2>/dev/null || true)"
  if [ -z "$sas" ]; then
    sleep 3
    arm_raw POST "$ARM_ENDPOINT${id}/beginGetAccess?api-version=${DISK_API}" "$body_file"
    if [ "$LAST_STATUS" = "200" ]; then
      cp "$LAST_BODY" "$result"
      sas="$(jq -r '.accessSAS // empty' "$result")"
    fi
  fi

  [ -n "$sas" ] || return 1
  jq -c '
    .properties.output // .output // .
    | {accessSAS, securityDataAccessSAS, securityMetadataAccessSAS}
  ' "$result"
  rm -f "$result" "$body_file"
}

revoke_access() {
  local id="$1"
  local result="$TMP_DIR/revoke-result-$RANDOM-$RANDOM.json"
  arm_operation POST "$ARM_ENDPOINT${id}/endGetAccess?api-version=${DISK_API}" "" "$result" \
    >/dev/null 2>&1 || warn "Could not revoke access for $(basename "$id")"
}

set_data_access() {
  local id="$1" mode="$2"
  local body="$TMP_DIR/data-access-$RANDOM-$RANDOM.json"
  case "$mode" in
    open)
      jq -n '{properties:{networkAccessPolicy:"AllowAll",publicNetworkAccess:"Enabled"}}' > "$body"
      ;;
    closed)
      jq -n '{properties:{networkAccessPolicy:"DenyAll",publicNetworkAccess:"Disabled"}}' > "$body"
      ;;
    *) die "Unsupported data-access mode: $mode" ;;
  esac
  patch_resource "$id" "$DISK_API" "$body"
}

close_data_access_best_effort() {
  local id="$1"
  local body="$TMP_DIR/close-access-$RANDOM-$RANDOM.json"
  local result="$TMP_DIR/close-access-result-$RANDOM-$RANDOM.json"
  jq -n '{properties:{networkAccessPolicy:"DenyAll",publicNetworkAccess:"Disabled"}}' > "$body"
  if ! arm_operation PATCH "$(resource_url "$id" "$DISK_API")" "$body" "$result"; then
    warn "Could not close public network access automatically: $(basename "$id")"
    return 1
  fi
}

wait_for_disk_unattached() {
  local id="$1" attempts=0 state
  while [ "$attempts" -lt 240 ]; do
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
  arm_raw GET "$ARM_ENDPOINT${vm_id}/instanceView?api-version=${VM_API}"
  if [ "$LAST_STATUS" != "200" ]; then
    echo "unknown"
    return
  fi
  jq -r '[.statuses[]? | select(.code | startswith("PowerState/")) | .code][0] // "PowerState/unknown"' "$LAST_BODY"
}

wait_for_power_state() {
  local vm_id="$1" expected="$2" attempts=0 state
  while [ "$attempts" -lt 360 ]; do
    state="$(vm_power_state "$vm_id")"
    [ "$state" = "PowerState/$expected" ] && return 0
    attempts=$((attempts + 1))
    sleep 5
  done
  return 1
}

deallocate_vm() {
  local vm_id="$1"
  local result="$TMP_DIR/deallocate-$RANDOM-$RANDOM.json"
  log "Deallocating $(basename "$vm_id")"
  arm_operation POST "$ARM_ENDPOINT${vm_id}/deallocate?api-version=${VM_API}" "" "$result" ||
    die "Could not deallocate $(basename "$vm_id")"
  wait_for_power_state "$vm_id" deallocated ||
    die "VM did not reach PowerState/deallocated: $(basename "$vm_id")"
}

start_vm() {
  local vm_id="$1"
  local result="$TMP_DIR/start-$RANDOM-$RANDOM.json"
  log "Starting $(basename "$vm_id")"
  arm_operation POST "$ARM_ENDPOINT${vm_id}/start?api-version=${VM_API}" "" "$result" ||
    die "Could not start $(basename "$vm_id")"
  wait_for_power_state "$vm_id" running ||
    die "VM did not reach PowerState/running: $(basename "$vm_id")"
}

require_source_deallocated() {
  local state
  state="$(vm_power_state "$SOURCE_VM_ID")"
  [ "$state" = "PowerState/deallocated" ] ||
    die "Source VM must stay deallocated during the copy. Current state: $state"
}

# ---------------------------------------------------------------------------
# Interaction helpers
# ---------------------------------------------------------------------------

require_interactive_terminal() {
  if [ ! -t 0 ]; then
    die "This tool is strictly interactive. Run it from a terminal; flags never make it unattended."
  fi
}

confirm_phrase() {
  local phrase="$1" entered
  require_interactive_terminal
  printf '\nType exactly: %s\n> ' "$phrase" >&2
  IFS= read -r entered
  [ "$entered" = "$phrase" ] || die "Confirmation did not match; no action was taken"
}

ask_yes_no() {
  local prompt="$1" answer
  require_interactive_terminal
  while true; do
    printf '%s [y/n]: ' "$prompt" >&2
    IFS= read -r answer
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) printf 'Please answer y or n.\n' >&2 ;;
    esac
  done
}

read_line() {
  local prompt="$1" default_value="${2:-}" answer
  require_interactive_terminal
  if [ -n "$default_value" ]; then
    printf '%s [%s]: ' "$prompt" "$default_value" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  IFS= read -r answer
  answer="$(trim "$answer")"
  if [ -z "$answer" ]; then
    answer="$default_value"
  fi
  printf '%s' "$answer"
}

always_true() {
  [ -n "$1" ]
}

# Resolves one configuration field. CLI/config supplied values are validated and
# shown; missing values are prompted. Values are never inferred silently.
resolve_field() {
  local varname="$1" label="$2" validator="$3" default_value="${4:-}"
  local current entered

  eval "current=\${$varname:-}"
  current="$(trim "$current")"

  if [ -n "$current" ]; then
    "$validator" "$current" || die "Invalid value for $label: $current"
    eval "$varname=\$current"
    log "$label = $current (supplied)"
    return 0
  fi

  while true; do
    entered="$(read_line "$label" "$default_value")"
    entered="$(trim "$entered")"
    if [ -z "$entered" ]; then
      printf 'A value is required for %s.\n' "$label" >&2
      continue
    fi
    if ! "$validator" "$entered"; then
      printf 'Invalid value for %s: %s\n' "$label" "$entered" >&2
      continue
    fi
    if [ -n "$default_value" ] && [ "$entered" = "$default_value" ]; then
      ask_yes_no "Confirm $label = $entered (proposed default, not inferred)" || continue
    fi
    eval "$varname=\$entered"
    return 0
  done
}

# ---------------------------------------------------------------------------
# Configuration file handling
# ---------------------------------------------------------------------------

CONFIG_KEYS="sourceVmId
sourceSubscription
sourceResourceGroup
vmName
destinationSubscription
managingTenant
location
destinationResourceGroup
destinationNetworkResourceGroup
destinationVnet
destinationSubnet
destinationPrivateIp
currency
targetSize"

config_key_to_var() {
  case "$1" in
    sourceVmId) printf 'SOURCE_VM_ID' ;;
    sourceSubscription) printf 'SOURCE_SUBSCRIPTION' ;;
    sourceResourceGroup) printf 'SOURCE_RESOURCE_GROUP' ;;
    vmName) printf 'SOURCE_VM_NAME' ;;
    destinationSubscription) printf 'DESTINATION_SUBSCRIPTION' ;;
    managingTenant) printf 'MANAGING_TENANT' ;;
    location) printf 'LOCATION' ;;
    destinationResourceGroup) printf 'DESTINATION_RESOURCE_GROUP' ;;
    destinationNetworkResourceGroup) printf 'DESTINATION_NETWORK_RESOURCE_GROUP' ;;
    destinationVnet) printf 'DESTINATION_VNET' ;;
    destinationSubnet) printf 'DESTINATION_SUBNET' ;;
    destinationPrivateIp) printf 'DESTINATION_PRIVATE_IP' ;;
    currency) printf 'CURRENCY' ;;
    targetSize) printf 'TARGET_SIZE' ;;
    *) return 1 ;;
  esac
}

# Config files carry only non-secret identifiers. Anything that looks like a
# credential aborts the load.
load_config_file() {
  local file="$1" key varname value
  [ -f "$file" ] || die "Config file not found: $file"
  jq -e 'type == "object"' "$file" >/dev/null 2>&1 ||
    die "Config file must contain a JSON object: $file"
  contains_no_secrets "$file" ||
    die "Config file appears to contain a credential or SAS value: $file"

  for key in $CONFIG_KEYS; do
    varname="$(config_key_to_var "$key")" || continue
    eval "value=\${$varname:-}"
    [ -n "$value" ] && continue
    value="$(jq -r --arg k "$key" '.[$k] // empty' "$file")"
    [ -n "$value" ] || continue
    eval "$varname=\$value"
  done
  log "Loaded configuration defaults from $file"
}

save_config_file() {
  local file="$1" tmp
  tmp="$file.tmp.$$"
  jq -n \
    --arg sourceVmId "$SOURCE_VM_ID" \
    --arg sourceSubscription "$SOURCE_SUBSCRIPTION" \
    --arg sourceResourceGroup "$SOURCE_RESOURCE_GROUP" \
    --arg vmName "$SOURCE_VM_NAME" \
    --arg destinationSubscription "$DESTINATION_SUBSCRIPTION" \
    --arg managingTenant "$MANAGING_TENANT" \
    --arg location "$LOCATION" \
    --arg destinationResourceGroup "$DESTINATION_RESOURCE_GROUP" \
    --arg destinationNetworkResourceGroup "$DESTINATION_NETWORK_RESOURCE_GROUP" \
    --arg destinationVnet "$DESTINATION_VNET" \
    --arg destinationSubnet "$DESTINATION_SUBNET" \
    --arg destinationPrivateIp "$DESTINATION_PRIVATE_IP" \
    --arg currency "$CURRENCY" \
    --arg targetSize "$SELECTED_SIZE" \
    '{
      sourceVmId:$sourceVmId,
      sourceSubscription:$sourceSubscription,
      sourceResourceGroup:$sourceResourceGroup,
      vmName:$vmName,
      destinationSubscription:$destinationSubscription,
      managingTenant:$managingTenant,
      location:$location,
      destinationResourceGroup:$destinationResourceGroup,
      destinationNetworkResourceGroup:$destinationNetworkResourceGroup,
      destinationVnet:$destinationVnet,
      destinationSubnet:$destinationSubnet,
      destinationPrivateIp:$destinationPrivateIp,
      currency:$currency,
      targetSize:$targetSize
    }
    | with_entries(select(.value != ""))' > "$tmp"
  contains_no_secrets "$tmp" || {
    rm -f "$tmp"
    die "Refusing to persist a configuration file that contains secret-shaped values"
  }
  mv "$tmp" "$file"
  chmod 600 "$file"
  log "Saved sanitized configuration to $file"
}

# ---------------------------------------------------------------------------
# State directory
# ---------------------------------------------------------------------------

init_state_dir() {
  [ -n "$MIGRATION_ID" ] || die "Migration id is not resolved yet"
  STATE_DIR="$STATE_ROOT/$MIGRATION_ID"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_ROOT" 2>/dev/null || true
  chmod 700 "$STATE_DIR"
}

# All state writes go through this function so that no SAS URL, token or other
# secret-shaped value can ever be persisted.
write_state_file() {
  local target="$1" source_file="$2"
  contains_no_secrets "$source_file" ||
    die "Refusing to persist secret-shaped content to state file: $(basename "$target")"
  cp "$source_file" "$target"
  chmod 600 "$target"
}

write_state_json() {
  local target="$1" tmp
  tmp="$TMP_DIR/state-write-$RANDOM-$RANDOM.json"
  cat > "$tmp"
  jq -e '.' "$tmp" >/dev/null 2>&1 || die "Refusing to persist invalid JSON state: $(basename "$target")"
  write_state_file "$target" "$tmp"
}

state_run_id() {
  local run_file="$STATE_DIR/run-id"
  if [ ! -s "$run_file" ]; then
    date -u '+%Y%m%dT%H%M%SZ' > "$run_file"
    chmod 600 "$run_file"
  fi
  cat "$run_file"
}

# Fingerprint over the identity-bearing part of the resolved manifest. Resume
# refuses to continue when any of these inputs changed.
manifest_fingerprint() {
  hash_string "$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' \
    "$(to_lower "$SOURCE_VM_ID")" \
    "$(to_lower "$DESTINATION_SUBSCRIPTION")" \
    "$(to_lower "$LOCATION")" \
    "$(to_lower "$DESTINATION_RESOURCE_GROUP")" \
    "$(to_lower "$DESTINATION_NETWORK_RESOURCE_GROUP")" \
    "$(to_lower "$DESTINATION_VNET")" \
    "$(to_lower "$DESTINATION_SUBNET")" \
    "$DESTINATION_PRIVATE_IP" \
    "$SELECTED_SIZE")"
}

write_manifest() {
  local fingerprint
  fingerprint="$(manifest_fingerprint)"
  write_state_json "$STATE_DIR/manifest.json" <<EOF
$(jq -n \
  --arg tool "$TOOL_NAME" \
  --arg version "$VERSION" \
  --arg migrationId "$MIGRATION_ID" \
  --arg capturedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg sourceVmId "$SOURCE_VM_ID" \
  --arg sourceSubscription "$SOURCE_SUBSCRIPTION" \
  --arg sourceResourceGroup "$SOURCE_RESOURCE_GROUP" \
  --arg vmName "$SOURCE_VM_NAME" \
  --arg sourceLocation "$SOURCE_LOCATION" \
  --arg destinationSubscription "$DESTINATION_SUBSCRIPTION" \
  --arg managingTenant "$MANAGING_TENANT" \
  --arg location "$LOCATION" \
  --arg destinationResourceGroup "$DESTINATION_RESOURCE_GROUP" \
  --arg destinationNetworkResourceGroup "$DESTINATION_NETWORK_RESOURCE_GROUP" \
  --arg destinationVnet "$DESTINATION_VNET" \
  --arg destinationSubnet "$DESTINATION_SUBNET" \
  --arg destinationPrivateIp "$DESTINATION_PRIVATE_IP" \
  --arg targetSize "$SELECTED_SIZE" \
  --arg currency "$CURRENCY" \
  --arg fingerprint "$fingerprint" \
  --argjson keepLicenseType "$([ "$KEEP_LICENSE_TYPE" = "1" ] && echo true || echo false)" \
  --argjson publicIpRequested "$([ "$PUBLIC_IP_REQUIRED" = "1" ] && echo true || echo false)" \
  --argjson domainController "$([ "$DC_MODE" = "1" ] && echo true || echo false)" \
  '{
    tool:$tool, version:$version, migrationId:$migrationId, capturedAt:$capturedAt,
    source:{
      vmId:$sourceVmId, subscription:$sourceSubscription,
      resourceGroup:$sourceResourceGroup, vmName:$vmName, location:$sourceLocation
    },
    destination:{
      subscription:$destinationSubscription, managingTenant:$managingTenant,
      location:$location, resourceGroup:$destinationResourceGroup,
      networkResourceGroup:$destinationNetworkResourceGroup,
      vnet:$destinationVnet, subnet:$destinationSubnet,
      privateIp:$destinationPrivateIp, vmSize:$targetSize,
      publicIpRequested:$publicIpRequested
    },
    options:{currency:$currency, keepLicenseType:$keepLicenseType, domainController:$domainController},
    fingerprint:$fingerprint
  }')
EOF
}

stored_fingerprint() {
  [ -f "$STATE_DIR/manifest.json" ] || return 1
  jq -r '.fingerprint // empty' "$STATE_DIR/manifest.json"
}

# ---------------------------------------------------------------------------
# Command line parsing
# ---------------------------------------------------------------------------

# Case lists are used instead of word splitting because IFS is restricted to
# newline and tab for safety.
mode_is_known() {
  case "$1" in
    preflight|status|copy|resume|rollback|reset|cleanup-snapshots|policy-test|validate) return 0 ;;
  esac
  return 1
}

mode_is_mutating() {
  case "$1" in
    copy|resume|rollback|reset|cleanup-snapshots|policy-test|validate) return 0 ;;
  esac
  return 1
}

require_argument() {
  [ -n "${2:-}" ] || die "Option $1 requires a value"
}

parse_arguments() {
  local mode_supplied=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) show_help; exit 0 ;;
      --version) printf '%s %s\n' "$TOOL_NAME" "$VERSION"; exit 0 ;;
      --mode)
        require_argument "$1" "${2:-}"
        MODE="$(to_lower "$2")"
        mode_supplied=1
        shift 2
        ;;
      --preflight-only) PREFLIGHT_ONLY=1; shift ;;
      --resume) MODE="resume"; mode_supplied=1; shift ;;
      --status) MODE="status"; mode_supplied=1; shift ;;
      --validate) MODE="validate"; mode_supplied=1; shift ;;
      --rollback) MODE="rollback"; mode_supplied=1; shift ;;
      --reset) MODE="reset"; mode_supplied=1; shift ;;
      --cleanup-snapshots) MODE="cleanup-snapshots"; mode_supplied=1; shift ;;
      --destination-policy-test) MODE="policy-test"; mode_supplied=1; shift ;;
      --source-vm-id) require_argument "$1" "${2:-}"; SOURCE_VM_ID="$2"; shift 2 ;;
      --source-subscription) require_argument "$1" "${2:-}"; SOURCE_SUBSCRIPTION="$2"; shift 2 ;;
      --source-resource-group) require_argument "$1" "${2:-}"; SOURCE_RESOURCE_GROUP="$2"; shift 2 ;;
      --vm-name) require_argument "$1" "${2:-}"; SOURCE_VM_NAME="$2"; shift 2 ;;
      --destination-subscription) require_argument "$1" "${2:-}"; DESTINATION_SUBSCRIPTION="$2"; shift 2 ;;
      --managing-tenant) require_argument "$1" "${2:-}"; MANAGING_TENANT="$2"; shift 2 ;;
      --location) require_argument "$1" "${2:-}"; LOCATION="$2"; shift 2 ;;
      --destination-resource-group) require_argument "$1" "${2:-}"; DESTINATION_RESOURCE_GROUP="$2"; shift 2 ;;
      --network-resource-group|--destination-network-resource-group) require_argument "$1" "${2:-}"; DESTINATION_NETWORK_RESOURCE_GROUP="$2"; shift 2 ;;
      --vnet|--destination-vnet) require_argument "$1" "${2:-}"; DESTINATION_VNET="$2"; shift 2 ;;
      --subnet|--destination-subnet) require_argument "$1" "${2:-}"; DESTINATION_SUBNET="$2"; shift 2 ;;
      --private-ip|--destination-private-ip) require_argument "$1" "${2:-}"; DESTINATION_PRIVATE_IP="$2"; shift 2 ;;
      --currency) require_argument "$1" "${2:-}"; CURRENCY="$(to_upper "$2")"; shift 2 ;;
      --target-size) require_argument "$1" "${2:-}"; TARGET_SIZE="$2"; shift 2 ;;
      --config) require_argument "$1" "${2:-}"; CONFIG_FILE="$2"; shift 2 ;;
      --save-config) require_argument "$1" "${2:-}"; SAVE_CONFIG_FILE="$2"; shift 2 ;;
      --keep-license-type) KEEP_LICENSE_TYPE=1; shift ;;
      --state-dir) require_argument "$1" "${2:-}"; STATE_ROOT="$2"; shift 2 ;;
      --copy-concurrency) require_argument "$1" "${2:-}"; COPY_CONCURRENCY="$2"; shift 2 ;;
      --sas-duration) require_argument "$1" "${2:-}"; SAS_DURATION_SECONDS="$2"; shift 2 ;;
      --) shift; break ;;
      *) die "Unknown argument: $1. Use --help." ;;
    esac
  done

  mode_is_known "$MODE" || die "Unknown mode: $MODE"

  if [ "$PREFLIGHT_ONLY" -eq 1 ]; then
    if [ "$mode_supplied" -eq 1 ] && mode_is_mutating "$MODE"; then
      die "--preflight-only cannot be combined with the mutating mode '$MODE'"
    fi
    MODE="preflight"
  fi

  if mode_is_mutating "$MODE"; then
    MUTATIONS_ENABLED=1
  else
    MUTATIONS_ENABLED=0
  fi

  case "$COPY_CONCURRENCY" in
    ''|*[!0-9]*) die "--copy-concurrency must be a positive integer" ;;
  esac
  [ "$COPY_CONCURRENCY" -ge 1 ] || die "--copy-concurrency must be at least 1"
  case "$SAS_DURATION_SECONDS" in
    ''|*[!0-9]*) die "--sas-duration must be a positive integer" ;;
  esac
  [ "$SAS_DURATION_SECONDS" -ge 3600 ] || die "--sas-duration must be at least 3600 seconds"
  is_currency_code "$CURRENCY" || die "--currency must be a three-letter ISO code"
}

# ---------------------------------------------------------------------------
# Authentication context and source VM resolution
# ---------------------------------------------------------------------------

discover_managing_tenant() {
  local tenant=""
  if [ -n "$DESTINATION_SUBSCRIPTION" ]; then
    tenant="$(az account list --all --output json 2>/dev/null |
      jq -r --arg id "$DESTINATION_SUBSCRIPTION" \
        '[.[] | select((.id // "") == $id) | (.homeTenantId // .tenantId // empty)][0] // empty' 2>/dev/null || true)"
  fi
  if [ -z "$tenant" ]; then
    tenant="$(az account show --output json 2>/dev/null | jq -r '.tenantId // empty' 2>/dev/null || true)"
  fi
  printf '%s' "$tenant"
}

resolve_managing_tenant() {
  local discovered=""
  if [ -z "$MANAGING_TENANT" ]; then
    discovered="$(discover_managing_tenant)"
    if [ -n "$discovered" ]; then
      note "Azure CLI reports tenant $discovered. Lighthouse delegations are often managed from a different tenant."
    fi
  fi
  resolve_field MANAGING_TENANT "Managing tenant id (the tenant your az login uses for both subscriptions)" is_uuid "$discovered"
}

find_vm_by_name() {
  local subscription="$1" name="$2" list_file matches count
  list_file="$TMP_DIR/vm-list-$RANDOM-$RANDOM.json"
  arm_list_to_file \
    "$ARM_ENDPOINT/subscriptions/$subscription/providers/Microsoft.Compute/virtualMachines?api-version=$VM_API" \
    "$list_file" || die "Could not enumerate virtual machines in subscription $subscription"

  matches="$(jq -r --arg name "$name" '
    [.value[] | select((.name // "" | ascii_downcase) == ($name | ascii_downcase)) | .id] | .[]
  ' "$list_file")"
  count="$(printf '%s\n' "$matches" | awk 'NF > 0' | wc -l | tr -d ' ')"

  if [ "$count" -eq 0 ]; then
    die "No virtual machine named '$name' was found in subscription $subscription"
  fi
  if [ "$count" -gt 1 ]; then
    printf '%s\n' "$matches" >&2
    die "Multiple virtual machines named '$name' were found. Supply --source-resource-group or --source-vm-id."
  fi
  printf '%s\n' "$matches" | awk 'NF > 0' | head -n 1
}

resolve_source_vm() {
  local candidate_id

  if [ -n "$SOURCE_VM_ID" ]; then
    is_vm_resource_id "$SOURCE_VM_ID" ||
      die "--source-vm-id is not a Microsoft.Compute/virtualMachines resource id: $SOURCE_VM_ID"
    SOURCE_SUBSCRIPTION="$(resource_id_field "$SOURCE_VM_ID" subscription)"
    SOURCE_RESOURCE_GROUP="$(resource_id_field "$SOURCE_VM_ID" resourceGroup)"
    SOURCE_VM_NAME="$(resource_id_field "$SOURCE_VM_ID" name)"
    log "Source VM id supplied: $SOURCE_VM_ID"
  else
    resolve_field SOURCE_SUBSCRIPTION "Source subscription id" is_uuid
    resolve_field SOURCE_VM_NAME "Source VM name" is_azure_name
    if [ -n "$SOURCE_RESOURCE_GROUP" ]; then
      is_azure_name "$SOURCE_RESOURCE_GROUP" ||
        die "Invalid source resource group: $SOURCE_RESOURCE_GROUP"
      SOURCE_VM_ID="$(vm_resource_id "$SOURCE_SUBSCRIPTION" "$SOURCE_RESOURCE_GROUP" "$SOURCE_VM_NAME")"
    else
      log "No source resource group supplied; searching subscription $SOURCE_SUBSCRIPTION for exact name matches"
      candidate_id="$(find_vm_by_name "$SOURCE_SUBSCRIPTION" "$SOURCE_VM_NAME")"
      SOURCE_VM_ID="$candidate_id"
      SOURCE_RESOURCE_GROUP="$(resource_id_field "$SOURCE_VM_ID" resourceGroup)"
      SOURCE_VM_NAME="$(resource_id_field "$SOURCE_VM_ID" name)"
    fi
  fi

  MIGRATION_ID="$(migration_id_for "$SOURCE_VM_ID")"
  init_state_dir

  arm_get_to_file "$SOURCE_VM_ID" "$VM_API" "$TMP_DIR/source-vm-probe.json" ||
    die "Source VM could not be read: $SOURCE_VM_ID"

  SOURCE_VM_ID="$(jq -r '.id' "$TMP_DIR/source-vm-probe.json")"
  SOURCE_SUBSCRIPTION="$(resource_id_field "$SOURCE_VM_ID" subscription)"
  SOURCE_RESOURCE_GROUP="$(resource_id_field "$SOURCE_VM_ID" resourceGroup)"
  SOURCE_VM_NAME="$(jq -r '.name' "$TMP_DIR/source-vm-probe.json")"
  SOURCE_LOCATION="$(jq -r '.location // empty' "$TMP_DIR/source-vm-probe.json")"

  cat >&2 <<EOF

Canonical source VM resolved by Azure:
  id:             $SOURCE_VM_ID
  name:           $SOURCE_VM_NAME
  resource group: $SOURCE_RESOURCE_GROUP
  location:       $SOURCE_LOCATION
  size:           $(jq -r '.properties.hardwareProfile.vmSize // "unknown"' "$TMP_DIR/source-vm-probe.json")
  migration id:   $MIGRATION_ID
EOF
  ask_yes_no "Is this the correct source VM" || die "Source VM was not confirmed"
}

ensure_subscription_access() {
  local source_file destination_file
  source_file="$TMP_DIR/source-subscription.json"
  destination_file="$TMP_DIR/destination-subscription.json"

  arm_get_to_file "/subscriptions/$SOURCE_SUBSCRIPTION" "$SUBSCRIPTIONS_API" "$source_file" ||
    die "No access to source subscription $SOURCE_SUBSCRIPTION with the current token"
  log "Source subscription: $(jq -r '.displayName // "unknown"' "$source_file")"

  arm_get_to_file "/subscriptions/$DESTINATION_SUBSCRIPTION" "$SUBSCRIPTIONS_API" "$destination_file" ||
    die "No access to destination subscription $DESTINATION_SUBSCRIPTION. Verify Lighthouse delegation or direct RBAC."
  log "Destination subscription: $(jq -r '.displayName // "unknown"' "$destination_file")"
}

resolve_destination_identity() {
  resolve_field DESTINATION_SUBSCRIPTION "Destination subscription id" is_uuid
  resolve_managing_tenant
}

resolve_destination_configuration() {
  resolve_field LOCATION "Destination Azure region (ARM name, for example eastus2)" is_location_name "$SOURCE_LOCATION"
  resolve_field DESTINATION_RESOURCE_GROUP "Destination resource group for the VM, disks and NIC" is_azure_name
  resolve_field DESTINATION_NETWORK_RESOURCE_GROUP "Destination resource group that holds the virtual network" is_azure_name
  resolve_field DESTINATION_VNET "Destination virtual network name" is_azure_name
  resolve_field DESTINATION_SUBNET "Destination subnet name" is_azure_name
  resolve_field DESTINATION_PRIVATE_IP "Destination static private IPv4 address" is_valid_ipv4 "$SOURCE_PRIVATE_IP"
}

# ---------------------------------------------------------------------------
# Source inventory
# ---------------------------------------------------------------------------

reset_blockers() {
  BLOCKERS_FILE="$TMP_DIR/blockers-$RANDOM-$RANDOM.txt"
  : > "$BLOCKERS_FILE"
}

add_blocker() {
  printf '%s\n' "$1" >> "$BLOCKERS_FILE"
}

fail_on_blockers() {
  local context="$1" count
  count="$(awk 'NF > 0' "$BLOCKERS_FILE" | wc -l | tr -d ' ')"
  [ "$count" -eq 0 ] && return 0
  printf '\nUnsupported configuration detected during %s:\n' "$context" >&2
  awk 'NF > 0 {printf "  - %s\n", $0}' "$BLOCKERS_FILE" >&2
  cat >&2 <<'EOF'

This tool fails closed. Every item above must be removed, remapped by hand, or
handled by a dedicated migration plan before a cross-tenant copy is attempted.
EOF
  exit 1
}

inventory_source() {
  local nic_id nsg_id subnet_id extensions_id
  local disk_ids disk_id disk_file disk_config disk_record records_dir index

  records_dir="$TMP_DIR/disk-records-$RANDOM-$RANDOM"
  mkdir -p "$records_dir"

  log "Reading source manifest for $SOURCE_VM_NAME"
  arm_get_to_file "$SOURCE_VM_ID" "$VM_API" "$TMP_DIR/source-vm.json" ||
    die "Source VM could not be read: $SOURCE_VM_ID"
  write_state_file "$STATE_DIR/source-vm.json" "$TMP_DIR/source-vm.json"

  [ "$(jq '.properties.networkProfile.networkInterfaces | length' "$TMP_DIR/source-vm.json")" -eq 1 ] ||
    die "Only single-NIC virtual machines are supported. Remap additional NICs manually."

  nic_id="$(jq -r '.properties.networkProfile.networkInterfaces[0].id' "$TMP_DIR/source-vm.json")"
  arm_get_to_file "$nic_id" "$NETWORK_API" "$TMP_DIR/source-nic.json" ||
    die "Could not read the source network interface: $nic_id"
  write_state_file "$STATE_DIR/source-nic.json" "$TMP_DIR/source-nic.json"

  SOURCE_PRIVATE_IP="$(jq -r '
    [.properties.ipConfigurations[]?
     | select((.properties.primary // false) == true or ((.properties.privateIPAddressVersion // "IPv4") == "IPv4"))
     | .properties.privateIPAddress][0] // empty' "$TMP_DIR/source-nic.json")"

  subnet_id="$(jq -r '[.properties.ipConfigurations[]? | .properties.subnet.id][0] // empty' "$TMP_DIR/source-nic.json")"
  if [ -n "$subnet_id" ]; then
    arm_get_to_file "$subnet_id" "$NETWORK_API" "$TMP_DIR/source-subnet.json" ||
      printf '{"properties":{}}' > "$TMP_DIR/source-subnet.json"
  else
    printf '{"properties":{}}' > "$TMP_DIR/source-subnet.json"
  fi
  write_state_file "$STATE_DIR/source-subnet.json" "$TMP_DIR/source-subnet.json"

  nsg_id="$(jq -r '.properties.networkSecurityGroup.id // empty' "$TMP_DIR/source-nic.json")"
  if [ -n "$nsg_id" ]; then
    arm_get_to_file "$nsg_id" "$NETWORK_API" "$TMP_DIR/source-nsg.json" ||
      die "Could not read the NIC network security group: $nsg_id"
  else
    printf '{"properties":{"securityRules":[]}}' > "$TMP_DIR/source-nsg.json"
  fi
  write_state_file "$STATE_DIR/source-nsg.json" "$TMP_DIR/source-nsg.json"

  extensions_id="${SOURCE_VM_ID}/extensions"
  arm_get_to_file "$extensions_id" "$VM_API" "$TMP_DIR/source-extensions.json" ||
    printf '{"value":[]}' > "$TMP_DIR/source-extensions.json"
  write_state_file "$STATE_DIR/source-extensions.json" "$TMP_DIR/source-extensions.json"

  disk_ids="$(jq -r '
    (.properties.storageProfile.osDisk.managedDisk.id // empty),
    (.properties.storageProfile.dataDisks[]?.managedDisk.id // empty)
  ' "$TMP_DIR/source-vm.json")"
  [ -n "$disk_ids" ] || die "The source VM exposes no managed disks. Unmanaged disks are not supported."

  index=0
  while IFS= read -r disk_id; do
    [ -n "$disk_id" ] || continue
    disk_file="$records_dir/disk-$index-source.json"
    arm_get_to_file "$disk_id" "$DISK_API" "$disk_file" || die "Could not read disk: $disk_id"

    if [ "$index" -eq 0 ]; then
      disk_config="$(jq -c '.properties.storageProfile.osDisk' "$TMP_DIR/source-vm.json")"
      jq -n \
        --arg role "OS" \
        --argjson index "$index" \
        --argjson config "$disk_config" \
        --slurpfile resource "$disk_file" \
        '{index:$index,role:$role,lun:null,config:$config,resource:$resource[0]}' \
        > "$records_dir/record-$index.json"
    else
      disk_config="$(jq -c --arg id "$disk_id" '
        .properties.storageProfile.dataDisks[] | select(.managedDisk.id == $id)
      ' "$TMP_DIR/source-vm.json")"
      jq -n \
        --arg role "DATA" \
        --argjson index "$index" \
        --argjson config "$disk_config" \
        --slurpfile resource "$disk_file" \
        '{index:$index,role:$role,lun:$config.lun,config:$config,resource:$resource[0]}' \
        > "$records_dir/record-$index.json"
    fi
    index=$((index + 1))
  done <<EOF
$disk_ids
EOF

  jq -s 'sort_by(.index)' "$records_dir"/record-*.json > "$TMP_DIR/disks.json"
  write_state_file "$STATE_DIR/disks.json" "$TMP_DIR/disks.json"

  log "Inventoried $(jq 'length' "$TMP_DIR/disks.json") managed disks for $SOURCE_VM_NAME"
}

# ---------------------------------------------------------------------------
# Fail-closed support boundary
# ---------------------------------------------------------------------------

validate_support_boundary() {
  local vm="$TMP_DIR/source-vm.json"
  local nic="$TMP_DIR/source-nic.json"
  local nsg="$TMP_DIR/source-nsg.json"
  local subnet="$TMP_DIR/source-subnet.json"
  local disks="$TMP_DIR/disks.json"
  local extensions="$TMP_DIR/source-extensions.json"
  local value security_type storage_uri license_type identity_type

  reset_blockers

  value="$(jq '[.properties.ipConfigurations[]?] | length' "$nic")"
  [ "$value" -eq 1 ] || add_blocker "The source NIC has $value IP configurations; only one primary IPv4 configuration is supported."

  value="$(jq '[.properties.ipConfigurations[]? | select((.properties.privateIPAddressVersion // "IPv4") != "IPv4")] | length' "$nic")"
  [ "$value" -eq 0 ] || add_blocker "The source NIC exposes non-IPv4 configurations. IPv6 is not supported."

  [ -n "$SOURCE_PRIVATE_IP" ] || add_blocker "The source NIC has no readable private IPv4 address."

  value="$(jq '[.properties.ipConfigurations[]? | select(((.properties.applicationSecurityGroups // []) | length) > 0)] | length' "$nic")"
  [ "$value" -eq 0 ] || add_blocker "The NIC references Application Security Groups. Create and remap destination ASGs explicitly first."

  value="$(jq '
    [.properties.ipConfigurations[]?
     | ((.properties.loadBalancerBackendAddressPools // []) + (.properties.applicationGatewayBackendAddressPools // []) + (.properties.loadBalancerInboundNatRules // []))[]
    ] | length' "$nic")"
  [ "$value" -eq 0 ] || add_blocker "The NIC participates in load balancer or gateway backend pools that cannot be recreated automatically."

  value="$(jq '[.properties.tapConfigurations[]?] | length' "$nic")"
  [ "$value" -eq 0 ] || add_blocker "The NIC has virtual network TAP configurations."

  value="$(jq '[.properties.securityRules[]? | select(((.properties.sourceApplicationSecurityGroups // []) | length) > 0 or ((.properties.destinationApplicationSecurityGroups // []) | length) > 0)] | length' "$nsg")"
  [ "$value" -eq 0 ] || add_blocker "The NIC NSG contains Application Security Group rules that cannot be resolved cross-tenant."

  value="$(jq -r '.properties.networkSecurityGroup.id // empty' "$subnet")"
  if [ -n "$value" ]; then
    if [ -n "$(jq -r '.properties.networkSecurityGroup.id // empty' "$nic")" ]; then
      add_blocker "The source uses both a subnet NSG and a NIC NSG. Combined NSG topology is not cloned; map the effective rules by hand."
    else
      add_blocker "The source is protected only by a subnet NSG. This tool clones NIC-level NSGs only and will not silently claim the effective rules were preserved."
    fi
  fi

  security_type="$(jq -r '.properties.securityProfile.securityType // empty' "$vm")"
  case "$security_type" in
    ''|Standard|TrustedLaunch) ;;
    ConfidentialVM|ConfidentialVM_*) add_blocker "Confidential VM security type '$security_type' is not supported." ;;
    *) add_blocker "Unknown securityProfile.securityType '$security_type'." ;;
  esac

  value="$(jq -r '.properties.securityProfile.encryptionAtHost // false' "$vm")"
  [ "$value" != "true" ] || add_blocker "Encryption at host is enabled on the source VM and is not reproduced by this tool."

  value="$(jq -r '.plan.name // empty' "$vm")"
  [ -z "$value" ] || add_blocker "The source VM uses marketplace plan '$value'. Accept the plan terms and deploy from the marketplace image in the destination tenant instead."

  for value in availabilitySet virtualMachineScaleSet proximityPlacementGroup host hostGroup capacityReservationGroup; do
    if [ -n "$(jq -r --arg k "$value" '.properties[$k].id // empty' "$vm")" ]; then
      add_blocker "The source VM references a $value that cannot be recreated cross-tenant automatically."
    fi
  done

  value="$(jq -r '.properties.additionalCapabilities.ultraSSDEnabled // false' "$vm")"
  [ "$value" != "true" ] || add_blocker "Ultra disk support is enabled on the source VM. Ultra disks are outside this tool's support boundary."

  value="$(jq -r '.properties.storageProfile.osDisk.vhd.uri // empty' "$vm")"
  [ -z "$value" ] || add_blocker "The OS disk is unmanaged (page blob VHD). Convert it to a managed disk first."

  value="$(jq -r '.properties.storageProfile.osDisk.diffDiskSettings.option // empty' "$vm")"
  [ -z "$value" ] || add_blocker "The OS disk is ephemeral (diffDiskSettings=$value) and cannot be snapshotted."

  value="$(jq '[.properties.storageProfile.dataDisks[]? | select((.managedDisk.id // "") == "")] | length' "$vm")"
  [ "$value" -eq 0 ] || add_blocker "At least one data disk is not a managed disk."

  value="$(jq '[.[] | select((.resource.properties.encryption.type // "EncryptionAtRestWithPlatformKey") != "EncryptionAtRestWithPlatformKey")] | length' "$disks")"
  [ "$value" -eq 0 ] || add_blocker "At least one disk uses a customer-managed key. Cross-tenant DES/key migration requires a separate plan."

  value="$(jq '[.[] | select(((.resource.properties.encryption.diskEncryptionSetId // "") | length) > 0)] | length' "$disks")"
  [ "$value" -eq 0 ] || add_blocker "At least one disk references a disk encryption set."

  value="$(jq '[.[] | select((.resource.properties.encryptionSettingsCollection.enabled // false) == true)] | length' "$disks")"
  [ "$value" -eq 0 ] || add_blocker "Azure Disk Encryption settings are present on at least one disk."

  value="$(jq '[.[] | select((.resource.properties.maxShares // 1) > 1)] | length' "$disks")"
  [ "$value" -eq 0 ] || add_blocker "Shared disks (maxShares > 1) are not supported."

  value="$(jq -r '[.[] | select((.resource.sku.name // "") | test("^(UltraSSD_LRS|PremiumV2_LRS)$")) | .resource.name] | join(", ")' "$disks")"
  [ -z "$value" ] || add_blocker "Ultra and Premium SSD v2 disks cannot be snapshotted and uploaded by this tool: $value"

  value="$(jq -r '[.[] | select(((.resource.properties.diskSizeBytes // 0) | tonumber) <= 0) | .resource.name] | join(", ")' "$disks")"
  [ -z "$value" ] || add_blocker "diskSizeBytes is missing for: $value. The exact byte size is required for a direct upload."

  value="$(jq -r '[.[] | select(.role == "OS")] | length' "$disks")"
  [ "$value" -eq 1 ] || add_blocker "Exactly one OS disk is required; found $value."

  value="$(jq -r '[.[] | select(.role == "OS") | .resource.properties.hyperVGeneration // ""][0] // ""' "$disks")"
  [ -n "$value" ] || add_blocker "The OS disk does not expose hyperVGeneration. Generation cannot be proven, so the copy is blocked."

  value="$(jq -r '[.[] | select(.role == "OS") | .resource.properties.osType // ""][0] // ""' "$disks")"
  case "$value" in
    Windows|Linux) ;;
    *) add_blocker "The OS disk does not expose a supported osType (found '${value:-none}')." ;;
  esac

  value="$(jq '
    [.value[]?
     | select(((.properties.type // "") | ascii_downcase | contains("azurediskencryption"))
              or (((.properties.publisher // "") | ascii_downcase | contains("azure.security"))
                  and ((.properties.type // "") | ascii_downcase | contains("diskencryption"))))
    ] | length' "$extensions")"
  [ "$value" -eq 0 ] || add_blocker "The Azure Disk Encryption extension is installed. Key Vault and key migration must be planned separately."

  fail_on_blockers "source inventory"

  storage_uri="$(jq -r '.properties.diagnosticsProfile.bootDiagnostics.storageUri // empty' "$vm")"
  if [ -n "$storage_uri" ]; then
    warn "The source uses a boot-diagnostics storage account. The destination will use managed boot diagnostics instead."
  fi

  identity_type="$(jq -r '.identity.type // empty' "$vm")"
  if [ -n "$identity_type" ]; then
    warn "Managed identity '$identity_type' is tenant-bound. It is not copied and must be recreated and re-granted in the destination tenant."
  fi

  if [ "$(jq '[.value[]?] | length' "$extensions")" -gt 0 ]; then
    warn "VM extensions are not copied. They must be reinstalled deliberately in the destination tenant:"
    jq -r '.value[]? | "    - \(.name): \(.properties.publisher // "?")/\(.properties.type // "?")"' "$extensions" >&2
  fi

  license_type="$(jq -r '.properties.licenseType // empty' "$vm")"
  if [ -n "$license_type" ] && [ "$license_type" != "None" ]; then
    if [ "$KEEP_LICENSE_TYPE" = "1" ]; then
      warn "Source licenseType=$license_type will be copied because --keep-license-type was supplied."
      ask_yes_no "Confirm the customer approved carrying licenseType=$license_type into the destination tenant" ||
        die "licenseType was not approved"
    else
      warn "Source licenseType=$license_type will NOT be copied. Re-run with --keep-license-type only after written approval."
    fi
  fi
}

ask_domain_controller_safeguards() {
  DC_MODE=0
  if ask_yes_no "Is this VM an Active Directory domain controller"; then
    DC_MODE=1
    cat >&2 <<'EOF'

Domain controller safeguards:
  - dcdiag and repadmin must report a healthy directory and DNS.
  - The destination VM generation must support VM-Generation ID.
  - A current System State backup must exist and be restorable.
  - Cloning a DC without these safeguards causes USN rollback and divergence.
  - Deploying and promoting a new DC in the destination tenant is safer.
EOF
    ask_yes_no "Confirm AD DS and DNS health were verified with dcdiag and repadmin" ||
      die "Domain controller health was not confirmed"
    ask_yes_no "Confirm VM-Generation ID support and a current System State backup exist" ||
      die "Domain controller safeguards were not confirmed"
    ask_yes_no "Confirm the Active Directory owner approved this copy" ||
      die "Active Directory owner approval is missing"
  fi
}

ask_public_ip_requirement() {
  PUBLIC_IP_REQUIRED=0
  cat >&2 <<'EOF'

Public IP handling: the source public IP address and its resource are never
copied. If the destination needs inbound internet access, a NEW Standard static
IPv4 address is created and its new value must be published to DNS, firewalls
and allowlists.
EOF
  if ask_yes_no "Does the destination VM require a public IP address"; then
    ask_yes_no "Confirm creating a NEW Standard static public IPv4 (the address will differ from the source)" &&
      PUBLIC_IP_REQUIRED=1
  fi
}

# ---------------------------------------------------------------------------
# Destination preflight (read-only)
# ---------------------------------------------------------------------------

destination_nsg_name() {
  local name
  name="$(jq -r '.name // empty' "$TMP_DIR/source-nsg.json" 2>/dev/null || true)"
  [ -n "$name" ] || name="${SOURCE_VM_NAME}-nsg"
  printf '%s' "$name"
}

destination_nsg_id() {
  destination_resource_id "Microsoft.Network/networkSecurityGroups" "$(destination_nsg_name)"
}

destination_disk_id_for() {
  destination_resource_id "Microsoft.Compute/disks" "$1"
}

source_snapshot_id_for() {
  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Compute/snapshots/%s' \
    "$SOURCE_SUBSCRIPTION" "$SOURCE_RESOURCE_GROUP" "$1"
}

state_owns_resource() {
  local id="$1" lower
  lower="$(to_lower "$id")"
  [ -d "$STATE_DIR" ] || return 1
  local file
  for file in "$STATE_DIR"/disk-*-state.json; do
    [ -f "$file" ] || continue
    if [ "$(jq -r --arg id "$lower" '
        [((.destinationDiskId // "") | ascii_downcase), ((.snapshotId // "") | ascii_downcase)]
        | index($id) | if . == null then "no" else "yes" end' "$file")" = "yes" ]; then
      return 0
    fi
  done
  return 1
}

check_provider_registration() {
  local provider file state
  for provider in Microsoft.Compute Microsoft.Network; do
    file="$TMP_DIR/provider-$provider.json"
    if arm_get_to_file "/subscriptions/$DESTINATION_SUBSCRIPTION/providers/$provider" "$RESOURCES_API" "$file"; then
      state="$(jq -r '.registrationState // "Unknown"' "$file")"
      if [ "$state" != "Registered" ]; then
        add_blocker "Resource provider $provider is '$state' in the destination subscription."
      else
        log "Destination provider $provider: Registered"
      fi
    else
      add_blocker "Could not read the registration state of $provider in the destination subscription."
    fi
  done
}

report_effective_permissions() {
  local scope file count
  scope="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$DESTINATION_RESOURCE_GROUP"
  file="$TMP_DIR/permissions.json"
  if arm_get_url_to_file \
      "$ARM_ENDPOINT$scope/providers/Microsoft.Authorization/permissions?api-version=$AUTHZ_API" "$file"; then
    count="$(jq '[.value[]?] | length' "$file")"
    log "Effective permission entries on the destination resource group: $count"
    jq -r '[.value[]? | (.actions // [])[]] | unique | .[0:12] | .[] | "    action: " + .' "$file" >&2 || true
  else
    warn "Effective permissions could not be read. Continue only if destination RBAC was verified out of band."
  fi
}

check_destination_scopes() {
  local rg_id network_rg_id subnet_id
  rg_id="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$DESTINATION_RESOURCE_GROUP"
  network_rg_id="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$DESTINATION_NETWORK_RESOURCE_GROUP"
  subnet_id="$(destination_subnet_id)"

  resource_exists "$rg_id" "$RESOURCES_API" ||
    add_blocker "Destination resource group does not exist or is not readable: $DESTINATION_RESOURCE_GROUP"
  resource_exists "$network_rg_id" "$RESOURCES_API" ||
    add_blocker "Destination network resource group does not exist or is not readable: $DESTINATION_NETWORK_RESOURCE_GROUP"

  if arm_get_to_file "$subnet_id" "$NETWORK_API" "$TMP_DIR/destination-subnet.json"; then
    log "Destination subnet resolved: $DESTINATION_VNET/$DESTINATION_SUBNET"
  else
    add_blocker "Destination subnet does not exist or is not readable: $DESTINATION_VNET/$DESTINATION_SUBNET"
    printf '{"properties":{}}' > "$TMP_DIR/destination-subnet.json"
  fi
}

# Local CIDR arithmetic only. No mutating or IP-availability action is invoked.
validate_destination_private_ip() {
  local prefixes prefix matched=0 assigned nics_file
  prefixes="$(jq -r '
    [(.properties.addressPrefix // empty), (.properties.addressPrefixes[]? // empty)] | .[]
  ' "$TMP_DIR/destination-subnet.json" 2>/dev/null || true)"

  if [ -z "$prefixes" ]; then
    add_blocker "The destination subnet exposes no address prefix, so private IP membership cannot be proven."
    return 0
  fi

  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    is_valid_ipv4_cidr "$prefix" || continue
    if ip_in_cidr "$DESTINATION_PRIVATE_IP" "$prefix"; then
      matched=1
      log "Private IP $DESTINATION_PRIVATE_IP is inside subnet prefix $prefix"
      if ip_is_azure_reserved "$DESTINATION_PRIVATE_IP" "$prefix"; then
        add_blocker "Private IP $DESTINATION_PRIVATE_IP is reserved by Azure inside $prefix (first four and last addresses)."
      fi
    fi
  done <<EOF
$prefixes
EOF

  [ "$matched" -eq 1 ] ||
    add_blocker "Private IP $DESTINATION_PRIVATE_IP is not inside any prefix of $DESTINATION_VNET/$DESTINATION_SUBNET."

  nics_file="$TMP_DIR/destination-nics.json"
  if arm_list_to_file \
      "$ARM_ENDPOINT/subscriptions/$DESTINATION_SUBSCRIPTION/providers/Microsoft.Network/networkInterfaces?api-version=$NETWORK_API" \
      "$nics_file"; then
    assigned="$(jq -r --arg ip "$DESTINATION_PRIVATE_IP" --arg self "$(to_lower "$(destination_nic_id)")" '
      [ .value[]
        | select((.id // "" | ascii_downcase) != $self)
        | . as $nic
        | .properties.ipConfigurations[]?
        | select(.properties.privateIPAddress == $ip)
        | $nic.name ] | unique | join(", ")' "$nics_file")"
    if [ -n "$assigned" ]; then
      add_blocker "Private IP $DESTINATION_PRIVATE_IP is already assigned in the destination subscription (NIC: $assigned)."
    else
      log "Private IP $DESTINATION_PRIVATE_IP is not assigned to any other destination NIC"
    fi
  else
    add_blocker "Destination network interfaces could not be listed, so IP conflicts cannot be ruled out."
  fi
}

check_destination_name_conflicts() {
  local id run_id index count disk_name snapshot

  id="$(destination_vm_id)"
  if resource_exists "$id" "$VM_API"; then
    add_blocker "Destination VM name already exists: $(resource_id_field "$id" name)"
  fi

  id="$(destination_nic_id)"
  if resource_exists "$id" "$NETWORK_API"; then
    add_blocker "Destination NIC name already exists: $(resource_id_field "$id" name)"
  fi

  if [ -n "$(jq -r '.name // empty' "$TMP_DIR/source-nsg.json")" ]; then
    id="$(destination_nsg_id)"
    if resource_exists "$id" "$NETWORK_API"; then
      add_blocker "Destination NSG name already exists: $(resource_id_field "$id" name)"
    fi
  fi

  if [ "$PUBLIC_IP_REQUIRED" = "1" ]; then
    id="$(destination_pip_id)"
    if resource_exists "$id" "$NETWORK_API"; then
      add_blocker "Destination public IP name already exists: $(resource_id_field "$id" name)"
    fi
  fi

  run_id=""
  [ -f "$STATE_DIR/run-id" ] && run_id="$(cat "$STATE_DIR/run-id")"

  count="$(jq 'length' "$TMP_DIR/disks.json")"
  index=0
  while [ "$index" -lt "$count" ]; do
    disk_name="$(jq -r ".[$index].resource.name" "$TMP_DIR/disks.json")"
    id="$(destination_disk_id_for "$disk_name")"
    if resource_exists "$id" "$DISK_API"; then
      if state_owns_resource "$id"; then
        log "Destination disk belongs to this migration state and will be resumed: $disk_name"
      else
        add_blocker "Destination disk name already exists and is not tracked by this migration: $disk_name"
      fi
    fi
    if [ -n "$run_id" ]; then
      snapshot="$(source_snapshot_id_for "$(snapshot_name_for "$SOURCE_VM_NAME" "$index" "$run_id")")"
      if resource_exists "$snapshot" "$DISK_API" && ! state_owns_resource "$snapshot"; then
        add_blocker "Source snapshot name already exists and is not tracked by this migration: $(resource_id_field "$snapshot" name)"
      fi
    fi
    index=$((index + 1))
  done
}

check_destination_disk_support() {
  local skus_file count index sku_name record restricted zone

  skus_file="$TMP_DIR/destination-skus.json"
  zone="$(jq -r '.zones[0] // empty' "$TMP_DIR/source-vm.json")"
  count="$(jq 'length' "$TMP_DIR/disks.json")"
  index=0
  while [ "$index" -lt "$count" ]; do
    sku_name="$(jq -r ".[$index].resource.sku.name // empty" "$TMP_DIR/disks.json")"
    if [ -z "$sku_name" ]; then
      add_blocker "Disk $(jq -r ".[$index].resource.name" "$TMP_DIR/disks.json") does not expose a SKU name."
      index=$((index + 1))
      continue
    fi
    record="$(jq -r --arg sku "$sku_name" '
      [.value[] | select(.resourceType == "disks" and .name == $sku)] | length' "$skus_file")"
    if [ "$record" -eq 0 ]; then
      add_blocker "Disk SKU $sku_name is not offered in $LOCATION for the destination subscription."
    else
      restricted="$(jq -r --arg sku "$sku_name" --arg location "$LOCATION" '
        [ .value[]
          | select(.resourceType == "disks" and .name == $sku)
          | .restrictions[]?
          | select(((.restrictionInfo.locations // .values // []) | map(ascii_downcase) | index($location | ascii_downcase)) != null)
        ] | length' "$skus_file")"
      [ "$restricted" -eq 0 ] ||
        add_blocker "Disk SKU $sku_name is restricted for the destination subscription in $LOCATION."
    fi

    if [ -n "$zone" ]; then
      restricted="$(jq -r --arg sku "$sku_name" --arg location "$LOCATION" --arg zone "$zone" '
        [ .value[]
          | select(.resourceType == "disks" and .name == $sku)
          | .locationInfo[]?
          | select((.location // "" | ascii_downcase) == ($location | ascii_downcase))
          | (.zones // [])
        ] | flatten | index($zone) | if . == null then 0 else 1 end' "$skus_file")"
      [ "$restricted" = "1" ] ||
        add_blocker "Disk SKU $sku_name is not available in zone $zone of $LOCATION."
    fi

    if [ "$(jq -r ".[$index].config.writeAcceleratorEnabled // false" "$TMP_DIR/disks.json")" = "true" ]; then
      case "$sku_name" in
        Premium_LRS|Premium_ZRS) ;;
        *) add_blocker "Write accelerator requires a Premium SSD disk but $(jq -r ".[$index].resource.name" "$TMP_DIR/disks.json") uses $sku_name." ;;
      esac
    fi
    index=$((index + 1))
  done
}

load_destination_catalog() {
  local skus_file usage_file
  skus_file="$TMP_DIR/destination-skus.json"
  usage_file="$TMP_DIR/destination-usages.json"

  if [ ! -s "$skus_file" ]; then
    arm_list_to_file \
      "$ARM_ENDPOINT/subscriptions/$DESTINATION_SUBSCRIPTION/providers/Microsoft.Compute/skus?api-version=$COMPUTE_SKU_API&%24filter=location%20eq%20%27$(to_lower "$LOCATION")%27" \
      "$skus_file" || die "Could not read destination compute SKU availability for $LOCATION"
  fi
  if [ ! -s "$usage_file" ]; then
    arm_get_url_to_file \
      "$ARM_ENDPOINT/subscriptions/$DESTINATION_SUBSCRIPTION/providers/Microsoft.Compute/locations/$(to_lower "$LOCATION")/usages?api-version=$COMPUTE_USAGE_API" \
      "$usage_file" || die "Could not read destination compute quota for $LOCATION"
  fi
  [ "$(jq '[.value[]?] | length' "$skus_file")" -gt 0 ] ||
    die "The destination SKU catalog for $LOCATION is empty; compatibility cannot be proven."
}

load_source_catalog() {
  local skus_file
  skus_file="$TMP_DIR/source-skus.json"
  if [ ! -s "$skus_file" ]; then
    arm_list_to_file \
      "$ARM_ENDPOINT/subscriptions/$SOURCE_SUBSCRIPTION/providers/Microsoft.Compute/skus?api-version=$COMPUTE_SKU_API&%24filter=location%20eq%20%27$(to_lower "$SOURCE_LOCATION")%27" \
      "$skus_file" || warn "Source compute SKU metadata could not be read; minimum vCPU and memory will be requested explicitly."
  fi
  [ -s "$skus_file" ] || printf '{"value":[]}' > "$skus_file"
}

# ---------------------------------------------------------------------------
# Size requirements, candidate filtering and live retail pricing
# ---------------------------------------------------------------------------

# Derives the compatibility requirements of the source VM. Pure jq: no Azure
# calls, so it is exercised directly by the fixture tests.
build_size_requirements() {
  local vm_file="$1" nic_file="$2" disks_file="$3" source_skus_file="$4"

  jq -n \
    --slurpfile vm "$vm_file" \
    --slurpfile nic "$nic_file" \
    --slurpfile disks "$disks_file" \
    --slurpfile skus "$source_skus_file" \
    '
    def capv($sku; $n): ([$sku.capabilities[]? | select(.name == $n) | .value][0] // null);
    def capnum($sku; $n): (capv($sku; $n) | if . == null then null else (try tonumber catch null) end);

    ($vm[0]) as $source
    | ($nic[0]) as $interface
    | ($disks[0]) as $allDisks
    | ($source.properties.hardwareProfile.vmSize // "") as $size
    | ([$skus[0].value[]? | select(.resourceType == "virtualMachines" and .name == $size)][0] // null) as $sku
    | {
        sourceSize: $size,
        sourceFamily: (if $sku == null then null else ($sku.family // null) end),
        vcpus: (if $sku == null then null else capnum($sku; "vCPUs") end),
        memoryGB: (if $sku == null then null else capnum($sku; "MemoryGB") end),
        architecture: (if $sku == null then null else capv($sku; "CpuArchitectureType") end),
        hyperVGeneration: ([$allDisks[] | select(.role == "OS") | .resource.properties.hyperVGeneration][0] // ""),
        osType: ([$allDisks[] | select(.role == "OS") | .resource.properties.osType][0] // ""),
        dataDiskCount: ([$allDisks[] | select(.role == "DATA")] | length),
        premiumIO: (([$allDisks[] | select((.resource.sku.name // "") | test("^Premium"))] | length) > 0),
        acceleratedNetworking: (($interface.properties.enableAcceleratedNetworking // false) == true),
        trustedLaunch: (($source.properties.securityProfile.securityType // "") == "TrustedLaunch"),
        writeAccelerator: (([$allDisks[] | select((.config.writeAcceleratorEnabled // false) == true)] | length) > 0),
        zone: ($source.zones[0]? // ""),
        totalDiskBytes: ([$allDisks[] | (.resource.properties.diskSizeBytes // 0)] | add // 0)
      }
    | .metadataComplete = (.vcpus != null and .memoryGB != null)
    '
}

# Evaluates every destination VM SKU against the source requirements and returns
# each one with the list of reasons that make it unusable. An empty reason list
# means the size is a valid candidate. Missing capability metadata produces a
# reason instead of an assumption of support.
evaluate_size_candidates() {
  local skus_file="$1" requirements_file="$2" usages_file="$3" location="$4"

  jq -n \
    --slurpfile skus "$skus_file" \
    --slurpfile req "$requirements_file" \
    --slurpfile usage "$usages_file" \
    --arg location "$location" \
    '
    def capv($n): ([.capabilities[]? | select(.name == $n) | .value][0] // null);
    def capnum($n): (capv($n) | if . == null then null else (try tonumber catch null) end);
    def capbool($n): (capv($n) | if . == null then null else ((. | ascii_downcase) == "true") end);
    def caplist($n): (capv($n) | if . == null then null else ([splits(",")] | map(ascii_downcase | sub("^ +"; "") | sub(" +$"; ""))) end);

    ($req[0]) as $r
    | ($usage[0].value // []) as $usages
    | ([$usages[] | select(((.name.value // "") | ascii_downcase) == "cores")][0]) as $cores
    | ([$skus[0].value[]? | select(.resourceType == "virtualMachines")]) as $vms
    | def familyQuota($family):
        (if $family == null then null
         else ([$usages[] | select(((.name.value // "") | ascii_downcase) == ($family | ascii_downcase))][0])
         end);
      [ $vms[]
        | . as $s
        | {
            name: (.name // ""),
            family: (.family // null),
            vcpus: capnum("vCPUs"),
            memoryGB: capnum("MemoryGB"),
            maxDataDisks: capnum("MaxDataDiskCount"),
            premiumIO: capbool("PremiumIO"),
            acceleratedNetworking: capbool("AcceleratedNetworkingEnabled"),
            architecture: capv("CpuArchitectureType"),
            hyperV: caplist("HyperVGenerations"),
            trustedLaunchDisabled: capbool("TrustedLaunchDisabled"),
            zones: ([$s.locationInfo[]?
                     | select(((.location // "") | ascii_downcase) == ($location | ascii_downcase))
                     | .zones[]?] | unique),
            locationRestricted: (([$s.restrictions[]?
                     | select(.type == "Location")
                     | select(((((.restrictionInfo.locations // .values // []) | map(ascii_downcase))
                                | index($location | ascii_downcase))) != null)] | length) > 0),
            restrictedZones: ([$s.restrictions[]?
                     | select(.type == "Zone")
                     | ((.restrictionInfo.zones // [])[])] | unique)
          }
        | . + {familyUsage: familyQuota(.family)}
        | . as $c
        | . + {reasons: (
              (if $c.name == "" then ["SKU name missing"] else [] end)
            + (if $c.family == null then ["SKU family missing"] else [] end)
            + (if $c.vcpus == null then ["vCPUs capability missing"] else [] end)
            + (if $c.memoryGB == null then ["MemoryGB capability missing"] else [] end)
            + (if $c.maxDataDisks == null then ["MaxDataDiskCount capability missing"] else [] end)
            + (if $c.hyperV == null then ["HyperVGenerations capability missing"] else [] end)
            + (if ($c.vcpus != null and $c.vcpus < $r.vcpus) then ["fewer vCPUs than required"] else [] end)
            + (if ($c.memoryGB != null and $c.memoryGB < $r.memoryGB) then ["less memory than required"] else [] end)
            + (if ($c.maxDataDisks != null and $c.maxDataDisks < $r.dataDiskCount) then ["not enough data disk slots"] else [] end)
            + (if ($r.hyperVGeneration == "") then ["source Hyper-V generation unknown"]
               elif ($c.hyperV != null and (($c.hyperV | index($r.hyperVGeneration | ascii_downcase)) == null))
               then ["no support for generation " + $r.hyperVGeneration] else [] end)
            + (if ($r.premiumIO == true and $c.premiumIO != true) then ["no premium storage support"] else [] end)
            + (if ($r.acceleratedNetworking == true and $c.acceleratedNetworking != true) then ["no accelerated networking support"] else [] end)
            + (if ($r.trustedLaunch == true and $c.trustedLaunchDisabled == true) then ["Trusted Launch is disabled for this size"] else [] end)
            + (if ($r.trustedLaunch == true and ($c.hyperV == null or (($c.hyperV | index("v2")) == null))) then ["Trusted Launch requires generation V2"] else [] end)
            + (if ($r.architecture != null and $c.architecture != null
                   and (($c.architecture | ascii_downcase) != ($r.architecture | ascii_downcase)))
               then ["different CPU architecture"] else [] end)
            + (if ($r.architecture != null and $c.architecture == null)
               then ["CPU architecture capability missing"] else [] end)
            + (if $c.locationRestricted then ["restricted in " + $location] else [] end)
            + (if (($r.zone // "") != "" and (($c.zones | index($r.zone)) == null)) then ["not offered in zone " + $r.zone] else [] end)
            + (if (($r.zone // "") != "" and (($c.restrictedZones | index($r.zone)) != null)) then ["restricted in zone " + $r.zone] else [] end)
            + (if ($r.writeAccelerator == true
                   and (($c.family // "") | ascii_downcase) != (($r.sourceFamily // "") | ascii_downcase))
               then ["write accelerator support cannot be proven outside the source SKU family"] else [] end)
            + (if $cores == null then ["regional vCPU quota unavailable"] else [] end)
            + (if ($cores != null and $c.vcpus != null and (($cores.currentValue + $c.vcpus) > $cores.limit))
               then ["regional vCPU quota exceeded"] else [] end)
            + (if $c.familyUsage == null then ["family quota entry missing"] else [] end)
            + (if ($c.familyUsage != null and $c.vcpus != null
                   and (($c.familyUsage.currentValue + $c.vcpus) > $c.familyUsage.limit))
               then ["family quota exceeded"] else [] end)
          )}
      ]
    | map({name, family, vcpus, memoryGB, maxDataDisks, premiumIO, acceleratedNetworking,
           architecture, hyperV, zones, reasons})
    | sort_by(.vcpus, .memoryGB, .name)
    '
}

# Convenience wrapper that keeps only the fully compatible candidates.
filter_size_candidates() {
  evaluate_size_candidates "$@" | jq 'map(select((.reasons | length) == 0)) | map(del(.reasons))'
}

explain_size_rejection() {
  local skus_file="$1" requirements_file="$2" usages_file="$3" location="$4" size="$5"
  evaluate_size_candidates "$skus_file" "$requirements_file" "$usages_file" "$location" |
    jq -r --arg size "$size" '
      [.[] | select(.name == $size)][0]
      | if . == null then "  " + $size + ": not offered in this region for this subscription"
        else "  " + $size + ": " + ((.reasons | join("; ")) | if . == "" then "compatible" else . end)
        end'
}

merge_retail_pages() {
  local accumulator="$1" page="$2"
  jq -s '{Items:((.[0].Items // []) + (.[1].Items // []))}' "$accumulator" "$page"
}

# Keeps only current, primary, pay-as-you-go hourly VM meters for the region and
# classifies them as Windows or base Linux. Ambiguity yields no price at all.
normalize_retail_prices() {
  local items_file="$1" region="$2" currency="$3" os_class="$4"

  jq \
    --arg region "$region" \
    --arg currency "$currency" \
    --arg osClass "$os_class" \
    '
    def text: (((.productName // "") + " " + (.skuName // "") + " " + (.meterName // "")) | ascii_downcase);
    def isSpot: (text | (contains("spot") or contains("low priority") or contains("lowpriority")));
    def isDevTest: (((.productName // "") | ascii_downcase) | (contains("dev/test") or contains("devtest")));
    def isWindows: (((.productName // "") | ascii_downcase) | contains("windows"));

    [ .Items[]?
      | select((.type // "") == "Consumption")
      | select((.serviceName // "") == "Virtual Machines")
      | select(((.armRegionName // "") | ascii_downcase) == ($region | ascii_downcase))
      | select((.currencyCode // "") == $currency)
      | select((.isPrimaryMeterRegion // false) == true)
      | select(((.armSkuName // "") | length) > 0)
      | select(((.reservationTerm // "") | length) == 0)
      | select(((.savingsPlan // []) | type) == "array")
      | select(((.unitOfMeasure // "") | ascii_downcase) | startswith("1 hour"))
      | select((.tierMinimumUnits // 0) == 0)
      | select((.retailPrice // 0) > 0)
      | select((.effectiveEndDate // null) == null)
      | select((isSpot | not) and (isDevTest | not))
      | select(if $osClass == "Windows" then isWindows else (isWindows | not) end)
      | {armSkuName, retailPrice, unitOfMeasure, meterName, productName, skuName}
    ]
    | group_by(.armSkuName)
    | map(min_by(.retailPrice))
    | sort_by(.armSkuName)
    ' "$items_file"
}

fetch_retail_prices() {
  local region="$1" currency="$2" os_class="$3" output="$4"
  local url page accumulator merged pages=0 filter

  filter="serviceName eq 'Virtual Machines' and priceType eq 'Consumption' and armRegionName eq '$(to_lower "$region")'"
  url="$RETAIL_PRICES_ENDPOINT?api-version=$RETAIL_PRICES_API_VERSION&currencyCode=$currency&\$filter=$(printf '%s' "$filter" | sed -e 's/ /%20/g' -e "s/'/%27/g")"
  accumulator="$TMP_DIR/retail-accumulator-$RANDOM.json"
  printf '{"Items":[]}' > "$accumulator"

  log "Querying the Azure Retail Prices API for $region in $currency"
  while [ -n "$url" ] && [ "$pages" -lt "$RETAIL_PRICE_MAX_PAGES" ]; do
    page="$TMP_DIR/retail-page-$pages.json"
    if ! curl --silent --show-error --fail --location --max-time 60 --output "$page" "$url"; then
      warn "The Retail Prices API could not be reached. Every estimate will show Unavailable."
      printf '[]' > "$output"
      return 0
    fi
    if ! jq -e '.Items? != null' "$page" >/dev/null 2>&1; then
      warn "The Retail Prices API returned an unexpected payload. Every estimate will show Unavailable."
      printf '[]' > "$output"
      return 0
    fi
    merged="$TMP_DIR/retail-merged-$pages.json"
    merge_retail_pages "$accumulator" "$page" > "$merged"
    mv "$merged" "$accumulator"
    url="$(jq -r '.NextPageLink // empty' "$page")"
    pages=$((pages + 1))
  done

  if [ -n "$url" ]; then
    warn "Retail price pagination stopped after $RETAIL_PRICE_MAX_PAGES pages; some sizes may show Unavailable."
  fi

  normalize_retail_prices "$accumulator" "$region" "$currency" "$os_class" > "$output"
  log "Normalized $(jq 'length' "$output") $os_class pay-as-you-go hourly VM meters"
}

rank_size_candidates() {
  local candidates_file="$1" prices_file="$2"
  jq -n \
    --slurpfile candidates "$candidates_file" \
    --slurpfile prices "$prices_file" \
    --argjson hours "$MONTHLY_HOURS" \
    '
    ($prices[0] // []) as $priceList
    | def priceFor($name): ([$priceList[] | select(.armSkuName == $name) | .retailPrice][0]);
      [$candidates[0][] | . + {hourly: priceFor(.name)}]
    | map(. + {monthly: (if .hourly == null then null else (.hourly * $hours) end)})
    | sort_by([(if .hourly == null then 1 else 0 end), (.hourly // 0), .name])
    '
}

format_price() {
  local value="$1"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    printf 'Unavailable'
    return
  fi
  awk -v v="$value" 'BEGIN {printf "%.2f", v}'
}

print_pricing_disclaimer() {
  cat >&2 <<EOF

Pricing note: figures come from the public Azure Retail Prices API for
$LOCATION in $CURRENCY and assume ${MONTHLY_HOURS} hours per month of pay-as-you-go
compute. They EXCLUDE negotiated discounts, taxes, reservations, savings plans,
Azure Hybrid Benefit, software licenses, managed disks, snapshots, bandwidth,
egress, backup, and every other resource. They are an order-of-magnitude
comparison aid, not a quote.
EOF
}

# ---------------------------------------------------------------------------
# Interactive size selection
# ---------------------------------------------------------------------------

is_positive_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

is_positive_number() {
  printf '%s' "$1" | awk '{exit !($0 ~ /^[0-9]+(\.[0-9]+)?$/ && $0 + 0 > 0)}'
}

prepare_size_requirements() {
  local requirements="$TMP_DIR/size-requirements.json" vcpus memory patched

  build_size_requirements \
    "$TMP_DIR/source-vm.json" "$TMP_DIR/source-nic.json" \
    "$TMP_DIR/disks.json" "$TMP_DIR/source-skus.json" > "$requirements"

  if [ "$(jq -r '.metadataComplete' "$requirements")" != "true" ]; then
    warn "Compute SKU metadata for the source size $(jq -r '.sourceSize' "$requirements") is unavailable."
    warn "Minimum vCPU and memory must be supplied explicitly; they are never guessed."
    while true; do
      vcpus="$(read_line "Minimum required vCPU count")"
      is_positive_integer "$vcpus" && break
      printf 'Enter a positive integer.\n' >&2
    done
    while true; do
      memory="$(read_line "Minimum required memory in GiB")"
      is_positive_number "$memory" && break
      printf 'Enter a positive number.\n' >&2
    done
    patched="$TMP_DIR/size-requirements-patched.json"
    jq --argjson vcpus "$vcpus" --argjson memory "$memory" \
      '.vcpus = $vcpus | .memoryGB = $memory | .metadataComplete = true | .operatorSupplied = true' \
      "$requirements" > "$patched"
    mv "$patched" "$requirements"
  fi

  cat >&2 <<EOF

Source compatibility requirements:
  Source size:            $(jq -r '.sourceSize' "$requirements")
  vCPU / memory (GiB):    $(jq -r '.vcpus' "$requirements") / $(jq -r '.memoryGB' "$requirements")
  CPU architecture:       $(jq -r '.architecture // "not exposed"' "$requirements")
  Hyper-V generation:     $(jq -r '.hyperVGeneration' "$requirements")
  OS type:                $(jq -r '.osType' "$requirements")
  Data disks:             $(jq -r '.dataDiskCount' "$requirements")
  Premium storage:        $(jq -r '.premiumIO' "$requirements")
  Accelerated networking: $(jq -r '.acceleratedNetworking' "$requirements")
  Trusted Launch:         $(jq -r '.trustedLaunch' "$requirements")
  Write accelerator:      $(jq -r '.writeAccelerator' "$requirements")
  Availability zone:      $(jq -r 'if .zone == "" then "regional" else .zone end' "$requirements")
EOF
  printf '%s' "$requirements"
}

select_target_size() {
  local requirements="$1"
  local candidates ranked table count source_size chosen index answer eligible
  local os_class prices

  candidates="$TMP_DIR/size-candidates.json"
  ranked="$TMP_DIR/size-ranked.json"
  prices="$TMP_DIR/retail-prices.json"
  source_size="$(jq -r '.sourceSize' "$requirements")"

  filter_size_candidates "$TMP_DIR/destination-skus.json" "$requirements" \
    "$TMP_DIR/destination-usages.json" "$LOCATION" > "$candidates"

  count="$(jq 'length' "$candidates")"
  if [ "$count" -eq 0 ]; then
    printf '\nNo destination VM size satisfies the source requirements in %s.\n' "$LOCATION" >&2
    printf 'Diagnosis for the source size:\n' >&2
    explain_size_rejection "$TMP_DIR/destination-skus.json" "$requirements" \
      "$TMP_DIR/destination-usages.json" "$LOCATION" "$source_size" >&2
    die "Increase quota, choose another region or relax the requirements deliberately, then re-run."
  fi
  log "$count destination sizes satisfy every compatibility and quota requirement"

  os_class="$(jq -r '.osType' "$requirements")"
  [ "$os_class" = "Windows" ] || os_class="Linux"
  fetch_retail_prices "$LOCATION" "$CURRENCY" "$os_class" "$prices"

  rank_size_candidates "$candidates" "$prices" > "$ranked"

  table="$TMP_DIR/size-table.json"
  jq --arg source "$source_size" '
    (. | map(select(.name == $source))) as $sourceRow
    | (.[0:10]) as $top
    | if (($top | map(.name) | index($source)) == null) then ($top + $sourceRow) else $top end
  ' "$ranked" > "$table"

  printf '\nCompatible destination sizes (%s, %s, %s hourly meters):\n\n' \
    "$LOCATION" "$CURRENCY" "$os_class" >&2
  printf '  %-3s %-22s %-6s %-9s %-14s %-14s\n' "#" "SIZE" "vCPU" "MEM GiB" "HOURLY" "MONTHLY EST" >&2
  printf '  %s\n' "--------------------------------------------------------------------------------" >&2

  index=1
  while [ "$index" -le "$(jq 'length' "$table")" ]; do
    printf '  %-3s %-22s %-6s %-9s %-14s %-14s\n' \
      "$index" \
      "$(jq -r ".[$((index - 1))].name" "$table")" \
      "$(jq -r ".[$((index - 1))].vcpus" "$table")" \
      "$(jq -r ".[$((index - 1))].memoryGB" "$table")" \
      "$(format_price "$(jq -r ".[$((index - 1))].hourly // empty" "$table")")" \
      "$(format_price "$(jq -r ".[$((index - 1))].monthly // empty" "$table")")" >&2
    index=$((index + 1))
  done

  if [ "$(jq --arg source "$source_size" 'map(.name) | index($source) | if . == null then 0 else 1 end' "$candidates")" = "0" ]; then
    printf '\n' >&2
    warn "The source size $source_size is NOT a valid destination candidate:"
    explain_size_rejection "$TMP_DIR/destination-skus.json" "$requirements" \
      "$TMP_DIR/destination-usages.json" "$LOCATION" "$source_size" >&2
  fi

  print_pricing_disclaimer

  if [ -n "$TARGET_SIZE" ]; then
    eligible="$(jq -r --arg size "$TARGET_SIZE" 'map(.name) | index($size) | if . == null then "no" else "yes" end' "$candidates")"
    if [ "$eligible" != "yes" ]; then
      printf '\n' >&2
      explain_size_rejection "$TMP_DIR/destination-skus.json" "$requirements" \
        "$TMP_DIR/destination-usages.json" "$LOCATION" "$TARGET_SIZE" >&2
      die "The proposed size $TARGET_SIZE is not a compatible destination candidate"
    fi
    printf '\nThe proposed size %s is compatible. It is never selected automatically.\n' "$TARGET_SIZE" >&2
    if ask_yes_no "Approve $TARGET_SIZE as the destination VM size"; then
      SELECTED_SIZE="$TARGET_SIZE"
    else
      warn "The proposed size was rejected; choose a size explicitly."
      TARGET_SIZE=""
    fi
  fi

  if [ -z "$SELECTED_SIZE" ]; then
    while true; do
      answer="$(read_line "Select a destination size by number, or type an exact size name")"
      if [ -z "$answer" ]; then
        continue
      fi
      case "$answer" in
        ''|*[!0-9]*)
          chosen="$answer"
          ;;
        *)
          if [ "$answer" -ge 1 ] && [ "$answer" -le "$(jq 'length' "$table")" ]; then
            chosen="$(jq -r ".[$((answer - 1))].name" "$table")"
          else
            printf 'Choice out of range.\n' >&2
            continue
          fi
          ;;
      esac
      eligible="$(jq -r --arg size "$chosen" 'map(.name) | index($size) | if . == null then "no" else "yes" end' "$candidates")"
      if [ "$eligible" != "yes" ]; then
        printf 'Size %s is not in the compatible candidate set.\n' "$chosen" >&2
        continue
      fi
      ask_yes_no "Approve $chosen as the destination VM size" || continue
      SELECTED_SIZE="$chosen"
      break
    done
  fi

  log "Destination VM size approved: $SELECTED_SIZE"
}

# ---------------------------------------------------------------------------
# ARM request body builders
#
# These are pure jq transformations with no Azure calls, so the fixture tests
# exercise the exact payloads that would be sent.
# ---------------------------------------------------------------------------

build_snapshot_body() {
  local location="$1" source_disk_id="$2"
  jq -n --arg location "$location" --arg source "$source_disk_id" '{
    location:$location,
    sku:{name:"Standard_LRS"},
    properties:{
      creationData:{createOption:"Copy",sourceResourceId:$source},
      incremental:false,
      networkAccessPolicy:"AllowAll",
      publicNetworkAccess:"Enabled"
    }
  }'
}

# The direct-upload contract requires uploadSizeBytes = diskSizeBytes + 512 for
# the VHD footer. That arithmetic lives here only.
build_upload_disk_body() {
  local disk_record="$1" location="$2" create_option="$3"
  jq \
    --arg location "$location" \
    --arg createOption "$create_option" \
    '
    . as $record
    | {
        location:$location,
        sku:{name:($record.resource.sku.name)},
        tags:($record.resource.tags // {}),
        properties:{
          creationData:{
            createOption:$createOption,
            uploadSizeBytes:(($record.resource.properties.diskSizeBytes) + 512)
          },
          networkAccessPolicy:"AllowAll",
          publicNetworkAccess:"Enabled"
        }
      }
    | if $record.role == "OS" then
        .properties.osType = $record.resource.properties.osType
        | .properties.hyperVGeneration = $record.resource.properties.hyperVGeneration
        | (if ($record.resource.properties.securityProfile // null) != null
           then .properties.securityProfile = $record.resource.properties.securityProfile
           else . end)
      else . end
    | if ($record.resource.zones // null) != null then .zones = $record.resource.zones else . end
    ' "$disk_record"
}

build_destination_nsg_body() {
  local source_nsg="$1" location="$2"
  jq --arg location "$location" '{
    location:$location,
    tags:(.tags // {}),
    properties:{securityRules:[
      .properties.securityRules[]?
      | {name:.name, properties:(.properties | del(.provisioningState, .etag))}
    ]}
  }' "$source_nsg"
}

build_destination_nic_body() {
  local source_nic="$1" location="$2" private_ip="$3" subnet_id="$4" nsg_id="$5" pip_id="$6"
  jq \
    --arg location "$location" \
    --arg privateIp "$private_ip" \
    --arg subnetId "$subnet_id" \
    --arg nsgId "$nsg_id" \
    --arg pipId "$pip_id" \
    '
    . as $source
    | {
        location:$location,
        tags:($source.tags // {}),
        properties:{
          enableAcceleratedNetworking:($source.properties.enableAcceleratedNetworking // false),
          enableIPForwarding:($source.properties.enableIPForwarding // false),
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
    | if $nsgId != "" then .properties.networkSecurityGroup = {id:$nsgId} else . end
    | if $pipId != "" then .properties.ipConfigurations[0].properties.publicIPAddress = {id:$pipId} else . end
    | if ((($source.properties.dnsSettings.dnsServers // []) | length) > 0)
      then .properties.dnsSettings = {dnsServers:$source.properties.dnsSettings.dnsServers}
      else . end
    ' "$source_nic"
}

build_destination_vm_body() {
  local source_vm="$1" disks="$2" location="$3" nic_id="$4" disk_prefix="$5"
  local target_size="$6" keep_license="$7"

  jq -n \
    --arg location "$location" \
    --arg nicId "$nic_id" \
    --arg diskPrefix "$disk_prefix" \
    --arg targetSize "$target_size" \
    --argjson keepLicenseType "$keep_license" \
    --slurpfile vm "$source_vm" \
    --slurpfile disks "$disks" \
    '
    def destinationDisk($name): {id:($diskPrefix + $name)};
    ($vm[0]) as $source
    | ($disks[0]) as $allDisks
    | ($allDisks[] | select(.role == "OS")) as $os
    | {
        location:$location,
        tags:($source.tags // {}),
        properties:{
          hardwareProfile:{vmSize:$targetSize},
          storageProfile:{
            osDisk:{
              osType:($os.config.osType // $os.resource.properties.osType),
              name:$os.resource.name,
              createOption:"Attach",
              caching:($os.config.caching // "ReadWrite"),
              deleteOption:"Detach",
              writeAcceleratorEnabled:($os.config.writeAcceleratorEnabled // false),
              managedDisk:destinationDisk($os.resource.name)
            },
            dataDisks:[
              $allDisks[]
              | select(.role == "DATA")
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
          networkProfile:{networkInterfaces:[{id:$nicId,properties:{primary:true}}]},
          diagnosticsProfile:{bootDiagnostics:{enabled:true}}
        }
      }
    | if $source.properties.securityProfile != null
      then .properties.securityProfile = ($source.properties.securityProfile | del(.encryptionAtHost))
      else . end
    | if $keepLicenseType
         and (($source.properties.licenseType // "") != "")
         and ($source.properties.licenseType != "None")
      then .properties.licenseType = $source.properties.licenseType
      else . end
    | if $source.zones != null then .zones = $source.zones else . end
    '
}

# ---------------------------------------------------------------------------
# Preflight orchestration
# ---------------------------------------------------------------------------

print_policy_caveat() {
  cat >&2 <<'EOF'

Azure Policy caveat: a read-only preflight cannot prove that destination policy
assignments will accept a disk, NIC or VM creation. Run `--mode policy-test`
(a separate, explicitly confirmed mutation) to validate destination RBAC and
policy behaviour with a temporary 1 GiB upload disk.
EOF
}

print_preflight_summary() {
  local disk_count total_bytes
  disk_count="$(jq 'length' "$TMP_DIR/disks.json")"
  total_bytes="$(jq '[.[].resource.properties.diskSizeBytes] | add' "$TMP_DIR/disks.json")"

  cat >&2 <<EOF

Resolved copy plan
  Migration id:            $MIGRATION_ID
  State directory:         $STATE_DIR
  Source VM:               $SOURCE_VM_NAME
  Source id:               $SOURCE_VM_ID
  Source location:         $SOURCE_LOCATION
  Source power state:      $(vm_power_state "$SOURCE_VM_ID")
  Source private IPv4:     ${SOURCE_PRIVATE_IP:-unknown}
  Destination subscr.:     $DESTINATION_SUBSCRIPTION
  Managing tenant:         $MANAGING_TENANT
  Destination location:    $LOCATION
  Destination RG:          $DESTINATION_RESOURCE_GROUP
  Destination network RG:  $DESTINATION_NETWORK_RESOURCE_GROUP
  Destination network:     $DESTINATION_VNET/$DESTINATION_SUBNET
  Destination private IP:  $DESTINATION_PRIVATE_IP
  Destination VM size:     ${SELECTED_SIZE:-not selected}
  New public IP requested: $([ "$PUBLIC_IP_REQUIRED" = "1" ] && echo yes || echo no)
  Copy licenseType:        $([ "$KEEP_LICENSE_TYPE" = "1" ] && echo yes || echo no)
  Domain controller:       $([ "$DC_MODE" = "1" ] && echo yes || echo no)
  Managed disks:           $disk_count
  Total provisioned:       $(awk -v b="$total_bytes" 'BEGIN {printf "%.1f", b / 1073741824}') GiB
  Boot diagnostics:        managed (source storage account URIs are never reused)
EOF
}

run_preflight() {
  reset_blockers
  check_provider_registration
  check_destination_scopes
  validate_destination_private_ip
  load_destination_catalog
  check_destination_disk_support
  check_destination_name_conflicts
  report_effective_permissions
  fail_on_blockers "destination preflight"

  load_source_catalog
  SIZE_REQUIREMENTS_FILE="$(prepare_size_requirements)"
  select_target_size "$SIZE_REQUIREMENTS_FILE"

  print_preflight_summary
  print_policy_caveat
  ask_yes_no "Is every resolved value above correct" ||
    die "The resolved plan was not confirmed"
}

# ---------------------------------------------------------------------------
# Copy phases
# ---------------------------------------------------------------------------

disk_state_file() {
  printf '%s/disk-%s-state.json' "$STATE_DIR" "$1"
}

snapshot_all_disks() {
  local run_id disk_count index disk_id disk_name snapshot snapshot_id body state_file existing

  run_id="$(state_run_id)"
  disk_count="$(jq 'length' "$TMP_DIR/disks.json")"
  log "Creating $disk_count source snapshots for $SOURCE_VM_NAME"

  index=0
  while [ "$index" -lt "$disk_count" ]; do
    require_source_deallocated
    disk_id="$(jq -r ".[$index].resource.id" "$TMP_DIR/disks.json")"
    disk_name="$(jq -r ".[$index].resource.name" "$TMP_DIR/disks.json")"
    snapshot="$(snapshot_name_for "$SOURCE_VM_NAME" "$index" "$run_id")"
    snapshot_id="$(source_snapshot_id_for "$snapshot")"
    state_file="$(disk_state_file "$index")"

    if resource_exists "$snapshot_id" "$DISK_API"; then
      log "Reusing existing snapshot: $snapshot"
    else
      body="$TMP_DIR/snapshot-body-$index.json"
      build_snapshot_body "$SOURCE_LOCATION" "$disk_id" > "$body"
      log "Creating snapshot $snapshot for disk $disk_name"
      put_resource "$snapshot_id" "$DISK_API" "$body"
    fi

    existing='{}'
    [ -f "$state_file" ] && existing="$(cat "$state_file")"
    printf '%s' "$existing" | jq \
      --argjson index "$index" \
      --arg diskName "$disk_name" \
      --arg snapshotId "$snapshot_id" \
      --arg destinationDiskId "$(destination_disk_id_for "$disk_name")" \
      '. + {index:$index, diskName:$diskName, snapshotId:$snapshotId, destinationDiskId:$destinationDiskId}
       | if (.status // "") == "Copied" then . else .status = "Snapshotted" end' \
      > "$TMP_DIR/disk-state-$index.json"
    write_state_file "$state_file" "$TMP_DIR/disk-state-$index.json"
    index=$((index + 1))
  done
}

copy_one_disk() (
  set -Eeuo pipefail
  INTERACTIVE_AUTH_ALLOWED=0

  local index="$1"
  local disk_json state_file snapshot_id destination_disk_id
  local disk_name disk_size_bytes upload_size_bytes role
  local security_profile security_type secure=false create_option
  local body source_access="" destination_access=""
  local source_sas="" destination_sas="" source_security_sas="" destination_security_sas=""
  local azcopy_log vmgs_log source_granted=0 destination_granted=0
  local destination_exists=false tracked_status disk_state

  disk_json="$TMP_DIR/worker-$index-$RANDOM.json"
  jq ".[$index]" "$TMP_DIR/disks.json" > "$disk_json"
  state_file="$(disk_state_file "$index")"
  snapshot_id="$(jq -r '.snapshotId' "$state_file")"
  destination_disk_id="$(jq -r '.destinationDiskId' "$state_file")"
  disk_name="$(jq -r '.resource.name' "$disk_json")"
  disk_size_bytes="$(jq -r '.resource.properties.diskSizeBytes' "$disk_json")"
  upload_size_bytes=$((disk_size_bytes + 512))
  role="$(jq -r '.role' "$disk_json")"
  security_profile="$(jq -c '.resource.properties.securityProfile // null' "$disk_json")"
  security_type="$(printf '%s' "$security_profile" | jq -r '.securityType // empty')"

  case "$security_type" in
    TrustedLaunch)
      [ "$role" = "OS" ] || die "[$disk_name] A secure disk profile was found on a non-OS disk"
      secure=true
      create_option="UploadPreparedSecure"
      ;;
    ''|Standard) create_option="Upload" ;;
    *) die "[$disk_name] Unsupported disk security type: $security_type" ;;
  esac

  cleanup_disk_access() {
    if [ "$destination_granted" -eq 1 ]; then
      revoke_access "$destination_disk_id" || true
    fi
    if [ "$source_granted" -eq 1 ]; then
      revoke_access "$snapshot_id" || true
    fi
    close_data_access_best_effort "$destination_disk_id" >/dev/null 2>&1 || true
    close_data_access_best_effort "$snapshot_id" >/dev/null 2>&1 || true
    return 0
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
          log "[$disk_name] Destination disk already completed; skipping"
          exit 0
        fi
        warn "[$disk_name] Unverified destination disk will be recreated"
        delete_resource "$destination_disk_id" "$DISK_API" ||
          die "[$disk_name] Could not remove the unverified destination disk"
        wait_for_resource_absent "$destination_disk_id" "$DISK_API" ||
          die "[$disk_name] Timed out deleting the unverified destination disk"
        destination_exists=false
        ;;
      Attached)
        [ "$tracked_status" = "Copied" ] ||
          die "[$disk_name] Destination disk is attached but has no verified-copy marker"
        log "[$disk_name] Destination disk already attached and verified"
        exit 0
        ;;
      ActiveUpload|ReadyToUpload) log "[$disk_name] Resuming an in-progress upload" ;;
      *) die "[$disk_name] Destination disk is in an unsupported state: ${disk_state:-unknown}" ;;
    esac
  fi

  if [ "$destination_exists" = false ]; then
    body="$TMP_DIR/upload-disk-body-$index-$RANDOM.json"
    build_upload_disk_body "$disk_json" "$LOCATION" "$create_option" > "$body"

    log "[$disk_name] Creating destination upload disk ($upload_size_bytes bytes, $create_option)"
    put_resource "$destination_disk_id" "$DISK_API" "$body"
  fi

  log "[$disk_name] Opening temporary data access"
  set_data_access "$snapshot_id" open
  set_data_access "$destination_disk_id" open

  source_access="$(grant_access_json "$snapshot_id" Read "$secure")" ||
    die "[$disk_name] Could not grant read access to the snapshot"
  source_granted=1
  destination_access="$(grant_access_json "$destination_disk_id" Write "$secure")" ||
    die "[$disk_name] Could not grant write access to the destination disk"
  destination_granted=1

  source_sas="$(printf '%s' "$source_access" | jq -r '.accessSAS // empty')"
  destination_sas="$(printf '%s' "$destination_access" | jq -r '.accessSAS // empty')"
  [ -n "$source_sas" ] && [ -n "$destination_sas" ] ||
    die "[$disk_name] Azure did not return the expected SAS pair"

  if [ "$secure" = true ]; then
    source_security_sas="$(printf '%s' "$source_access" | jq -r '.securityDataAccessSAS // empty')"
    destination_security_sas="$(printf '%s' "$destination_access" | jq -r '.securityDataAccessSAS // empty')"
    [ -n "$source_security_sas" ] && [ -n "$destination_security_sas" ] ||
      die "[$disk_name] Trusted Launch VMGS SAS pair was not returned"
  fi

  azcopy_log="$TMP_DIR/azcopy-$index-$RANDOM.log"
  log "[$disk_name] Copying the VHD stream"
  if ! azcopy copy "$source_sas" "$destination_sas" \
      --blob-type PageBlob --check-length=true --output-type text >"$azcopy_log" 2>&1; then
    redact_secrets < "$azcopy_log" >&2
    die "[$disk_name] AzCopy failed"
  fi
  grep -E 'Final Job Status|Number of File Transfers|Total Number of Transfers' "$azcopy_log" |
    redact_secrets >&2 || true

  if [ "$secure" = true ]; then
    vmgs_log="$TMP_DIR/azcopy-vmgs-$index-$RANDOM.log"
    log "[$disk_name] Copying the Trusted Launch guest state (VMGS)"
    if ! azcopy copy "$source_security_sas" "$destination_security_sas" \
        --blob-type PageBlob --check-length=true --output-type text >"$vmgs_log" 2>&1; then
      redact_secrets < "$vmgs_log" >&2
      die "[$disk_name] AzCopy failed for the Trusted Launch guest state"
    fi
    grep -E 'Final Job Status|Number of File Transfers|Total Number of Transfers' "$vmgs_log" |
      redact_secrets >&2 || true
  fi

  revoke_access "$destination_disk_id"
  destination_granted=0
  revoke_access "$snapshot_id"
  source_granted=0
  wait_for_disk_unattached "$destination_disk_id" ||
    die "[$disk_name] Destination disk did not leave the upload state"
  set_data_access "$destination_disk_id" closed
  set_data_access "$snapshot_id" closed

  jq --arg status "Copied" --arg completedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.status = $status | .completedAt = $completedAt' "$state_file" > "$TMP_DIR/disk-done-$index.json"
  write_state_file "$state_file" "$TMP_DIR/disk-done-$index.json"
  log "[$disk_name] Copy complete"
)

copy_all_disks() {
  local disk_count index running pid failed=0
  local pids
  pids=()

  require_azcopy
  disk_count="$(jq 'length' "$TMP_DIR/disks.json")"
  [ "$disk_count" -gt 0 ] || die "No source disks were inventoried"
  require_source_deallocated

  log "Copying $disk_count disks with concurrency $COPY_CONCURRENCY"
  index=0
  while [ "$index" -lt "$disk_count" ]; do
    while true; do
      running="$(jobs -pr | wc -l | tr -d ' ')"
      [ "$running" -lt "$COPY_CONCURRENCY" ] && break
      sleep 2
    done
    refresh_token
    copy_one_disk "$index" &
    pid=$!
    pids[${#pids[@]}]="$pid"
    index=$((index + 1))
  done

  if [ "${#pids[@]}" -gt 0 ]; then
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        failed=1
      fi
    done
  fi
  [ "$failed" -eq 0 ] || die "One or more disk transfers failed"
}

# ---------------------------------------------------------------------------
# Destination network and VM creation
# ---------------------------------------------------------------------------

create_destination_nsg() {
  local nsg_id body name
  name="$(destination_nsg_name)"
  nsg_id="$(destination_nsg_id)"

  if [ "$(jq -r '.name // empty' "$TMP_DIR/source-nsg.json")" = "" ]; then
    log "The source NIC has no NSG; no destination NSG will be created"
    printf ''
    return 0
  fi

  if resource_exists "$nsg_id" "$NETWORK_API"; then
    log "Reusing the destination NSG: $name"
  else
    body="$TMP_DIR/nsg-body.json"
    build_destination_nsg_body "$TMP_DIR/source-nsg.json" "$LOCATION" > "$body"
    log "Creating the destination NSG: $name"
    put_resource "$nsg_id" "$NETWORK_API" "$body"
  fi
  printf '%s' "$nsg_id"
}

create_destination_public_ip() {
  local pip_id body
  [ "$PUBLIC_IP_REQUIRED" = "1" ] || { printf ''; return 0; }
  pip_id="$(destination_pip_id)"

  if resource_exists "$pip_id" "$NETWORK_API"; then
    log "Reusing the destination public IP: $(resource_id_field "$pip_id" name)"
  else
    confirm_phrase "CREATE NEW PUBLIC IP $SOURCE_VM_NAME"
    body="$TMP_DIR/pip-body.json"
    jq -n --arg location "$LOCATION" '{
      location:$location,
      sku:{name:"Standard"},
      properties:{
        publicIPAllocationMethod:"Static",
        publicIPAddressVersion:"IPv4",
        idleTimeoutInMinutes:4
      }
    }' > "$body"
    log "Creating a new Standard static public IPv4"
    put_resource "$pip_id" "$NETWORK_API" "$body"
  fi
  printf '%s' "$pip_id"
}

create_destination_nic() {
  local nic_id nsg_id pip_id body
  nic_id="$(destination_nic_id)"

  if resource_exists "$nic_id" "$NETWORK_API"; then
    log "Reusing the destination NIC: $(resource_id_field "$nic_id" name)"
    return 0
  fi

  nsg_id="$(create_destination_nsg)"
  pip_id="$(create_destination_public_ip)"
  body="$TMP_DIR/nic-body.json"
  build_destination_nic_body "$TMP_DIR/source-nic.json" "$LOCATION" "$DESTINATION_PRIVATE_IP" \
    "$(destination_subnet_id)" "$nsg_id" "$pip_id" > "$body"

  log "Creating the destination NIC with static private IP $DESTINATION_PRIVATE_IP"
  put_resource "$nic_id" "$NETWORK_API" "$body"
}

create_destination_vm() {
  local vm_id nic_id body keep_license disk_prefix
  vm_id="$(destination_vm_id)"
  nic_id="$(destination_nic_id)"
  disk_prefix="/subscriptions/$DESTINATION_SUBSCRIPTION/resourceGroups/$DESTINATION_RESOURCE_GROUP/providers/Microsoft.Compute/disks/"

  if resource_exists "$vm_id" "$VM_API"; then
    log "The destination VM already exists: $SOURCE_VM_NAME"
    return 0
  fi

  keep_license=false
  [ "$KEEP_LICENSE_TYPE" = "1" ] && keep_license=true

  body="$TMP_DIR/vm-body.json"
  build_destination_vm_body "$TMP_DIR/source-vm.json" "$TMP_DIR/disks.json" "$LOCATION" \
    "$nic_id" "$disk_prefix" "$SELECTED_SIZE" "$keep_license" > "$body"

  log "Creating the destination VM $SOURCE_VM_NAME with size $SELECTED_SIZE"
  put_resource "$vm_id" "$VM_API" "$body"
  wait_for_power_state "$vm_id" running ||
    die "The destination VM did not reach PowerState/running: $SOURCE_VM_NAME"
}

print_post_deployment_actions() {
  local pip_id
  cat >&2 <<EOF

The destination VM is running: $SOURCE_VM_NAME

Required manual validation:
  1. Boot diagnostics and guest OS event logs.
  2. All volumes, drive letters, mount points, LUNs and services.
  3. DNS, domain authentication and application dependencies.
  4. Application owner functional test.
  5. Backup, monitoring, endpoint protection and any IaaS agent registration.

Not copied by design (recreate deliberately in the destination tenant):
  - Managed identities and every role assignment bound to them.
  - VM extensions.
  - Source boot-diagnostics storage account (managed boot diagnostics is used).
  - The source public IP address and its resource.
EOF
  if [ "$PUBLIC_IP_REQUIRED" = "1" ]; then
    pip_id="$(destination_pip_id)"
    if resource_exists "$pip_id" "$NETWORK_API"; then
      arm_raw GET "$(resource_url "$pip_id" "$NETWORK_API")"
      printf '\nNew public IP address: %s\n' "$(jq -r '.properties.ipAddress // "Pending"' "$LAST_BODY")" >&2
      printf 'Update public DNS, firewall rules and allowlists with this new address.\n' >&2
    fi
  fi
  jq -r '.value[]? | "  - extension to reinstall: \(.name) (\(.properties.publisher // "?")/\(.properties.type // "?"))"' \
    "$TMP_DIR/source-extensions.json" >&2 || true
}

network_cutover_checkpoint() {
  cat >&2 <<EOF

Disk and network preparation is complete.

STOP HERE. The destination VM has not been created yet.

Ask the network team to execute the approved routing, VPN or ExpressRoute
cutover for $DESTINATION_VNET/$DESTINATION_SUBNET and $DESTINATION_PRIVATE_IP.

The source VM stays deallocated. Never allow the source and the destination to
run at the same time with the same address or name.
EOF
  ask_yes_no "Has the network team confirmed that routing to $DESTINATION_PRIVATE_IP is now exclusive to the destination" ||
    die "Cutover was not confirmed; the destination VM was not created"
  confirm_phrase "NETWORK CUTOVER COMPLETE $SOURCE_VM_NAME"
  require_source_deallocated
}

# ---------------------------------------------------------------------------
# Run preparation shared by every mode
# ---------------------------------------------------------------------------

load_manifest_defaults() {
  local file="$STATE_DIR/manifest.json"
  [ -f "$file" ] || return 0
  log "Existing migration state found: $file"

  [ -n "$LOCATION" ] || LOCATION="$(jq -r '.destination.location // empty' "$file")"
  [ -n "$DESTINATION_SUBSCRIPTION" ] || DESTINATION_SUBSCRIPTION="$(jq -r '.destination.subscription // empty' "$file")"
  [ -n "$MANAGING_TENANT" ] || MANAGING_TENANT="$(jq -r '.destination.managingTenant // empty' "$file")"
  [ -n "$DESTINATION_RESOURCE_GROUP" ] || DESTINATION_RESOURCE_GROUP="$(jq -r '.destination.resourceGroup // empty' "$file")"
  [ -n "$DESTINATION_NETWORK_RESOURCE_GROUP" ] || DESTINATION_NETWORK_RESOURCE_GROUP="$(jq -r '.destination.networkResourceGroup // empty' "$file")"
  [ -n "$DESTINATION_VNET" ] || DESTINATION_VNET="$(jq -r '.destination.vnet // empty' "$file")"
  [ -n "$DESTINATION_SUBNET" ] || DESTINATION_SUBNET="$(jq -r '.destination.subnet // empty' "$file")"
  [ -n "$DESTINATION_PRIVATE_IP" ] || DESTINATION_PRIVATE_IP="$(jq -r '.destination.privateIp // empty' "$file")"
  [ -n "$TARGET_SIZE" ] || TARGET_SIZE="$(jq -r '.destination.vmSize // empty' "$file")"
  [ "$(jq -r '.destination.publicIpRequested // false' "$file")" = "true" ] && PUBLIC_IP_REQUIRED=1
  [ "$(jq -r '.options.domainController // false' "$file")" = "true" ] && DC_MODE=1
  return 0
}

prepare_identity_and_inventory() {
  resolve_managing_tenant
  resolve_source_vm
  load_manifest_defaults
  resolve_field DESTINATION_SUBSCRIPTION "Destination subscription id" is_uuid
  ensure_subscription_access
  inventory_source
}

prepare_full_run() {
  prepare_identity_and_inventory
  validate_support_boundary
  ask_domain_controller_safeguards
  ask_public_ip_requirement
  resolve_destination_configuration
  run_preflight
  [ -n "$SAVE_CONFIG_FILE" ] && save_config_file "$SAVE_CONFIG_FILE"
  return 0
}

prepare_lifecycle_run() {
  prepare_identity_and_inventory
  resolve_destination_configuration
  [ -n "$TARGET_SIZE" ] && SELECTED_SIZE="$TARGET_SIZE"
  return 0
}

assert_not_rolled_back() {
  [ -f "$STATE_DIR/rolled-back-at" ] || return 0
  cat >&2 <<EOF

This migration was rolled back at $(cat "$STATE_DIR/rolled-back-at").

The source VM was allowed to change afterwards, so every existing snapshot,
destination disk and Copied marker is stale and must not be reused.
Run '--mode reset' to delete the stale destination VM, destination disks and
source snapshots before starting a new copy.
EOF
  exit 1
}

assert_destination_absent_or_deallocated() {
  local vm_id state
  vm_id="$(destination_vm_id)"
  resource_exists "$vm_id" "$VM_API" || return 0
  state="$(vm_power_state "$vm_id")"
  [ "$state" = "PowerState/deallocated" ] ||
    die "The destination VM already exists and is $state. Source and destination must never run at the same time."
  warn "The destination VM already exists and is deallocated; it will be reused only if the state matches."
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

execute_copy_pipeline() {
  local resuming="$1"
  local stored=""

  assert_not_rolled_back
  # The stored fingerprint must be read before the manifest is rewritten.
  if [ -f "$STATE_DIR/manifest.json" ]; then
    stored="$(stored_fingerprint || true)"
  fi

  if [ "$resuming" = "1" ]; then
    [ -n "$stored" ] || die "No manifest fingerprint exists for $MIGRATION_ID; a resume is not possible"
    [ "$stored" = "$(manifest_fingerprint)" ] ||
      die "The resolved configuration does not match the stored manifest fingerprint; resume refused"
    assert_destination_absent_or_deallocated
    require_source_deallocated
    log "Resuming migration $MIGRATION_ID"
  else
    if [ -n "$stored" ] && [ "$stored" != "$(manifest_fingerprint)" ]; then
      die "A different configuration is already recorded for migration $MIGRATION_ID. Use '--mode resume' with the recorded values or '--mode reset' first."
    fi
    assert_destination_absent_or_deallocated
    cat >&2 <<EOF

This operation will:
  - Deallocate the source VM $SOURCE_VM_NAME.
  - Snapshot every attached managed disk in $SOURCE_LOCATION.
  - Upload each snapshot into a managed disk in the destination tenant.
  - Recreate the NIC-level NSG and the NIC with private IP $DESTINATION_PRIVATE_IP.
  - Pause for the external network cutover.
  - Create and start the destination VM with size $SELECTED_SIZE.

The source VM and the source disks are never deleted and remain available for
rollback.
EOF
    if [ "$DC_MODE" = "1" ]; then
      confirm_phrase "AD HEALTH AND SYSTEM STATE VERIFIED $SOURCE_VM_NAME"
    fi
    ask_yes_no "Are all guest services and applications stopped cleanly" ||
      die "Stop the guest services before the copy"
    confirm_phrase "START COPY $SOURCE_VM_NAME"
    if [ "$(vm_power_state "$SOURCE_VM_ID")" != "PowerState/deallocated" ]; then
      deallocate_vm "$SOURCE_VM_ID"
    fi
  fi
  write_manifest

  require_source_deallocated
  snapshot_all_disks
  copy_all_disks
  create_destination_nic
  network_cutover_checkpoint
  create_destination_vm
  print_post_deployment_actions
  log "Copy finished for $SOURCE_VM_NAME. Run '--mode validate' before any cleanup."
}

mode_preflight() {
  prepare_full_run
  cat >&2 <<'EOF'

Preflight complete. No Azure resource was created, changed or deleted.
EOF
}

mode_copy() {
  require_azcopy
  prepare_full_run
  execute_copy_pipeline 0
}

mode_resume() {
  require_azcopy
  prepare_full_run
  execute_copy_pipeline 1
}

mode_status() {
  local index count state_file destination_state destination_id

  prepare_lifecycle_run
  destination_id="$(destination_vm_id)"
  if resource_exists "$destination_id" "$VM_API"; then
    destination_state="$(vm_power_state "$destination_id")"
  else
    destination_state="NotCreated"
  fi

  cat >&2 <<EOF

Migration status
  Migration id:        $MIGRATION_ID
  State directory:     $STATE_DIR
  Source VM:           $SOURCE_VM_NAME ($(vm_power_state "$SOURCE_VM_ID"))
  Destination VM:      $destination_state
  Manifest:            $([ -f "$STATE_DIR/manifest.json" ] && echo present || echo absent)
  Validation accepted: $([ -f "$STATE_DIR/accepted-at" ] && cat "$STATE_DIR/accepted-at" || echo no)
  Rolled back:         $([ -f "$STATE_DIR/rolled-back-at" ] && cat "$STATE_DIR/rolled-back-at" || echo no)

Disks:
EOF
  count="$(jq 'length' "$TMP_DIR/disks.json")"
  index=0
  while [ "$index" -lt "$count" ]; do
    state_file="$(disk_state_file "$index")"
    printf '  %-40s %s\n' \
      "$(jq -r ".[$index].resource.name" "$TMP_DIR/disks.json")" \
      "$([ -f "$state_file" ] && jq -r '.status // "Unknown"' "$state_file" || echo NotStarted)" >&2
    index=$((index + 1))
  done
}

mode_validate() {
  local vm_id nic_id expected actual ip power accepted=1

  prepare_lifecycle_run
  vm_id="$(destination_vm_id)"
  nic_id="$(destination_nic_id)"
  resource_exists "$vm_id" "$VM_API" || die "The destination VM does not exist: $SOURCE_VM_NAME"

  power="$(vm_power_state "$vm_id")"
  expected="$(jq 'length' "$TMP_DIR/disks.json")"
  arm_raw GET "$(resource_url "$vm_id" "$VM_API")"
  actual="$(jq '1 + ([.properties.storageProfile.dataDisks[]?] | length)' "$LAST_BODY")"
  arm_raw GET "$(resource_url "$nic_id" "$NETWORK_API")"
  ip="$(jq -r '[.properties.ipConfigurations[]?.properties.privateIPAddress][0] // "unknown"' "$LAST_BODY")"

  cat >&2 <<EOF

Automated validation for $SOURCE_VM_NAME:
  Power state:    $power
  Attached disks: $actual / $expected
  Private IP:     $ip / $DESTINATION_PRIVATE_IP
EOF

  [ "$power" = "PowerState/running" ] || accepted=0
  [ "$actual" -eq "$expected" ] || accepted=0
  [ "$ip" = "$DESTINATION_PRIVATE_IP" ] || accepted=0

  ask_yes_no "Did the guest OS boot without critical errors" || accepted=0
  ask_yes_no "Are all volumes, mount points and drive letters correct" || accepted=0
  ask_yes_no "Are DNS, directory and required network paths working" || accepted=0
  ask_yes_no "Did the application owner approve the functional test" || accepted=0
  ask_yes_no "Are backup, monitoring and security actions complete" || accepted=0

  if [ "$accepted" -eq 1 ]; then
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$TMP_DIR/accepted-at"
    write_state_file "$STATE_DIR/accepted-at" "$TMP_DIR/accepted-at"
    log "Validation accepted for $SOURCE_VM_NAME"
  else
    warn "Validation is incomplete or failed. Do not clean up any source resource."
    return 1
  fi
}

mode_rollback() {
  local destination_id
  prepare_lifecycle_run
  destination_id="$(destination_vm_id)"

  cat >&2 <<EOF

Rollback deallocates the destination VM $SOURCE_VM_NAME and then starts the
source VM again, but only after the network team confirms that routing was
restored to the source. Destination disks and source snapshots are retained for
analysis and are marked stale.
EOF
  if [ "$DC_MODE" = "1" ]; then
    cat >&2 <<'EOF'

DOMAIN CONTROLLER WARNING:
Rollback can discard directory changes accepted by the destination DC and can
cause USN rollback or replication divergence. Confirm which DC owns the
authoritative post-cutover changes and obtain Active Directory owner approval.
EOF
    confirm_phrase "AD ROLLBACK APPROVED $SOURCE_VM_NAME"
  fi
  confirm_phrase "ROLLBACK $SOURCE_VM_NAME"

  if resource_exists "$destination_id" "$VM_API"; then
    if [ "$(vm_power_state "$destination_id")" != "PowerState/deallocated" ]; then
      deallocate_vm "$destination_id"
    fi
  else
    warn "No destination VM exists; only the source will be restored."
  fi

  printf '\nAsk the network team to restore routing to the source now.\n' >&2
  ask_yes_no "Has routing been restored to the source and is the destination path withdrawn" ||
    die "Rollback stopped: the source must not start while the destination path is live"
  confirm_phrase "SOURCE NETWORK RESTORED $SOURCE_VM_NAME"

  start_vm "$SOURCE_VM_ID"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$TMP_DIR/rolled-back-at"
  write_state_file "$STATE_DIR/rolled-back-at" "$TMP_DIR/rolled-back-at"
  rm -f "$STATE_DIR/accepted-at"
  log "Rollback complete. The source VM is running and all copied state is stale."
  warn "Run '--mode reset' before attempting another copy."
}

mode_reset() {
  local state_file destination_disk_id snapshot_id destination_id

  prepare_lifecycle_run
  [ -f "$STATE_DIR/rolled-back-at" ] ||
    warn "This migration is not marked as rolled back. Reset still deletes stale destination resources."

  cat >&2 <<EOF

Reset permanently deletes the destination VM, the destination disks and the
source migration snapshots that belong to migration $MIGRATION_ID. Source VMs
and source disks are never touched.
EOF
  confirm_phrase "RESET STALE MIGRATION $SOURCE_VM_NAME"

  destination_id="$(destination_vm_id)"
  if resource_exists "$destination_id" "$VM_API"; then
    if [ "$(vm_power_state "$destination_id")" != "PowerState/deallocated" ]; then
      deallocate_vm "$destination_id"
    fi
    log "Deleting the stale destination VM"
    delete_resource "$destination_id" "$VM_API" || die "Could not delete the stale destination VM"
    wait_for_resource_absent "$destination_id" "$VM_API" ||
      die "Timed out waiting for the stale destination VM to be deleted"
  fi

  for state_file in "$STATE_DIR"/disk-*-state.json; do
    [ -f "$state_file" ] || continue
    destination_disk_id="$(jq -r '.destinationDiskId // empty' "$state_file")"
    snapshot_id="$(jq -r '.snapshotId // empty' "$state_file")"

    if [ -n "$destination_disk_id" ] && resource_exists "$destination_disk_id" "$DISK_API"; then
      revoke_access "$destination_disk_id" || true
      close_data_access_best_effort "$destination_disk_id" >/dev/null 2>&1 || true
      log "Deleting stale destination disk $(resource_id_field "$destination_disk_id" name)"
      delete_resource "$destination_disk_id" "$DISK_API" ||
        die "Could not delete the stale destination disk"
    fi
    if [ -n "$snapshot_id" ] && resource_exists "$snapshot_id" "$DISK_API"; then
      revoke_access "$snapshot_id" || true
      close_data_access_best_effort "$snapshot_id" >/dev/null 2>&1 || true
      log "Deleting stale source snapshot $(resource_id_field "$snapshot_id" name)"
      delete_resource "$snapshot_id" "$DISK_API" || die "Could not delete the stale source snapshot"
    fi
    rm -f "$state_file"
  done

  rm -f "$STATE_DIR/run-id" "$STATE_DIR/accepted-at" "$STATE_DIR/rolled-back-at"
  log "Stale migration state was reset for $SOURCE_VM_NAME"
}

mode_cleanup_snapshots() {
  local state_file snapshot_id

  prepare_lifecycle_run
  [ -f "$STATE_DIR/accepted-at" ] ||
    die "No accepted validation marker exists. Run '--mode validate' first."

  cat >&2 <<EOF

This cleanup deletes only the temporary migration snapshots in the source
subscription. Source VMs, source disks, destination VMs and destination disks
are never deleted.
EOF
  confirm_phrase "DELETE MIGRATION SNAPSHOTS $SOURCE_VM_NAME"

  for state_file in "$STATE_DIR"/disk-*-state.json; do
    [ -f "$state_file" ] || continue
    [ "$(jq -r '.status // empty' "$state_file")" = "Copied" ] ||
      die "A disk has no verified copy marker; snapshots are kept"
    snapshot_id="$(jq -r '.snapshotId // empty' "$state_file")"
    [ -n "$snapshot_id" ] || continue
    if resource_exists "$snapshot_id" "$DISK_API"; then
      revoke_access "$snapshot_id" || true
      log "Deleting snapshot $(resource_id_field "$snapshot_id" name)"
      delete_resource "$snapshot_id" "$DISK_API" || die "Could not delete the snapshot"
    fi
  done
  log "Temporary migration snapshots were removed"
}

mode_policy_test() (
  set -Eeuo pipefail
  local disk_name disk_id body access disk_created=0

  prepare_identity_and_inventory
  resolve_destination_configuration

  disk_name="copy-policy-test-$(date -u '+%Y%m%d%H%M%S')"
  disk_id="$(destination_resource_id "Microsoft.Compute/disks" "$disk_name")"
  body="$TMP_DIR/policy-test-disk.json"

  cleanup_policy_test() {
    if [ "$disk_created" -eq 1 ]; then
      revoke_access "$disk_id" >/dev/null 2>&1 || true
      close_data_access_best_effort "$disk_id" >/dev/null 2>&1 || true
      delete_resource "$disk_id" "$DISK_API" >/dev/null 2>&1 || true
    fi
    return 0
  }
  trap cleanup_policy_test EXIT

  cat >&2 <<EOF

This explicit write test creates a temporary 1 GiB upload disk in destination
resource group $DESTINATION_RESOURCE_GROUP, grants and revokes a write SAS,
disables public access and deletes the disk. It proves destination RBAC and
Azure Policy behaviour without copying any data.
EOF
  confirm_phrase "CREATE POLICY TEST DISK $DESTINATION_RESOURCE_GROUP"

  jq -n --arg location "$LOCATION" --argjson uploadSizeBytes 1073742336 '{
    location:$location,
    sku:{name:"Standard_LRS"},
    properties:{
      creationData:{createOption:"Upload",uploadSizeBytes:$uploadSizeBytes},
      networkAccessPolicy:"AllowAll",
      publicNetworkAccess:"Enabled"
    }
  }' > "$body"

  log "Creating the temporary policy-test disk $disk_name"
  put_resource "$disk_id" "$DISK_API" "$body"
  disk_created=1
  access="$(grant_access_json "$disk_id" Write false)" ||
    die "The destination policy test could not grant a write SAS"
  [ -n "$(printf '%s' "$access" | jq -r '.accessSAS // empty')" ] ||
    die "The destination policy test did not return a write SAS"
  access=""
  revoke_access "$disk_id"
  set_data_access "$disk_id" closed
  delete_resource "$disk_id" "$DISK_API" || die "Could not delete the temporary policy-test disk"
  disk_created=0
  log "Destination disk write-policy test passed for $DESTINATION_RESOURCE_GROUP"
)

# ---------------------------------------------------------------------------
# Help and entry point
# ---------------------------------------------------------------------------

show_help() {
  cat <<EOF
$TOOL_NAME $VERSION

Generic, conservative cross-tenant Azure VM copy. Hybrid CLI and prompt: every
value can be supplied on the command line or in a config file, and every
mutation still requires an explicit typed confirmation in a terminal.

Usage:
  $(basename "$0") [options]

Modes (--mode):
  preflight          Read-only assessment, size selection and price estimate.
  copy               Full interactive copy (default).
  resume             Continue an interrupted copy with a matching manifest.
  status             Read-only progress report.
  validate           Post-cutover validation checklist and acceptance marker.
  rollback           Deallocate destination, restore source after network restore.
  reset              Delete stale destination VM/disks and source snapshots.
  cleanup-snapshots  Delete accepted migration snapshots only.
  policy-test        Explicit destination RBAC/Azure Policy write test.

Options:
  --preflight-only                     Force read-only mode; blocks every non-GET call.
  --source-vm-id ID                    Authoritative source VM resource id.
  --source-subscription GUID           Source subscription id.
  --source-resource-group NAME         Source resource group.
  --vm-name NAME                       Source VM name.
  --destination-subscription GUID      Destination subscription id.
  --managing-tenant GUID               Tenant used by az login for both subscriptions.
  --location NAME                      Destination ARM region name.
  --destination-resource-group NAME    Destination resource group for VM/disks/NIC.
  --network-resource-group NAME        Resource group that holds the destination VNet.
  --vnet NAME                          Destination virtual network name.
  --subnet NAME                        Destination subnet name.
  --private-ip IPV4                    Destination static private IPv4 address.
  --target-size SIZE                   Proposed destination size; still requires approval.
  --currency CODE                      Retail price currency (default USD).
  --config FILE                        Load non-secret defaults from a JSON file.
  --save-config FILE                   Persist the sanitized resolved configuration.
  --keep-license-type                  Copy a non-empty source licenseType (needs approval).
  --state-dir DIR                      State root (default: $STATE_ROOT).
  --copy-concurrency N                 Parallel disk copies (default: 4).
  --sas-duration SECONDS               Temporary SAS lifetime (default: 43200).
  --resume | --status | --validate | --rollback | --reset
                                       Convenience aliases for lifecycle modes.
  --cleanup-snapshots                  Delete accepted migration snapshots only.
  --destination-policy-test            Run the explicit temporary disk write test.
  --version                            Print the version and exit.
  -h, --help                           Print this help and exit.

Support boundary (fails closed):
  Exactly one NIC and one primary IPv4 configuration, managed non-ephemeral
  disks, no Confidential VM, no Azure Disk Encryption, no customer-managed keys
  or disk encryption sets, no shared disks, no Ultra or Premium SSD v2 disks, no
  ASG references, no load balancer or gateway membership, no marketplace plan,
  no availability set, scale set, host, host group, capacity reservation or
  proximity placement group, and no subnet-level NSG topology.

Never copied: managed identities, extensions, the source public IP address, and
the source boot-diagnostics storage account. Managed boot diagnostics is used.

Examples:
  $(basename "$0") --preflight-only \\
    --source-vm-id /subscriptions/<guid>/resourceGroups/APP-RG/providers/Microsoft.Compute/virtualMachines/APP-VM

  $(basename "$0") --preflight-only \\
    --source-subscription <guid> --source-resource-group APP-RG --vm-name APP-VM

  $(basename "$0") --source-vm-id <id> --destination-subscription <guid>

  $(basename "$0") --source-vm-id <id> --destination-subscription <guid> \\
    --managing-tenant <guid> --location eastus2 \\
    --destination-resource-group APP-RG --network-resource-group NET-RG \\
    --vnet app-vnet --subnet app-subnet --private-ip 10.20.30.40
EOF
}

print_banner() {
  cat >&2 <<EOF

$TOOL_NAME $VERSION
  Mode:                 $MODE
  ARM writes:           $([ "$MUTATIONS_ENABLED" = "1" ] && echo enabled || echo "blocked (read-only)")
  State root:           $STATE_ROOT
  Disk-copy concurrency: $COPY_CONCURRENCY
  SAS lifetime:         ${SAS_DURATION_SECONDS}s
  Price currency:       $CURRENCY
EOF
}

main() {
  parse_arguments "$@"
  init_runtime
  if [ -n "$CONFIG_FILE" ]; then
    load_config_file "$CONFIG_FILE"
  fi
  require_interactive_terminal
  print_banner

  case "$MODE" in
    preflight) mode_preflight ;;
    copy) mode_copy ;;
    resume) mode_resume ;;
    status) mode_status ;;
    validate) mode_validate ;;
    rollback) mode_rollback ;;
    reset) mode_reset ;;
    cleanup-snapshots) mode_cleanup_snapshots ;;
    policy-test) mode_policy_test ;;
    *) die "Unknown mode: $MODE" ;;
  esac
}

# Sourcing the script with AZ_VM_COPY_LIB=1 exposes the pure helpers to the
# fixture tests without executing any mode.
if [ "${AZ_VM_COPY_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"
