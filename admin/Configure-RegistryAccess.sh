#!/usr/bin/env bash
# Paste into Azure Cloud Shell BASH after filling the variables. No repository clone is required.
# Adds registry access for the admin app only; never enables public Cosmos access or account keys.
set -euo pipefail

SUB="REPLACE-subscription-guid"
COSMOS_RG="REPLACE-cosmos-resource-group"
COSMOS="REPLACE-cosmos-account"
APP_RG="REPLACE-admin-app-resource-group"
APP="REPLACE-admin-function-app"
NET_RG="REPLACE-admin-network-resource-group"
VNET="REPLACE-admin-vnet"
PE_SUBNET="snet-admin-private-endpoints"
DB="ccof"
CONTAINER="projects"
PE="${APP}-cosmos-pe"
ZONE="privatelink.documents.azure.com"

[[ "$SUB" != REPLACE-* ]] || { echo "Fill the variables first."; exit 1; }
az account show --subscription "$SUB" --query '{subscription:id,tenant:tenantId}' -o json
CID=$(az cosmosdb show --subscription "$SUB" -g "$COSMOS_RG" -n "$COSMOS" --query id -o tsv)
PID=$(az functionapp identity show --subscription "$SUB" -g "$APP_RG" -n "$APP" --query principalId -o tsv)
VID=$(az network vnet show --subscription "$SUB" -g "$NET_RG" -n "$VNET" --query id -o tsv)
LOCATION=$(az network vnet show --subscription "$SUB" -g "$NET_RG" -n "$VNET" --query location -o tsv)
SID=$(az network vnet subnet show --subscription "$SUB" -g "$NET_RG" --vnet-name "$VNET" -n "$PE_SUBNET" --query id -o tsv)
INTEGRATION=$(az functionapp show --subscription "$SUB" -g "$APP_RG" -n "$APP" --query 'properties.virtualNetworkSubnetId || virtualNetworkSubnetId' -o tsv)
PUBLIC=$(az cosmosdb show --subscription "$SUB" -g "$COSMOS_RG" -n "$COSMOS" --query publicNetworkAccess -o tsv)
[[ -n "$PID" && "$PID" != "None" ]] || { echo "STOP: admin app has no system-assigned identity."; exit 1; }
[[ "${INTEGRATION,,}" == "${VID,,}/subnets/"* ]] || { echo "STOP: admin app is not integrated with the selected VNet."; exit 1; }
[[ "$PUBLIC" == "Disabled" ]] || { echo "STOP: expected private-only Cosmos; review its configuration."; exit 1; }
az cosmosdb sql container show --subscription "$SUB" -g "$COSMOS_RG" -a "$COSMOS" -d "$DB" -n "$CONTAINER" --query 'resource.partitionKey.paths' -o json

# Stable IDs make role reruns target this role and this assignment, not create duplicates.
RID=$(python3 -c 'import sys,uuid; print(uuid.uuid5(uuid.NAMESPACE_URL,sys.argv[1].lower()+"/ccof-admin-project-editor"))' "$CID")
SCOPE="/dbs/$DB/colls/$CONTAINER"
AID=$(python3 -c 'import sys,uuid; print(uuid.uuid5(uuid.NAMESPACE_URL,"|".join(sys.argv[1:]).lower()))' "$CID" "$PID" "$SCOPE" "$RID")

umask 077
ROLE_FILE=$(mktemp)
HEALTH_FILE=$(mktemp)
trap 'rm -f "$ROLE_FILE" "$HEALTH_FILE"; unset KEY' EXIT
cat > "$ROLE_FILE" <<JSON
{
  "Id": "$RID",
  "RoleName": "ccof-admin-project-editor",
  "Type": "CustomRole",
  "AssignableScopes": ["$CID"],
  "Permissions": [{"DataActions": [
    "Microsoft.DocumentDB/databaseAccounts/readMetadata",
    "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery",
    "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/readChangeFeed",
    "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read",
    "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create",
    "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace"
  ]}]
}
JSON
az cosmosdb sql role definition create --subscription "$SUB" -g "$COSMOS_RG" -a "$COSMOS" \
  --body "@$ROLE_FILE" --output none
az cosmosdb sql role assignment create --subscription "$SUB" -g "$COSMOS_RG" -a "$COSMOS" \
  --role-definition-id "$RID" --role-assignment-id "$AID" \
  --principal-id "$PID" --scope "$SCOPE" --output none

# Dedicated DNS zone in the ADMIN network resource group, not the existing CCOF zone.
az network private-dns zone create --subscription "$SUB" -g "$NET_RG" -n "$ZONE" --output none
az network private-dns link vnet create --subscription "$SUB" -g "$NET_RG" \
  --zone-name "$ZONE" -n "${VNET}-cosmos-link" --virtual-network "$VID" \
  --registration-enabled false --output none
az network private-endpoint create --subscription "$SUB" -g "$NET_RG" -n "$PE" \
  --location "$LOCATION" --subnet "$SID" --private-connection-resource-id "$CID" \
  --group-id Sql --connection-name "${PE}-connection" --output none
STATE=$(az network private-endpoint show --subscription "$SUB" -g "$NET_RG" -n "$PE" \
  --query '(privateLinkServiceConnections[0] || manualPrivateLinkServiceConnections[0]).privateLinkServiceConnectionState.status' -o tsv)
[[ "$STATE" == "Approved" ]] || { echo "STOP: connection is $STATE. Ask the Cosmos owner to approve this new connection, then rerun."; exit 1; }
ZONE_ID=$(az network private-dns zone show --subscription "$SUB" -g "$NET_RG" -n "$ZONE" --query id -o tsv)
az network private-endpoint dns-zone-group create --subscription "$SUB" -g "$NET_RG" \
  --endpoint-name "$PE" -n cosmos --private-dns-zone "$ZONE_ID" --zone-name cosmos --output none

# Refresh only the ADMIN app's DNS/client state. Existing apps are not restarted.
az functionapp restart --subscription "$SUB" -g "$APP_RG" -n "$APP"
echo "Allow a few minutes for DNS and role propagation; checking from the Function App..."
sleep 60
HOST=$(az functionapp show --subscription "$SUB" -g "$APP_RG" -n "$APP" --query 'properties.defaultHostName || defaultHostName' -o tsv)
KEY=$(az functionapp keys list --subscription "$SUB" -g "$APP_RG" -n "$APP" --query functionKeys.default -o tsv)
[[ -n "$KEY" && "$KEY" != "None" ]] || { echo "STOP: no health function key returned."; exit 1; }
HTTP=$(curl --silent --show-error --connect-timeout 15 --max-time 90 \
  -H "x-functions-key: $KEY" -o "$HEALTH_FILE" -w '%{http_code}' "https://$HOST/api/health")
unset KEY
cat "$HEALTH_FILE"; echo
[[ "$HTTP" == "200" ]] || { echo "NOT READY (HTTP $HTTP). Check the guide's troubleshooting before proceeding."; exit 1; }
python3 -c 'import json,sys; x=json.load(open(sys.argv[1])); assert x.get("status")=="ready" and x.get("checks",{}).get("cosmos")=="ok", x' "$HEALTH_FILE"
echo "Health probe passed. Open https://$HOST/api/console and click Try again."
echo "This verifies a Cosmos point read from the app, not list/create/update or entitlement-sync acceptance."
