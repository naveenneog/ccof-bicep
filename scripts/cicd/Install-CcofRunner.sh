#!/bin/bash
# Bootstraps a CCOF self-hosted GitHub Actions runner on a Linux VM (docs/runbooks/CICD-SETUP.md).
# The customer's VM admin runs it as root on their own (hardened) image: RHEL 8/9 or Ubuntu 22.04/24.04.
# It uses no cloud-init and no VM extension. Commands:
#   install     tools (git curl jq tar via apt/dnf/yum; Azure CLI package; Node.js, PowerShell, Bicep and the
#               runner from tarballs pinned by SHA-256, downloaded or taken from --stage) and the runner user
#   register    root-owned job policy and job-started hook, runner .env, configure and start the service.
#               Needs RUNNER_TOKEN (registration token, 1 hour) in the environment; it is never written
#   status      service state, then Test-RunnerHost.sh (next to this script) as the runner user
#   remove      stop the service and unregister; RUNNER_TOKEN is a remove token
#   print-hook  print the job-started hook (used by the offline tests)
# Exit codes: 0 ok, 2 input refused, 3 failed. The last stdout line is one JSON run line
# ({"schema":"ccof.cicd.runner.v1",...}) because Azure Run Command returns only the last 4,096 bytes.
set -uo pipefail
# @@ARGS@@
COMMAND="${1:-}"; [ $# -gt 0 ] && shift
ROLE=''; CLIENT_ID=''; SUBSCRIPTION_ID=''; TENANT_ID=''; REPOSITORY=''; RUNNER_NAME=''; LABELS=''
ALLOWED_REFS='refs/heads/main'; ALLOWED_WORKFLOWS=''
RUNNER_VERSION='2.338.2'; RUNNER_SHA256='baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40'
NODE_VERSION='22.23.5'; NODE_SHA256='c54118104acc524633b5abe106bbf44a53126ec8b4e5fa105cb92b5d7de8a1a1'
PWSH_VERSION='7.7.0'; PWSH_SHA256='c89d9c682d2c403dfe726f3df948e359675235a5bd6fab535776de69729ca0cb'
BICEP_VERSION='v0.46.1'; BICEP_SHA256='3e011d629ea4311b7a7dd8f0040ab2b1a072ea4ff5d02cb75e0e55a9a6703fb9'
AZ_PACKAGE=''; AZ_SHA256=''; STAGE=''; PROXY=''; NO_PROXY_EXTRA=''; CA_CERT=''
RUNNER_USER='ghrunner'; RUNNER_DIR='/opt/actions-runner'; TOOLS=/opt/ccof-tools; WORK=/var/lib/ccof-runner
POLICY=/etc/ccof-runner/policy; HOOK=/opt/ccof-runner/job-started.sh
NOTES=''; LOG=/dev/null; FETCHED=''
IMDS=169.254.169.254
DEFAULT_NO_PROXY="localhost,127.0.0.1,$IMDS,168.63.129.16,.documents.azure.com,.azurewebsites.net,.azure-api.net,.vaultcore.azure.net,.cognitiveservices.azure.com,.services.ai.azure.com,.openai.azure.com"

clean() { printf '%s' "$1" | tr -d '"\\' | tr '\r\n\t' '   ' | cut -c1-400; }
emit() {
  printf '{"schema":"ccof.cicd.runner.v1","phase":"%s","outcome":"%s","step":"%s","detail":"%s","role":"%s","runner":"%s","notes":"%s","log":"%s"}\n' \
    "$COMMAND" "$1" "$2" "$(clean "$3")" "$ROLE" "$RUNNER_NAME" "$(clean "$NOTES")" "$LOG"
}
refuse() { echo "input refused: $1" >&2; emit refused input "$1"; exit 2; }
fail() {
  [ "$LOG" != /dev/null ] && { echo "--- last lines of $LOG" >&2; tail -n 12 "$LOG" 2>/dev/null | cut -c1-160 >&2; }
  emit failed "$1" "$2"; exit 3
}
note() { NOTES="$NOTES$1; "; echo "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
want() { [[ "$2" =~ $3 ]] || refuse "$1 '$2' does not match $3"; }
GUID='^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
SHA='^[0-9a-f]{64}$'

print_hook() {
cat <<'HOOK'
#!/bin/bash
# CCOF job-started hook (installed by scripts/cicd/Install-CcofRunner.sh). A non-zero exit fails the job before
# any step runs. Policy: root-owned /etc/ccof-runner/policy (argument 1 overrides it for the offline tests).
# The apply runner holds the deploy identity: it only runs push, workflow_dispatch or schedule jobs of this
# repository on an allowed branch, and only allowed workflows when ALLOWED_WORKFLOWS is set.
set -euo pipefail
POLICY="${1:-/etc/ccof-runner/policy}"
deny() { echo "ccof-runner: job refused: $1" >&2; exit 1; }
[ -r "$POLICY" ] || deny "policy file $POLICY is missing"
get() { { grep -E "^$1=" "$POLICY" || true; } | tail -n 1 | cut -d= -f2- | tr -d '"'; }
ROLE=$(get RUNNER_ROLE); REPOSITORY=$(get REPOSITORY)
ALLOWED_REFS=$(get ALLOWED_REFS); ALLOWED_WORKFLOWS=$(get ALLOWED_WORKFLOWS)
EVENT="${GITHUB_EVENT_NAME:-}"; REF="${GITHUB_REF:-}"; WORKFLOW_REF="${GITHUB_WORKFLOW_REF:-}"
[ -n "$REPOSITORY" ] || deny "policy has no REPOSITORY"
[ "${GITHUB_REPOSITORY:-}" = "$REPOSITORY" ] || deny "repository '${GITHUB_REPOSITORY:-}' is not $REPOSITORY"
case "$ROLE" in
  preview) echo "ccof-runner: preview runner, $EVENT on $REF accepted."; exit 0 ;;
  apply) ;;
  *) deny "policy RUNNER_ROLE '$ROLE' is not preview or apply" ;;
esac
case "$EVENT" in
  push|workflow_dispatch|schedule) ;;
  *) deny "event '$EVENT' cannot run on the apply runner (pull_request jobs use ccof-preview)" ;;
esac
ok=0; for r in $ALLOWED_REFS; do [ "$REF" = "$r" ] && ok=1; done
[ "$ok" = 1 ] || deny "ref '$REF' is not one of: $ALLOWED_REFS"
if [ -n "$ALLOWED_WORKFLOWS" ]; then
  wf="${WORKFLOW_REF#"$REPOSITORY"/}"; wf="${wf%@*}"
  ok=0; for w in $ALLOWED_WORKFLOWS; do [ "$wf" = "$w" ] && ok=1; done
  [ "$ok" = 1 ] || deny "workflow '$wf' is not one of: $ALLOWED_WORKFLOWS"
fi
echo "ccof-runner: apply runner, $EVENT on $REF accepted."
HOOK
}

while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || refuse "option $1 needs a value"
  case "$1" in
    --role) ROLE="$2" ;; --client-id) CLIENT_ID="$2" ;; --subscription-id) SUBSCRIPTION_ID="$2" ;; --tenant-id) TENANT_ID="$2" ;;
    --repository) REPOSITORY="$2" ;; --runner-name) RUNNER_NAME="$2" ;; --labels) LABELS="$2" ;;
    --allowed-refs) ALLOWED_REFS="$2" ;; --allowed-workflows) ALLOWED_WORKFLOWS="$2" ;;
    --runner-version) RUNNER_VERSION="$2" ;; --runner-sha256) RUNNER_SHA256="$2" ;;
    --node-version) NODE_VERSION="$2" ;; --node-sha256) NODE_SHA256="$2" ;;
    --pwsh-version) PWSH_VERSION="$2" ;; --pwsh-sha256) PWSH_SHA256="$2" ;;
    --bicep-version) BICEP_VERSION="$2" ;; --bicep-sha256) BICEP_SHA256="$2" ;;
    --az-package) AZ_PACKAGE="$2" ;; --az-sha256) AZ_SHA256="$2" ;;
    --stage) STAGE="$2" ;; --proxy) PROXY="$2" ;; --no-proxy) NO_PROXY_EXTRA="$2" ;; --ca-cert) CA_CERT="$2" ;;
    --runner-user) RUNNER_USER="$2" ;; --runner-dir) RUNNER_DIR="$2" ;;
    *) refuse "unknown option $1" ;;
  esac
  shift 2
done

case "$COMMAND" in
  print-hook) print_hook; exit 0 ;;
  install|register|status|remove) ;;
  *) refuse "command must be install, register, status, remove or print-hook" ;;
esac
want role "$ROLE" '^(preview|apply)$'
want runner-version "$RUNNER_VERSION" '^[0-9]+\.[0-9]+\.[0-9]+$'; want node-version "$NODE_VERSION" '^22\.[0-9]+\.[0-9]+$'
want pwsh-version "$PWSH_VERSION" '^7\.[0-9]+\.[0-9]+$'; want bicep-version "$BICEP_VERSION" '^v[0-9]+\.[0-9]+\.[0-9]+$'
for v in "$RUNNER_SHA256" "$NODE_SHA256" "$PWSH_SHA256" "$BICEP_SHA256"; do want sha256 "$v" "$SHA"; done
[ -z "$AZ_SHA256" ] || want az-sha256 "$AZ_SHA256" "$SHA"
want runner-user "$RUNNER_USER" '^[a-z_][a-z0-9_-]{0,31}$'; want runner-dir "$RUNNER_DIR" '^/[A-Za-z0-9._/-]+$'
[ -z "$PROXY" ] || want proxy "$PROXY" '^https?://[A-Za-z0-9.:@_%-]+/?$'
[ -z "$NO_PROXY_EXTRA" ] || want no-proxy "$NO_PROXY_EXTRA" '^[A-Za-z0-9.,*_/:-]+$'
if [ "$COMMAND" = register ]; then
  want client-id "$CLIENT_ID" "$GUID"; want subscription-id "$SUBSCRIPTION_ID" "$GUID"; want tenant-id "$TENANT_ID" "$GUID"
  want repository "$REPOSITORY" '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
  [ -n "$RUNNER_NAME" ] || RUNNER_NAME="$(hostname -s)-$ROLE"
  [ -n "$LABELS" ] || LABELS="ccof-vnet,ccof-$ROLE"
  want runner-name "$RUNNER_NAME" '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'; want labels "$LABELS" '^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$'
  [[ ",$LABELS," == *",ccof-$ROLE,"* ]] || refuse "labels must include ccof-$ROLE"
  other=preview; [ "$ROLE" = preview ] && other=apply
  [[ ",$LABELS," != *",ccof-$other,"* ]] || refuse "labels must not include ccof-$other"
  want allowed-refs "$ALLOWED_REFS" '^refs/heads/[A-Za-z0-9._/-]+( refs/heads/[A-Za-z0-9._/-]+)*$'
  [ -z "$ALLOWED_WORKFLOWS" ] || want allowed-workflows "$ALLOWED_WORKFLOWS" '^\.github/workflows/[A-Za-z0-9._-]+( \.github/workflows/[A-Za-z0-9._-]+)*$'
fi
[ "$(id -u)" = 0 ] || refuse "run as root (sudo): the script installs packages and the runner service"

mkdir -p "$WORK" && chmod 700 "$WORK" || exit 3
LOG="$WORK/$COMMAND-$(date -u +%Y%m%dT%H%M%SZ).log"
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
export DEBIAN_FRONTEND=noninteractive
NO_PROXY_ALL="$DEFAULT_NO_PROXY${NO_PROXY_EXTRA:+,$NO_PROXY_EXTRA}"
if [ -n "$PROXY" ]; then
  export https_proxy="$PROXY" http_proxy="$PROXY" HTTPS_PROXY="$PROXY" HTTP_PROXY="$PROXY" no_proxy="$NO_PROXY_ALL" NO_PROXY="$NO_PROXY_ALL"
fi

pkg() {
  if have apt-get; then apt-get -o DPkg::Lock::Timeout=600 "$@"
  elif have dnf; then dnf -y "$@"
  elif have yum; then yum -y "$@"
  else return 9; fi
}
ca_bundle() { for f in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do [ -r "$f" ] && { echo "$f"; return; }; done; }
fetch() { # fetch <file name> <url> <sha256>: from --stage (directory or mirror URL) or the URL; sets FETCHED
  local name="$1" url="$2" sum="$3" out="$WORK/dl/$1"
  mkdir -p "$WORK/dl"
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then cp -f "$STAGE/$name" "$out" 2>>"$LOG" || fail fetch "$name is not in --stage $STAGE"
  else
    [ -n "$STAGE" ] && url="${STAGE%/}/$name"
    curl -fsSL --retry 3 -o "$out" "$url" >>"$LOG" 2>&1 || fail fetch "download of $url failed: check the egress allow-list, --proxy and --ca-cert"
  fi
  echo "$sum  $out" | sha256sum -c - >>"$LOG" 2>&1 || { rm -f "$out"; fail fetch "$name SHA-256 does not match the pinned value"; }
  FETCHED="$out"
}

preflight_imds() {
  local code
  code=$(curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' -H Metadata:true "http://$IMDS/metadata/instance?api-version=2021-02-01" 2>/dev/null)
  [ "$code" = 200 ] || fail imds "IMDS $IMDS is not reachable (HTTP ${code:-none}): managed identity needs it; allow it in the host firewall and do not send it through a proxy"
  note "IMDS reachable"
}

selinux_fix() {
  have selinuxenabled && selinuxenabled || return 0
  # Under SELinux enforcing, systemd only executes files with an executable type: label the runner entry points.
  local spec="$RUNNER_DIR/(runsvc\.sh|run\.sh|run-helper\.sh|config\.sh|bin/.*)"
  if have semanage; then
    semanage fcontext -a -t bin_t "$spec" >>"$LOG" 2>&1 || semanage fcontext -m -t bin_t "$spec" >>"$LOG" 2>&1
    restorecon -RF "$RUNNER_DIR" "$TOOLS" /usr/local/bin >>"$LOG" 2>&1
  else
    restorecon -RF "$RUNNER_DIR" "$TOOLS" /usr/local/bin >>"$LOG" 2>&1
    chcon -t bin_t "$RUNNER_DIR/runsvc.sh" >>"$LOG" 2>&1
  fi
  note "SELinux $(getenforce 2>/dev/null): contexts set under $RUNNER_DIR"
}

do_install() {
  preflight_imds
  [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = 1 ] && note "FIPS mode is on: see the FIPS notes in CICD-SETUP.md"
  if [ -n "$CA_CERT" ]; then
    [ -r "$CA_CERT" ] || refuse "--ca-cert $CA_CERT is not readable"
    if [ -d /etc/pki/ca-trust/source/anchors ]; then cp -f "$CA_CERT" /etc/pki/ca-trust/source/anchors/ccof-corporate-ca.crt && update-ca-trust extract
    else mkdir -p /usr/local/share/ca-certificates && cp -f "$CA_CERT" /usr/local/share/ca-certificates/ccof-corporate-ca.crt && update-ca-certificates; fi >>"$LOG" 2>&1 \
      || fail ca "cannot add $CA_CERT to the system trust store"
    note "corporate CA added to the system trust store"
  fi
  local missing='' t
  for t in git curl jq tar gzip sha256sum; do have "$t" || missing="$missing $t"; done
  if [ -n "$missing" ]; then
    note "installing:$missing"
    { if have apt-get; then pkg update -y; fi; pkg install -y git curl jq tar gzip coreutils ca-certificates; } >>"$LOG" 2>&1 \
      || fail packages "package install failed: configure the distribution repositories or mirror"
  fi
  if ! have az; then
    if [ -n "$AZ_PACKAGE" ]; then
      [ -n "$AZ_SHA256" ] || refuse "--az-package needs --az-sha256"
      echo "$AZ_SHA256  $AZ_PACKAGE" | sha256sum -c - >>"$LOG" 2>&1 || fail az "$AZ_PACKAGE SHA-256 does not match --az-sha256"
      pkg install -y "$AZ_PACKAGE" >>"$LOG" 2>&1 || fail az "Azure CLI package install failed"
    elif have apt-get; then
      { curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash; } >>"$LOG" 2>&1 || fail az "Azure CLI install failed (aka.ms, packages.microsoft.com)"
    else
      local rel; rel=$(. /etc/os-release && echo "${VERSION_ID%%.*}")
      { rpm --import https://packages.microsoft.com/keys/microsoft.asc && pkg install "https://packages.microsoft.com/config/rhel/$rel/packages-microsoft-prod.rpm" \
        && pkg install azure-cli; } >>"$LOG" 2>&1 || fail az "Azure CLI install failed (packages.microsoft.com)"
    fi
    note "Azure CLI installed"
  fi
  if [ "$("$TOOLS/node/bin/node" -v 2>/dev/null)" != "v$NODE_VERSION" ]; then
    fetch "node-v$NODE_VERSION-linux-x64.tar.gz" "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.gz" "$NODE_SHA256"
    rm -rf "$TOOLS/node" && mkdir -p "$TOOLS/node" && tar xzf "$FETCHED" -C "$TOOLS/node" --strip-components 1 >>"$LOG" 2>&1 || fail node "Node.js extraction failed"
    for t in node npm npx; do ln -sf "$TOOLS/node/bin/$t" "/usr/local/bin/$t"; done
    note "node v$NODE_VERSION installed"
  fi
  if [ "$("$TOOLS/pwsh/pwsh" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r')" != "$PWSH_VERSION" ]; then
    fetch "powershell-$PWSH_VERSION-linux-x64.tar.gz" "https://github.com/PowerShell/PowerShell/releases/download/v$PWSH_VERSION/powershell-$PWSH_VERSION-linux-x64.tar.gz" "$PWSH_SHA256"
    rm -rf "$TOOLS/pwsh" && mkdir -p "$TOOLS/pwsh" && tar xzf "$FETCHED" -C "$TOOLS/pwsh" >>"$LOG" 2>&1 && chmod 755 "$TOOLS/pwsh/pwsh" || fail pwsh "PowerShell extraction failed"
    ln -sf "$TOOLS/pwsh/pwsh" /usr/local/bin/pwsh
    note "pwsh $PWSH_VERSION installed"
  fi
  if [ "$(/usr/local/bin/bicep --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" != "${BICEP_VERSION#v}" ]; then
    fetch bicep-linux-x64 "https://github.com/Azure/bicep/releases/download/$BICEP_VERSION/bicep-linux-x64" "$BICEP_SHA256"
    install -m 755 "$FETCHED" /usr/local/bin/bicep || fail bicep "Bicep install failed"
    note "bicep $BICEP_VERSION installed"
  fi
  id "$RUNNER_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$RUNNER_USER" >>"$LOG" 2>&1 || fail user "cannot create user $RUNNER_USER"
  if [ "$(cat "$RUNNER_DIR/.ccof-version" 2>/dev/null)" != "$RUNNER_VERSION" ]; then
    fetch "actions-runner-linux-x64-$RUNNER_VERSION.tar.gz" "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz" "$RUNNER_SHA256"
    mkdir -p "$RUNNER_DIR" && tar xzf "$FETCHED" -C "$RUNNER_DIR" >>"$LOG" 2>&1 || fail runner "runner extraction failed"
    "$RUNNER_DIR/bin/installdependencies.sh" >>"$LOG" 2>&1 || fail runner "runner dependency install failed (libicu, openssl, krb5 from the distribution repositories)"
    echo "$RUNNER_VERSION" >"$RUNNER_DIR/.ccof-version"
    note "runner $RUNNER_VERSION installed in $RUNNER_DIR"
  fi
  mkdir -p "$RUNNER_DIR/_work/_tmp"; chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"
  rm -rf "$WORK/dl"
  selinux_fix
  note "az $(az version --query '"azure-cli"' -o tsv 2>/dev/null), node $(node -v 2>/dev/null), pwsh $PWSH_VERSION, bicep $BICEP_VERSION"
}

service_name() { systemctl list-unit-files --no-legend 'actions.runner.*' 2>/dev/null | awk '{print $1; exit}'; }

write_env() {
  # The runner reads .env and .path at start; every job inherits them.
  local bundle; bundle=$(ca_bundle)
  {
    echo "LANG=C.UTF-8"
    echo "CCOF_RUNNER_ROLE=$ROLE"
    echo "CCOF_RUNNER_IDENTITY_CLIENT_ID=$CLIENT_ID"
    echo "CCOF_RUNNER_SUBSCRIPTION_ID=$SUBSCRIPTION_ID"
    echo "CCOF_RUNNER_TENANT_ID=$TENANT_ID"
    echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$HOOK"
    echo "TMPDIR=$RUNNER_DIR/_work/_tmp"
    echo "AZURE_BICEP_USE_BINARY_FROM_PATH=true"
    echo "AZURE_BICEP_CHECK_VERSION=false"
    echo "AZURE_CORE_COLLECT_TELEMETRY=false"
    if [ -n "$PROXY" ]; then
      echo "https_proxy=$PROXY"; echo "HTTPS_PROXY=$PROXY"; echo "http_proxy=$PROXY"; echo "HTTP_PROXY=$PROXY"
      echo "no_proxy=$NO_PROXY_ALL"; echo "NO_PROXY=$NO_PROXY_ALL"
    fi
    if [ -n "$CA_CERT" ] && [ -n "$bundle" ]; then echo "REQUESTS_CA_BUNDLE=$bundle"; echo "NODE_EXTRA_CA_CERTS=$CA_CERT"; fi
  } >"$RUNNER_DIR/.env"
  echo "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin" >"$RUNNER_DIR/.path"
  chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR/.env" "$RUNNER_DIR/.path"
  if [ -n "$CA_CERT" ] && [ -n "$bundle" ]; then git config --system http.sslCAInfo "$bundle"; fi
  return 0
}

do_register() {
  [ -x "$RUNNER_DIR/config.sh" ] || fail register "runner is not installed: run install first"
  [ -n "${RUNNER_TOKEN:-}" ] || refuse "RUNNER_TOKEN (registration token) is not set in the environment"
  [[ "$RUNNER_TOKEN" =~ ^[A-Za-z0-9_-]{20,200}$ ]] || refuse "RUNNER_TOKEN does not look like a registration token"
  mkdir -p /etc/ccof-runner "$(dirname "$HOOK")"
  printf 'RUNNER_ROLE=%s\nREPOSITORY=%s\nALLOWED_REFS=%s\nALLOWED_WORKFLOWS=%s\n' "$ROLE" "$REPOSITORY" "$ALLOWED_REFS" "$ALLOWED_WORKFLOWS" >"$POLICY"
  print_hook >"$HOOK"
  chown root:root /etc/ccof-runner "$POLICY" "$(dirname "$HOOK")" "$HOOK"
  chmod 755 /etc/ccof-runner "$(dirname "$HOOK")" "$HOOK"; chmod 644 "$POLICY"
  local svc; svc=$(service_name)
  if [ -n "$svc" ]; then (cd "$RUNNER_DIR" && ./svc.sh stop && ./svc.sh uninstall) >>"$LOG" 2>&1 || fail register "cannot stop the existing service $svc"; fi
  # Re-registration: drop the local registration; --replace takes over the runner with the same name on GitHub.
  rm -f "$RUNNER_DIR/.runner" "$RUNNER_DIR/.credentials" "$RUNNER_DIR/.credentials_rsaparams"
  (cd "$RUNNER_DIR" && runuser -u "$RUNNER_USER" -- ./config.sh --unattended --url "https://github.com/$REPOSITORY" \
    --token "$RUNNER_TOKEN" --name "$RUNNER_NAME" --labels "$LABELS" --work _work --replace) >>"$LOG" 2>&1 \
    || fail register "config.sh failed: the registration token may be expired (1 hour) or for another repository"
  write_env
  (cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER") >>"$LOG" 2>&1 || fail register "runner service install failed"
  selinux_fix
  (cd "$RUNNER_DIR" && ./svc.sh start) >>"$LOG" 2>&1 || fail register "runner service start failed"
  note "registered $RUNNER_NAME ($LABELS) to $REPOSITORY as $(service_name)"
}

do_status() {
  local svc state; svc=$(service_name)
  [ -n "$svc" ] || fail status "no runner service: run register"
  state=$(systemctl is-active "$svc" 2>/dev/null); note "$svc $state"
  [ "$state" = active ] || fail status "runner service $svc is $state"
  local pre; pre="$(dirname "$0")/Test-RunnerHost.sh"
  if [ -r "$pre" ]; then
    (set -a; . "$RUNNER_DIR/.env"; set +a; cd "$RUNNER_DIR" && runuser -u "$RUNNER_USER" -- bash "$pre") >>"$LOG" 2>&1 \
      || fail preflight "Test-RunnerHost.sh failed as $RUNNER_USER: see $LOG"
    note "Test-RunnerHost.sh passed as $RUNNER_USER"
  fi
}

do_remove() {
  [ -n "${RUNNER_TOKEN:-}" ] || refuse "RUNNER_TOKEN (a remove token) is not set in the environment"
  local svc; svc=$(service_name)
  if [ -n "$svc" ]; then (cd "$RUNNER_DIR" && ./svc.sh stop && ./svc.sh uninstall) >>"$LOG" 2>&1; fi
  (cd "$RUNNER_DIR" && runuser -u "$RUNNER_USER" -- ./config.sh remove --token "$RUNNER_TOKEN") >>"$LOG" 2>&1 || fail remove "config.sh remove failed"
  note "removed the runner registration"
}

case "$COMMAND" in
  install) do_install ;; register) do_register ;; status) do_status ;; remove) do_remove ;;
esac
emit succeeded "$COMMAND" ok
exit 0
