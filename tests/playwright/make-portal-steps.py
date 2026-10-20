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
 ("00-subscription-access", "0", "Subscription: Access control (IAM) - view my access", f"/resource/subscriptions/{sub}/users", ["Access control"]),
 ("01-rg-overview", "1", "Resource group overview: the deployed resources", f"/resource{R}/overview", [n["cosmosAccount"], s1["apimName"]]),
 ("01-rg-deployments", "1", "Resource group: Deployments (stage1-services ... stage6-config)", f"/resource{R}/deployments", ["stage1-services"]),
 ("01-apim-overview", "1", "API Management overview: Standard v2", f"/resource{apim}/overview", ["Standard v2"]),
 ("01-apim-identity", "1", "API Management: Managed identities - system assigned", f"/resource{apim}/managedidentities", ["System assigned"]),
 ("01-foundry-overview", "Foundry", "Foundry account overview", f"/resource{fid}/overview", [fd]),
 ("02-foundry-networking", "Foundry/2", "Foundry: Networking - public access disabled, private endpoint", f"/resource{fid}/networking", ["Private endpoint"]),
 ("02-apim-network", "2", "API Management: Network - outbound VNet integration", f"/resource{apim}/virtualNetwork", ["snet-apim"]),
 ("02-function-networking", "2", "Function App: Networking - VNet integration", f"/resource{site('resolver')}/networkingHub", ["snet-functions"]),
 ("02-dns-links", "2", "Private DNS zone: Virtual network links", f"/resource{R}/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com/virtualNetworkLinks", [cfg["network"]["create"]["vnetName"]]),
 ("03-cosmos-overview", "3", "Cosmos DB account overview (private)", f"/resource{R}/providers/Microsoft.DocumentDB/databaseAccounts/{n['cosmosAccount']}/overview", [n["cosmosAccount"]]),
 ("04-foundry-iam", "4", "Foundry: Access control (IAM) - role assignments", f"/resource{fid}/users", ["Cognitive Services User"]),
 ("04-storage-iam", "4", "Storage account: Access control (IAM) - role assignments", f"/resource{R}/providers/Microsoft.Storage/storageAccounts/{n['apps']['resolver']['storageAccount']}/users", ["Storage Blob Data Owner"]),
 ("06-function-settings", "6", "Function App: Environment variables (names only)", f"/resource{site('sync')}/environmentVariablesAppSettings", ["COSMOS_ENDPOINT"]),
 ("06-resolver-auth", "6", "Resolver: Authentication - require authentication", f"/resource{site('resolver')}/authV2", ["Microsoft"]),
 ("06-apim-apis", "6", "API Management: APIs - Claude Messages", f"/resource{apim}/apim-apis", [cfg["apim"]["apiDisplayName"]]),
 ("07-functions-list", "7", "Function App: functions after publishing", f"/resource{site('resolver')}/functionsList", ["resolve"]),
]
if "5" in S:
    s5 = S["5"]["outputs"]
    gw = s5["registrations"]["gatewayApi"]["appId"]
    steps.append(("05-gateway-expose-api", "5", "Entra: gateway app - Expose an API", f"/view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/ProtectAnAPI/appId/{gw}", ["access_as_user"]))
    if s5.get("admin", {}).get("appId"):
        steps.append(("05-admin-roles", "5", "Entra: admin app - App roles", f"/view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/AppRoles/appId/{s5['admin']['appId']}", ["CCOF.Projects.Write"]))
    for key, g in list(s5["groups"].items())[:1]:
        steps.append(("05-group-members", "5", f"Entra: group {g['displayName']} - Members", f"/view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/{g['id']}", ["Members"]))
json.dump([{"id": i, "guideStep": g, "title": t, "url": u, "expect": e, "wait": 30000} for i, g, t, u, e in steps], open(out, "w", encoding="utf-8"), indent=1)
print(len(steps), "steps")
