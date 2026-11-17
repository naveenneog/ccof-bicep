#!/bin/bash
# Body of .github/actions/azure-login-mi (docs/runbooks/CICD-SETUP.md). Inputs arrive as IN_* variables;
# the runner identity comes from the runner's .env file, written by scripts/cicd/Install-CcofRunner.sh register:
# CCOF_RUNNER_ROLE, CCOF_RUNNER_IDENTITY_CLIENT_ID, CCOF_RUNNER_SUBSCRIPTION_ID.
set -euo pipefail
GUID='^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
fail() { echo "::error title=azure-login-mi::$1"; exit 1; }
: "${RUNNER_TEMP:?RUNNER_TEMP is not set: run this inside a GitHub Actions job}"
: "${GITHUB_ENV:?GITHUB_ENV is not set: run this inside a GitHub Actions job}"
MODE="${IN_MODE:-login}"

if [ "$MODE" = logout ]; then
  dir="${AZURE_CONFIG_DIR:-}"
  case "$dir" in
    "$RUNNER_TEMP"/azcfg.*)
      az logout >/dev/null 2>&1 || true
      az account clear >/dev/null 2>&1 || true
      rm -rf -- "$dir"
      echo "AZURE_CONFIG_DIR=" >>"$GITHUB_ENV"
      echo "Signed out; removed the per-job Azure CLI profile." ;;
    '') echo "No per-job Azure CLI profile to remove." ;;
    *) fail "AZURE_CONFIG_DIR '$dir' was not created by this action; not removed." ;;
  esac
  exit 0
fi
[ "$MODE" = login ] || fail "mode must be login or logout, not '$MODE'"

ROLE="${CCOF_RUNNER_ROLE:-}"
case "$ROLE" in
  preview|apply) ;;
  *) fail "this runner has no CCOF_RUNNER_ROLE (preview or apply): it was not set up by scripts/cicd/Install-CcofRunner" ;;
esac
if [ -n "${IN_ROLE:-}" ] && [ "$IN_ROLE" != "$ROLE" ]; then
  fail "the job expects the $IN_ROLE identity but runs on a $ROLE runner; check runs-on (ccof-$IN_ROLE label)"
fi
CLIENT_ID="${IN_CLIENT_ID:-${CCOF_RUNNER_IDENTITY_CLIENT_ID:-}}"
SUB="${IN_SUBSCRIPTION_ID:-${CCOF_RUNNER_SUBSCRIPTION_ID:-}}"
[[ "$CLIENT_ID" =~ $GUID ]] || fail "identity client ID '$CLIENT_ID' is not a GUID"
[[ "$SUB" =~ $GUID ]] || fail "subscription ID '$SUB' is not a GUID"
command -v az >/dev/null 2>&1 || fail "Azure CLI is not installed on this runner"

dir=$(mktemp -d "$RUNNER_TEMP/azcfg.XXXXXXXX")
chmod 700 "$dir"
export AZURE_CONFIG_DIR="$dir"
{ echo "AZURE_CONFIG_DIR=$dir"; echo "AZURE_CORE_COLLECT_TELEMETRY=false"; } >>"$GITHUB_ENV"

# Azure CLI 2.69 added --client-id; older versions take the client ID as --username.
if ! out=$(az login --identity --client-id "$CLIENT_ID" --output none 2>&1); then
  if grep -qiE "unrecognized arguments|--client-id" <<<"$out"; then
    az login --identity --username "$CLIENT_ID" --output none || fail "az login --identity failed for client ID $CLIENT_ID"
  else
    echo "$out" >&2
    fail "az login --identity failed for client ID $CLIENT_ID: is this identity attached to the runner VM?"
  fi
fi
az account set --subscription "$SUB" || fail "subscription $SUB is not visible to identity $CLIENT_ID: it needs a role in that subscription"
TENANT=$(az account show --query tenantId --output tsv)
{ echo "client-id=$CLIENT_ID"; echo "subscription-id=$SUB"; echo "tenant-id=$TENANT"; echo "role=$ROLE"; } >>"${GITHUB_OUTPUT:-/dev/null}"
echo "Signed in with the $ROLE runner identity $CLIENT_ID (tenant $TENANT, subscription $SUB) in a per-job profile."
