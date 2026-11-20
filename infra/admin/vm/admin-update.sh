#!/bin/bash
# Runs on the admin-update VM through Azure Run Command, as root (docs/runbooks/ADMIN-UPDATE-FROM-VM.md,
# ADR 0037). infra/admin/Update-AdminFromVm.ps1 replaces the values line below; values are checked
# there against fixed patterns before they are written in single quotes.
#   setup   install git, curl, Azure CLI, Node.js 22 and PowerShell 7 when missing, then check
#   check   read-only: tools, managed identity sign-in, admin app read, private DNS, outbound HTTPS
#   update  check, then build admin or verify a retained role-specific worker artifact and OneDeploy
# The last stdout line is one JSON run line ({"schema":"ccof.admin.vmupdate.v1",...}): Run Command
# returns only the last 4,096 bytes and exits 0 whatever the script returns.
set -uo pipefail
umask 077
# @@VALUES@@
: "${PHASE:?values missing: run this script through infra/admin/Update-AdminFromVm.ps1}"
WORK="${CCOF_ADMIN_WORK:-/var/lib/ccof-admin-update}"
POLL="${CCOF_POLL_SECONDS:-15}"
mkdir -p "$WORK" || exit 1
LOG="$WORK/$PHASE-$(date -u +%Y%m%dT%H%M%SZ).log"
export AZURE_CONFIG_DIR="$WORK/.azure"
export DEBIAN_FRONTEND=noninteractive
SHA=''
NOTES=''
GUARD_BEFORE=''
BACKUP=''
GUARD_VERIFIED=false
HOST_HTTP_STATUS=''
TARGET_RESOURCE_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP"

clean() { printf '%s' "$1" | tr -d '"\\' | tr '\r\n\t' '   ' | cut -c1-400; }
emit() {
  printf '{"schema":"ccof.admin.vmupdate.v1","phase":"%s","outcome":"%s","step":"%s","detail":"%s","app":"%s","commit":"%s","sha256":"%s","guardReadback":%s,"previousSha256":"%s","packageKind":"%s","resourceId":"%s","hostHttpStatus":"%s","businessVerified":false,"notes":"%s","log":"%s"}\n' \
    "$PHASE" "$1" "$2" "$(clean "$3")" "$APP" "$COMMIT" "$SHA" "$GUARD_VERIFIED" "$PREVIOUS_SHA256" "$PACKAGE_KIND" "$TARGET_RESOURCE_ID" "$HOST_HTTP_STATUS" "$(clean "$NOTES")" "$LOG"
}
fail() {
  echo "--- last lines of $LOG" >&2
  tail -n 12 "$LOG" 2>/dev/null | cut -c1-160 >&2
  emit failed "$1" "$2"
  exit 1
}
note() { NOTES="$NOTES$1; "; echo "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
node_major() { node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/'; }
# RFC 1918 plus RFC 6598 shared space (100.64.0.0/10), which some private VNets use.
is_private() { [[ "$1" =~ ^10\. || "$1" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. || "$1" =~ ^192\.168\. || "$1" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; }

do_setup() {
  local missing=''
  { have git && have curl; } || missing="$missing base"
  have az || missing="$missing az"
  { have node && [ "$(node_major)" -ge 22 ]; } || missing="$missing node22"
  have pwsh || missing="$missing pwsh"
  if [ -z "$missing" ]; then note "tools present"; return 0; fi
  note "installing:$missing"
  apt-get update -y >>"$LOG" 2>&1 || fail setup "apt-get update failed (outbound HTTPS to the Ubuntu archive)"
  apt-get install -y ca-certificates curl git gnupg wget >>"$LOG" 2>&1 || fail setup "apt-get install of base packages failed"
  if [[ "$missing" == *az* ]]; then
    { curl -sL https://aka.ms/InstallAzureCLIDeb | bash; } >>"$LOG" 2>&1 || fail setup "Azure CLI install failed"
  fi
  if [[ "$missing" == *node22* ]]; then
    { curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs; } >>"$LOG" 2>&1 || fail setup "Node.js 22 install failed"
  fi
  if [[ "$missing" == *pwsh* ]]; then
    local ver
    ver=$(. "${CCOF_OS_RELEASE:-/etc/os-release}" && echo "$VERSION_ID") || fail setup "cannot read /etc/os-release"
    { wget -q "https://packages.microsoft.com/config/ubuntu/$ver/packages-microsoft-prod.deb" -O "$WORK/packages-microsoft-prod.deb" \
      && dpkg -i "$WORK/packages-microsoft-prod.deb" && apt-get update -y && apt-get install -y powershell; } >>"$LOG" 2>&1 || fail setup "PowerShell 7 install failed"
  fi
}

do_check() {
  local t
  if [ "$PACKAGE_KIND" != admin ]; then
    local approved=false id
    local -a approved_ids
    IFS=',' read -r -a approved_ids <<<"$APPROVED_WORKER_RESOURCE_IDS"
    for id in "${approved_ids[@]}"; do [ "${id,,}" != "${TARGET_RESOURCE_ID,,}" ] || approved=true; done
    [ "$approved" = true ] || fail check "worker target resource ID is not in the approved allowlist"
    have curl || fail check "curl is required for private host-only worker readiness"
  fi
  if [ "$PHASE" != rollback ] && [ "$PACKAGE_KIND" = admin ]; then
    for t in git curl az node pwsh; do have "$t" || fail check "$t is not installed; run -Phase Setup -Apply first"; done
    [ "$(node_major)" -ge 22 ] || fail check "Node.js $(node -v) is older than 22; run -Phase Setup -Apply"
    note "node $(node -v), pwsh $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r')"
  else
    have az || fail check "Azure CLI is required for private artifact deployment or rollback"
  fi
  az login --identity --allow-no-subscriptions >>"$LOG" 2>&1 || fail check "managed identity sign-in failed: the VM needs a system-assigned identity"
  az account set --subscription "$SUB" >>"$LOG" 2>&1 || fail check "subscription $SUB is not visible to the VM identity: assign Website Contributor on the target app"
  local access
  access=$(az functionapp show --subscription "$SUB" --resource-group "$RG" --name "$APP" --output tsv --query 'publicNetworkAccess || properties.publicNetworkAccess' 2>>"$LOG") \
    || fail check "cannot read $APP: the VM identity needs Website Contributor on the target app"
  note "$APP publicNetworkAccess=${access:-unset}"
  local ip
  ip=$(getent hosts "$APP.scm.azurewebsites.net" | awk '{print $1; exit}')
  [ -n "$ip" ] || fail check "$APP.scm.azurewebsites.net does not resolve"
  is_private "$ip" || fail check "$APP.scm.azurewebsites.net resolves to $ip, not a private address: the target app private endpoint or its privatelink.azurewebsites.net record is missing for this VNet"
  note "$APP.scm.azurewebsites.net -> $ip"
  if [ "$PACKAGE_KIND" != admin ]; then
    ip=$(getent hosts "$APP.azurewebsites.net" | awk '{print $1; exit}')
    is_private "$ip" || fail check "worker app hostname does not resolve privately; no public readiness fallback"
    local role
    role=$(az functionapp config appsettings list --subscription "$SUB" --resource-group "$RG" --name "$APP" --query "[?name=='CCOF_APP_ROLE'].value | [0]" --output tsv 2>/dev/null) \
      || fail check "cannot verify the fixed worker role"
    [ "$role" = "$PACKAGE_KIND" ] || fail check "worker target role mismatch; no deployment attempted"
  fi
  { [ "$PHASE" != rollback ] && [ "$PACKAGE_KIND" = admin ]; } || return 0
  local url code
  for url in "${REPO_URL%.git}" https://registry.npmjs.org/; do
    code=$(curl -s -o /dev/null --max-time 20 -w '%{http_code}' "$url" 2>>"$LOG")
    [[ "$code" =~ ^[23] ]] || fail check "outbound HTTPS to $url returned '${code:-no answer}': the VM needs outbound HTTPS to the repository and the npm registry"
  done
  note "outbound HTTPS ok"
}

guard_snapshot() {
  local settings auth access
  # Never persist app-setting values or authentication documents in logs/evidence.
  settings=$(az functionapp config appsettings list --subscription "$SUB" --resource-group "$RG" --name "$APP" --query 'sort_by(@, &name)' --output json 2>/dev/null) || return 1
  auth=$(az rest --method get --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/config/authsettingsV2/list?api-version=2024-04-01" --output json 2>/dev/null) || return 1
  access=$(az functionapp show --subscription "$SUB" --resource-group "$RG" --name "$APP" --query '{publicNetworkAccess:publicNetworkAccess,httpsOnly:httpsOnly,virtualNetworkSubnetId:virtualNetworkSubnetId}' --output json 2>/dev/null) || return 1
  [ -n "$settings" ] && [ -n "$auth" ] && [ -n "$access" ] || return 1
  printf '%s\n%s\n%s\n' "$settings" "$auth" "$access" | sha256sum | cut -c1-64
}

prepare_backup() {
  local previous="$WORK/$PACKAGE_KIND-$PREVIOUS_COMMIT.zip" actual label="$PREVIOUS_COMMIT"
  if [ "${PREVIOUS_SOURCE:-commit}" = recovered ]; then
    previous="$WORK/recovered/$APP/$PREVIOUS_SHA256.zip"
    label="recovered active package (source commit unknown)"
  fi
  [ -s "$previous" ] || fail backup "approved retained artifact missing: $previous; recover the exact previously deployed package before upgrading"
  actual=$(sha256sum "$previous" | cut -c1-64)
  [ "$actual" = "$PREVIOUS_SHA256" ] || fail backup "previous artifact hash mismatch; no deployment attempted"
  mkdir -p "$WORK/backups/$APP" || fail backup "cannot create app backup directory"
  BACKUP="$WORK/backups/$APP/$PREVIOUS_SHA256.zip"
  cp "$previous" "$BACKUP" && chmod 600 "$BACKUP" || fail backup "cannot retain approved rollback package"
  GUARD_BEFORE=$(guard_snapshot) || fail backup "cannot read settings/auth/access guards; config/list/action is sensitive and required for safe upgrade"
  note "backup $label sha256=$PREVIOUS_SHA256; guard=$GUARD_BEFORE"
}

verify_functions() {
  local i f listed missing=' not read'
  for i in $(seq 1 20); do
    listed=$(az functionapp function list --subscription "$SUB" --resource-group "$RG" --name "$APP" --output tsv --query '[].name' 2>>"$LOG")
    missing=''
    for f in $REQUIRED_FUNCTIONS; do grep -q "/$f\$" <<<"$listed" || missing="$missing $f"; done
    [ -z "$missing" ] && return 0
    sleep "$POLL"
  done
  return 1
}

verify_host() {
  [ "$PACKAGE_KIND" != admin ] || return 0
  local i
  for i in $(seq 1 20); do
    HOST_HTTP_STATUS=$(curl --noproxy '*' -s -o /dev/null --max-time 20 -w '%{http_code}' "https://$APP.azurewebsites.net/" 2>/dev/null)
    if [[ "$HOST_HTTP_STATUS" =~ ^(200|401)$ ]]; then
      note "worker host HTTP $HOST_HTTP_STATUS; host-only readiness, no business verification"
      return 0
    fi
    sleep "$POLL"
  done
  return 1
}

verify_guard() {
  local after
  GUARD_VERIFIED=false
  after=$(guard_snapshot) || return 1
  [ "$after" = "$GUARD_BEFORE" ] || return 1
  GUARD_VERIFIED=true
  note "guard readback verified $after"
}

# OneDeploy. On Flex with a managed-identity AzureWebJobsStorage, the CLI's single post-deploy health
# probe can run before the host has its token and report the app unhealthy after a successful
# deployment, or fail to read the host key it probes with (azure-cli check_flex_app_after_deployment;
# azure-functions-host #11782, #11636). Both are raised only after the deployment succeeded. For workers
# only, those exact messages defer to the
# polled readback (verify_functions, verify_host, verify_guard), which still rolls back on failure.
one_deploy() {
  local out="$WORK/onedeploy-$$.out" rc=0
  az functionapp deployment source config-zip --subscription "$SUB" --resource-group "$RG" --name "$APP" --src "$1" >"$out" 2>&1 || rc=$?
  cat "$out" >>"$LOG"
  if [ "$rc" -ne 0 ] && [ "$PACKAGE_KIND" != admin ] \
    && grep -qF -e 'Deployment was successful but the app appears to be unhealthy' \
      -e 'Failed to fetch host key to check for function app status' "$out"; then
    note "CLI health probe failed at start-up after a successful deployment; deciding by polled readback"
    rc=0
  fi
  rm -f "$out"
  return "$rc"
}

restore_backup() {
  [ "$(sha256sum "$BACKUP" | cut -c1-64)" = "$PREVIOUS_SHA256" ] || return 1
  one_deploy "$BACKUP" || return 1
  verify_functions && verify_host && verify_guard
}

upgrade_failed() {
  local step="$1" detail="$2"
  if [ "$SAFE_UPGRADE" = true ]; then
    if restore_backup; then
      fail "$step" "$detail; rollback to approved package verified"
    else
      fail "$step" "$detail; rollback attempted but readback failed; operator recovery required"
    fi
  fi
  fail "$step" "$detail"
}

do_rollback() {
  do_check
  prepare_backup
  restore_backup || fail rollback "approved package rollback or readback failed; operator recovery required"
  COMMIT="$PREVIOUS_COMMIT"
  SHA="$PREVIOUS_SHA256"
  note "rollback verified"
}

do_update() {
  do_check
  if [ "$SAFE_UPGRADE" = true ]; then prepare_backup; fi
  local src='' zip="$WORK/$PACKAGE_KIND-$COMMIT.zip"
  if [ "$PACKAGE_KIND" = admin ]; then
    src="$WORK/src-$COMMIT"
    rm -rf "$src"
    git clone --quiet --no-checkout "$REPO_URL" "$src" >>"$LOG" 2>&1 || fail clone "git clone of $REPO_URL failed"
    git -C "$src" checkout --quiet "$COMMIT" >>"$LOG" 2>&1 || fail clone "commit $COMMIT is not in $REPO_URL: push it first"
    [ "$(git -C "$src" rev-parse HEAD)" = "$COMMIT" ] || fail clone "checked-out commit differs from $COMMIT"
    rm -f "$zip"
    # The admin build compiles shared files from src/ and analytics/, which import root packages.
    (cd "$src" && npm ci --ignore-scripts --no-audit --no-fund) >>"$LOG" 2>&1 || fail build "npm ci at the repository root failed (outbound HTTPS to registry.npmjs.org)"
    pwsh -NoProfile -File "$src/admin/Build-AdminPackage.ps1" -OutFile "$zip" >>"$LOG" 2>&1 || fail build "admin/Build-AdminPackage.ps1 failed (npm ci, build or unit tests)"
    [ -s "$zip" ] || fail build "no package at $zip"
    SHA=$(sha256sum "$zip" | cut -c1-64)
    note "built admin-$COMMIT.zip"
  else
    [ -s "$zip" ] || fail artifact "approved retained worker artifact missing: $zip"
    SHA=$(sha256sum "$zip" | cut -c1-64)
    [ "$SHA" = "$PACKAGE_SHA256" ] || fail artifact "worker artifact hash mismatch; no deployment attempted"
    note "verified $PACKAGE_KIND-$COMMIT.zip"
  fi
  one_deploy "$zip" \
    || upgrade_failed deploy "OneDeploy to $APP failed: check Website Contributor on the app and the private endpoint"
  verify_functions || upgrade_failed verify "$APP does not list required functions: $REQUIRED_FUNCTIONS"
  verify_host || upgrade_failed verify "worker host did not become reachable through its unchanged authentication"
  if [ "$SAFE_UPGRADE" = true ]; then
    verify_guard || upgrade_failed verify "settings/auth/access guard mismatch or unreadable"
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $APP $COMMIT $SHA" >>"$WORK/history.log"
  [ -z "$src" ] || rm -rf "$src"
  note "published"
}

case "$PACKAGE_KIND" in
  admin) REQUIRED_FUNCTIONS='projects adminUi adminHealth' ;;
  sync) REQUIRED_FUNCTIONS='syncEntitlement' ;;
  reconciler) REQUIRED_FUNCTIONS='reconcileBudgets' ;;
  *) fail input "unapproved package kind" ;;
esac
case "$PHASE" in
  setup) do_setup; do_check ;;
  check) do_check ;;
  update) do_update ;;
  rollback) do_rollback ;;
  *) fail input "unknown phase $PHASE" ;;
esac
emit succeeded "$PHASE" "ok"
