"""Build Portal walkthrough steps (guide step -> deep link + expected text) from a staged run's state."""
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8")); st = json.load(open(sys.argv[2], encoding="utf-8")); out = sys.argv[3]
S = st["stages"]; s1 = S["1"]["outputs"]; n = s1["names"]
sub, rg = cfg["subscriptionId"], cfg["resourceGroup"]
R = f"/subscriptions/{sub}/resourceGroups/{rg}"
apim = f"{R}/providers/Microsoft.ApiManagement/service/{s1['apimName']}"
fd = cfg["stage1"]["foundry"]["accountName"]; fid = f"{R}/providers/Microsoft.CognitiveServices/accounts/{fd}"
site = lambda k: f"{R}/providers/Microsoft.Web/sites/{n['apps'][k]['functionApp']}"
steps = [
 ("00-subscription-access", "0", "Subscription: Access control (IAM) - view my access", f"/resource/subscriptions/{sub}/users", ["Active permanent assignments"]),
 ("01-rg-overview", "1", "Resource group overview: the deployed resources", f"/resource{R}/overview", [n["cosmosAccount"]]),
 ("01-rg-deployments", "1", "Resource group: Deployments (stage1-services ... stage6-network)", f"/resource{R}/deployments", ["stage1-services"]),
 ("01-apim-overview", "1", "API Management overview: Standard v2", f"/resource{apim}/overview", ["Standard v2"]),
 ("01-apim-identity", "1", "API Management: Managed identities - system assigned", f"/resource{apim}/overview", ["System assigned"]),
 ("01-foundry-overview", "Foundry", "Foundry account overview", f"/resource{fid}/overview", [fd]),
 ("06-foundry-networking", "Foundry/6", "Foundry: Networking - public access disabled, private endpoint", f"/resource{fid}/overview", ["Private endpoint"]),
 ("06-apim-network", "6", "API Management: Network - outbound VNet integration", f"/resource{apim}/overview", ["outbound private network"]),
 ("06-function-networking", "6", "Function App: Networking - VNet integration", f"/resource{site('resolver')}/networkingHub", ["snet-functions"]),
 ("06-dns-links", "6", "Private DNS zone: Virtual network links", f"/resource{R}/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com/overview", [cfg["network"]["create"]["vnetName"]]),
 ("02-cosmos-overview", "2", "Cosmos DB account overview (private)", f"/resource{R}/providers/Microsoft.DocumentDB/databaseAccounts/{n['cosmosAccount']}/overview", [n["cosmosAccount"]]),
 ("03-foundry-iam", "3", "Foundry: Access control (IAM) - role assignments", f"/resource{fid}/overview", ["Cognitive Services User"]),
 ("03-storage-iam", "3", "Storage account: Access control (IAM) - role assignments", f"/resource{R}/providers/Microsoft.Storage/storageAccounts/{n['apps']['resolver']['storageAccount']}/overview", ["Storage Blob Data Owner"]),
 ("05-function-settings", "5", "Function App: Environment variables (names only)", f"/resource{site('sync')}/environmentVariablesAppSettings", ["COSMOS_ENDPOINT"]),
 ("05-resolver-auth", "5", "Resolver: Authentication - require authentication", f"/resource{site('resolver')}/overview", ["Require authentication"]),
 ("05-apim-apis", "5", "API Management: APIs - Claude Messages", f"/resource{apim}/apim-apis", [cfg["apim"]["apiDisplayName"]]),
 ("07-functions-list", "7", "Function App: functions after publishing", f"/resource{site('resolver')}/functionsList", ["resolve"]),
]
if "4" in S:
    s5 = S["4"]["outputs"]  # Entra (Stage 4 in the network-last order)
    gw = s5["registrations"]["gatewayApi"]["appId"]
    steps.append(("04-gateway-expose-api", "4", "Entra: gateway app - Expose an API", f"/view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/ProtectAnAPI/appId/{gw}", ["access_as_user"]))
    if s5.get("admin", {}).get("appId"):
        steps.append(("04-admin-roles", "4", "Entra: admin app - App roles", f"/view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/AppRoles/appId/{s5['admin']['appId']}", ["CCOF.Projects.Write"]))
    for key, g in list(s5["groups"].items())[:1]:
        steps.append(("04-group-members", "4", f"Entra: group {g['displayName']} - Members", f"/view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/{g['id']}", ["Members"]))
# These blades have no stable deep link: the walker opens the overview, then the named menu entry.
# IAM blades open on "Check access"; the role assignments are on another tab.
MENU = {"01-apim-identity": "Managed identities", "06-foundry-networking": "Networking", "06-apim-network": "Network",
        "06-dns-links": "Virtual network links", "05-resolver-auth": "Authentication", "03-foundry-iam": "Access control (IAM)", "03-storage-iam": "Access control (IAM)"}
CLICK = {"03-foundry-iam": "Role assignments", "03-storage-iam": "Role assignments"}
# Shared resource groups and subscriptions hold long, virtualized lists: filter to this deployment's rows.
FILTER = {"01-rg-overview": {"placeholder": "Filter for any field...", "text": n["cosmosAccount"]},
          "03-foundry-iam": {"placeholder": "Search by name or email", "text": s1["apimName"]},
          "03-storage-iam": {"placeholder": "Search by name or email", "text": n["apps"]["resolver"]["functionApp"]}}
def extra(i):
    return {**({"menu": MENU[i]} if i in MENU else {}), **({"click": CLICK[i]} if i in CLICK else {}), **({"filter": FILTER[i]} if i in FILTER else {})}
json.dump([{"id": i, "guideStep": g, "title": t, "url": u, "expect": e, "wait": 30000, **extra(i)} for i, g, t, u, e in steps], open(out, "w", encoding="utf-8"), indent=1)
print(len(steps), "steps")
