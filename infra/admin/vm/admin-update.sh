#!/bin/bash
# Runs on the admin-update VM through Azure Run Command, as root (docs/runbooks/ADMIN-UPDATE-FROM-VM.md,
# ADR 0037). infra/admin/Update-AdminFromVm.ps1 replaces the values line below; values are checked
# there against fixed patterns before they are written in single quotes.
#   setup   install git, curl, Azure CLI, Node.js 22 and PowerShell 7 when missing, then check
#   check   read-only: tools, managed identity sign-in, admin app read, private DNS, outbound HTTPS
#   update  check, then build the admin package at COMMIT and publish it with OneDeploy
# The last stdout line is one JSON run line ({"schema":"ccof.admin.vmupdate.v1",...}): Run Command
# returns only the last 4,096 bytes and exits 0 whatever the script returns.
set -uo pipefail
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

clean() { printf '%s' "$1" | tr -d '"\\' | tr '\r\n\t' '   ' | cut -c1-400; }
emit() {
  printf '{"schema":"ccof.admin.vmupdate.v1","phase":"%s","outcome":"%s","step":"%s","detail":"%s","app":"%s","commit":"%s","sha256":"%s","notes":"%s","log":"%s"}\n' \
    "$PHASE" "$1" "$2" "$(clean "$3")" "$APP" "$COMMIT" "$SHA" "$(clean "$NOTES")" "$LOG"
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
is_private() { [[ "$1" =~ ^10\. || "$1" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. || "$1" =~ ^192\.168\. ]]; }

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
  for t in git curl az node pwsh; do have "$t" || fail check "$t is not installed; run -Phase Setup -Apply first"; done
  [ "$(node_major)" -ge 22 ] || fail check "Node.js $(node -v) is older than 22; run -Phase Setup -Apply"
  note "node $(node -v), pwsh $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r')"
  az login --identity --allow-no-subscriptions >>"$LOG" 2>&1 || fail check "managed identity sign-in failed: the VM needs a system-assigned identity"
  az account set --subscription "$SUB" >>"$LOG" 2>&1 || fail check "subscription $SUB is not visible to the VM identity: assign Website Contributor on the admin app"
  local access
  access=$(az functionapp show --subscription "$SUB" --resource-group "$RG" --name "$APP" --output tsv --query 'publicNetworkAccess || properties.publicNetworkAccess' 2>>"$LOG") \
    || fail check "cannot read $APP: the VM identity needs Website Contributor on the admin app"
  note "$APP publicNetworkAccess=${access:-unset}"
  local ip
  ip=$(getent hosts "$APP.scm.azurewebsites.net" | awk '{print $1; exit}')
  [ -n "$ip" ] || fail check "$APP.scm.azurewebsites.net does not resolve"
  is_private "$ip" || fail check "$APP.scm.azurewebsites.net resolves to $ip, not a private address: the admin app private endpoint or its privatelink.azurewebsites.net record is missing for this VNet"
  note "$APP.scm.azurewebsites.net -> $ip"
  local url code
  for url in "${REPO_URL%.git}" https://registry.npmjs.org/; do
    code=$(curl -s -o /dev/null --max-time 20 -w '%{http_code}' "$url" 2>>"$LOG")
    [[ "$code" =~ ^[23] ]] || fail check "outbound HTTPS to $url returned '${code:-no answer}': the VM needs outbound HTTPS to the repository and the npm registry"
  done
  note "outbound HTTPS ok"
}

do_update() {
  do_check
  local src="$WORK/src-$COMMIT" zip="$WORK/admin-$COMMIT.zip"
  rm -rf "$src"
  git clone --quiet --no-checkout "$REPO_URL" "$src" >>"$LOG" 2>&1 || fail clone "git clone of $REPO_URL failed"
  git -C "$src" checkout --quiet "$COMMIT" >>"$LOG" 2>&1 || fail clone "commit $COMMIT is not in $REPO_URL: push it first"
  [ "$(git -C "$src" rev-parse HEAD)" = "$COMMIT" ] || fail clone "checked-out commit differs from $COMMIT"
  rm -f "$zip"
  # The admin build compiles shared files from src/ and analytics/, which import the root packages.
  (cd "$src" && npm ci --ignore-scripts --no-audit --no-fund) >>"$LOG" 2>&1 || fail build "npm ci at the repository root failed (outbound HTTPS to registry.npmjs.org)"
  pwsh -NoProfile -File "$src/admin/Build-AdminPackage.ps1" -OutFile "$zip" >>"$LOG" 2>&1 || fail build "admin/Build-AdminPackage.ps1 failed (npm ci, build or unit tests)"
  [ -s "$zip" ] || fail build "no package at $zip"
  SHA=$(sha256sum "$zip" | cut -c1-64)
  note "built admin-$COMMIT.zip"
  az functionapp deployment source config-zip --subscription "$SUB" --resource-group "$RG" --name "$APP" --src "$zip" >>"$LOG" 2>&1 \
    || fail deploy "OneDeploy to $APP failed: check Website Contributor on the app and the private endpoint"
  local i f listed missing=' not read'
  for i in $(seq 1 20); do
    listed=$(az functionapp function list --subscription "$SUB" --resource-group "$RG" --name "$APP" --output tsv --query '[].name' 2>>"$LOG")
    missing=''
    for f in projects adminUi adminHealth; do grep -q "/$f\$" <<<"$listed" || missing="$missing $f"; done
    [ -z "$missing" ] && break
    sleep "$POLL"
  done
  [ -z "$missing" ] || fail verify "$APP does not list:$missing"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $APP $COMMIT $SHA" >>"$WORK/history.log"
  rm -rf "$src"
  note "published"
}

case "$PHASE" in
  setup) do_setup; do_check ;;
  check) do_check ;;
  update) do_update ;;
  *) fail input "unknown phase $PHASE" ;;
esac
emit succeeded "$PHASE" "ok"
