#!/bin/bash
# Preflight for a CCOF runner host (docs/runbooks/CICD-SETUP.md). Run it as the first step of every job on a
# ccof-* runner, or as the runner user after Install-CcofRunner.sh. It changes nothing on the host.
# Prints one PASS, FAIL, WARN or INFO line per check with its evidence; exits 1 when any check fails.
#   --client-id GUID        identity to sign in with (default CCOF_RUNNER_IDENTITY_CLIENT_ID)
#   --subscription-id GUID  subscription to select (default CCOF_RUNNER_SUBSCRIPTION_ID)
#   --private-fqdns "a b"   names that must resolve to private addresses (default CCOF_PRIVATE_FQDNS)
#   --bicep-version vX.Y.Z  expected Bicep version (default: any)
#   --min-disk-gb N         free space needed in the work directory (default 10)
#   --no-login              skip the managed identity sign-in
set -uo pipefail
CLIENT_ID="${CCOF_RUNNER_IDENTITY_CLIENT_ID:-}"; SUB="${CCOF_RUNNER_SUBSCRIPTION_ID:-}"; FQDNS="${CCOF_PRIVATE_FQDNS:-}"
BICEP=''; MIN_GB=10; LOGIN=1
while [ $# -gt 0 ]; do
  case "$1" in
    --client-id) CLIENT_ID="$2"; shift 2 ;; --subscription-id) SUB="$2"; shift 2 ;; --private-fqdns) FQDNS="$2"; shift 2 ;;
    --bicep-version) BICEP="$2"; shift 2 ;; --min-disk-gb) MIN_GB="$2"; shift 2 ;; --no-login) LOGIN=0; shift ;;
    *) echo "FAIL arguments: unknown option $1"; exit 2 ;;
  esac
done
FAILS=0
pass() { echo "PASS $1: $2"; }
bad() { echo "FAIL $1: $2"; FAILS=$((FAILS + 1)); }
warn() { echo "WARN $1: $2"; }
info() { echo "INFO $1: $2"; }
have() { command -v "$1" >/dev/null 2>&1; }
GUID='^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
is_private() {
  local a b; IFS=. read -r a b _ _ <<<"$1"
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [ "$a" = 10 ] || { [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } || { [ "$a" = 192 ] && [ "$b" = 168 ]; } || { [ "$a" = 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; }
}
resolve() {
  if have getent; then getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'
  elif have nslookup; then nslookup "$1" 2>/dev/null | awk '/^Address/ && !/#/ {print $2}' | tail -n 1
  fi
}

# 1. IMDS first: managed identity sign-in needs it, without a proxy.
code=$(curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2021-02-01" 2>/dev/null)
if [ "$code" = 200 ]; then pass imds "169.254.169.254 HTTP 200"; else bad imds "169.254.169.254 HTTP ${code:-none}: allow it in the host firewall and exclude it from the proxy"; fi
proxy="${HTTPS_PROXY:-${https_proxy:-}}"; noproxy="${NO_PROXY:-${no_proxy:-}}"
# Only the proxy host:port is ever printed; a proxy with user:password@ is refused (credentials would reach job logs).
proxy_shown="${proxy#*://}"; proxy_shown="${proxy_shown##*@}"; proxy_shown="${proxy_shown%%/*}"
if [ -n "$proxy" ]; then
  if [[ "$proxy" == *@* ]]; then bad proxy "HTTPS_PROXY contains credentials (user:password@, not shown): use an IP-allow-listed proxy"
  elif [[ ",$noproxy," == *",169.254.169.254,"* ]]; then pass proxy "HTTPS_PROXY set; NO_PROXY includes 169.254.169.254"
  else bad proxy "HTTPS_PROXY is set but NO_PROXY does not include 169.254.169.254"; fi
else info proxy "no HTTPS_PROXY"; fi

# 2. Tools.
for t in git curl jq tar; do if have "$t"; then pass "tool $t" "$(command -v "$t")"; else bad "tool $t" "not on PATH"; fi; done
if have az; then pass "tool az" "azure-cli $(az version --query '"azure-cli"' -o tsv 2>/dev/null)"; else bad "tool az" "not on PATH"; fi
nv=$(node -v 2>/dev/null); if [[ "$nv" =~ ^v(2[2-9]|[3-9][0-9]) ]]; then pass "tool node" "$nv"; else bad "tool node" "need Node.js 22 or later, found '${nv:-none}'"; fi
pv=$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r'); if [[ "$pv" =~ ^7\. ]]; then pass "tool pwsh" "$pv"; else bad "tool pwsh" "need PowerShell 7, found '${pv:-none}'"; fi
bv=$(bicep --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
if [ -z "$bv" ]; then bad "tool bicep" "not on PATH"
elif [ -n "$BICEP" ] && [ "$bv" != "${BICEP#v}" ]; then bad "tool bicep" "found $bv, need ${BICEP#v}"
else pass "tool bicep" "$bv"; fi

# 3. Managed identity sign-in in a throwaway profile.
if [ "$LOGIN" = 1 ]; then
  if [[ ! "$CLIENT_ID" =~ $GUID ]]; then bad identity "no identity client ID (CCOF_RUNNER_IDENTITY_CLIENT_ID or --client-id)"
  elif have az; then
    cfg=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/preflight-az.XXXXXX")
    if out=$(AZURE_CONFIG_DIR="$cfg" az login --identity --client-id "$CLIENT_ID" --allow-no-subscriptions --output none 2>&1); then
      if [[ "$SUB" =~ $GUID ]]; then
        if AZURE_CONFIG_DIR="$cfg" az account set --subscription "$SUB" >/dev/null 2>&1; then pass identity "az login --identity $CLIENT_ID; subscription $SUB visible"
        else bad identity "signed in as $CLIENT_ID but subscription $SUB is not visible: the identity has no role there"; fi
      else pass identity "az login --identity $CLIENT_ID"; fi
    else bad identity "az login --identity --client-id $CLIENT_ID failed: $(echo "$out" | tail -n 1 | cut -c1-200)"; fi
    AZURE_CONFIG_DIR="$cfg" az logout >/dev/null 2>&1; rm -rf "$cfg"
  fi
else info identity "skipped (--no-login)"; fi

# 4. Private DNS.
for f in $FQDNS; do
  ip=$(resolve "$f")
  if [ -z "$ip" ]; then bad "dns $f" "does not resolve"
  elif is_private "$ip"; then pass "dns $f" "$ip (private)"
  else bad "dns $f" "$ip is public: the privatelink zone is not linked to this VNet or the record is missing"; fi
done
[ -n "$FQDNS" ] || info dns "no CCOF_PRIVATE_FQDNS given"

# 5. GitHub through the proxy (if any), and the clock against the GitHub Date header.
hdr=$(curl -sS -I --max-time 15 https://api.github.com/ 2>&1)
gcode=$(printf '%s\n' "$hdr" | awk 'toupper($1) ~ /^HTTP/ {c=$2} END {print c}')
if [ "$gcode" = 200 ]; then pass github "https://api.github.com HTTP 200${proxy:+ via proxy $proxy_shown}"; else bad github "https://api.github.com: $(printf '%s' "$hdr" | head -n 1 | tr -d '\r' | cut -c1-200)"; fi
gdate=$(printf '%s\n' "$hdr" | awk -F': ' 'tolower($1)=="date" {print $2}' | tr -d '\r')
if [ -n "$gdate" ] && gs=$(date -u -d "$gdate" +%s 2>/dev/null); then
  skew=$(( $(date -u +%s) - gs )); skew=${skew#-}
  if [ "$skew" -le 300 ]; then pass clock "skew ${skew}s against api.github.com"; else bad clock "skew ${skew}s against api.github.com (tokens fail beyond 5 minutes): check NTP"; fi
else warn clock "could not read the api.github.com Date header"; fi
if have timedatectl; then info ntp "NTPSynchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"; fi

# 6. Disk space and executable temp directory.
dir="${GITHUB_WORKSPACE:-$PWD}"
kb=$(df -Pk "$dir" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$kb" ] && [ "$kb" -ge $((MIN_GB * 1024 * 1024)) ]; then pass disk "$((kb / 1024 / 1024)) GB free in $dir"
else bad disk "$((${kb:-0} / 1024 / 1024)) GB free in $dir, need $MIN_GB"; fi
tdir="${TMPDIR:-/tmp}"
probe=$(mktemp "$tdir/ccof-exec.XXXXXX" 2>/dev/null)
if [ -n "$probe" ] && printf '#!/bin/sh\necho ok\n' >"$probe" && chmod 700 "$probe" && [ "$("$probe" 2>/dev/null)" = ok ]; then pass tmpdir "$tdir allows executables"
else bad tmpdir "$tdir does not allow executables (noexec): set TMPDIR inside the runner _work directory"; fi
[ -n "$probe" ] && rm -f "$probe"
if [ "$tdir" != /tmp ] && have findmnt && findmnt -no OPTIONS --target /tmp 2>/dev/null | grep -qw noexec; then info tmp "/tmp is noexec; TMPDIR=$tdir is used"; fi

# 7. Host facts.
info selinux "$(getenforce 2>/dev/null || echo 'not present')"
info fips "fips_enabled=$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo n/a)"
info os "$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -sr)"
info role "CCOF_RUNNER_ROLE=${CCOF_RUNNER_ROLE:-unset}"

echo "Test-RunnerHost: $FAILS failed"
[ "$FAILS" = 0 ]
