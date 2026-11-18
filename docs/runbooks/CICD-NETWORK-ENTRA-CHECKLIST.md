# Checklist: network and Entra teams (CI/CD deployment)

Print this page for each environment. The pipeline waits at a gate until a named approver signs off;
see [CICD-ENVIRONMENT-DEPLOYMENT.md](CICD-ENVIRONMENT-DEPLOYMENT.md) section 5. The pipeline never changes
the network outside its own private endpoints and never changes Entra.

Environment: ______________  Region A: East US 2  Region B: Central US  Date: ______________

## Part A. Network team (gate `<env>-gate-network`, then `<env>-gate-privatelink`)

Before the first run (checked by `Test-CicdPrerequisites.ps1`, area Network):

- [ ] Region A VNet and region B VNet exist; address spaces do not overlap.
- [ ] Subnet for API Management in each region: delegated to `Microsoft.Web/serverFarms`, /27 or larger, NSG attached
      ([API Management outbound VNet](https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound)).
- [ ] Subnet for Function Apps in each region: delegated to `Microsoft.App/environments`, /27 or larger
      ([Flex Consumption networking](https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to)).
- [ ] Subnet for private endpoints in each region: no delegation, /28 or larger.
- [ ] Private DNS zones exist and are linked to **both** VNets: `privatelink.documents.azure.com`,
      `privatelink.blob.core.windows.net`, `privatelink.services.ai.azure.com`,
      `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com`.
- [ ] Peering region A <-> region B is `Connected` in both directions, or the DR Bootstrap step may create it
      (approval `ExistingVnetUpdate` at gate network).
- [ ] The two runners (`ccof-preview`, `ccof-apply`) are in a subnet that resolves the private DNS zones.
- [ ] The subnet IDs and zone IDs are in `deploy/<env>/staged.config.json` (`network.existing`) and
      `dr-standby.config.json` (`primary`, `secondary`, `dnsZones`).

During the run:

- [ ] Stage 6 (`network.mode` `verify`): private endpoints for Cosmos DB and blob storage, and VNet integration
      of the four Function Apps, as listed by the Stage 6 preview. See [DEPLOYMENT-RUNBOOK.md](DEPLOYMENT-RUNBOOK.md).
- [ ] Standby Network (`PrivateNetworkChanges`): reviewed the preview in the job log before approving.
- [ ] DR 7.4: region B Function App private endpoints and `privatelink.azurewebsites.net` records created
      ([DR-STANDBY-CLOUD-SHELL.md](DR-STANDBY-CLOUD-SHELL.md)), before approving the handoff gate.
- [ ] Front Door private link: the connection IDs listed by the Approve preview match the expected Front Door
      profile; give them to the run as `fd_reviewed_ids` ([DR-FRONT-DOOR.md](DR-FRONT-DOOR.md)).

Signed (network team lead): ______________________

## Part B. Entra team (gate `<env>-gate-entra`)

The pipeline identity has no Graph write permission and needs none. Do not grant it Graph ReadWrite
permissions. Settings per application are printed by the Stage 4 preview job in its summary.

- [ ] Gateway, resolver and admin app registrations exist, each with its enterprise application
      (service principal). IDs in `entra.existing` (`gatewayAppId`, `resolverAppId`, `adminAppId`).
- [ ] Gateway: Application ID URI `api://<gatewayAppId>`; scope `access_as_user`; public client flows on;
      redirect URIs as printed; `requestedAccessTokenVersion` 2.
- [ ] Resolver: Application ID URI `api://<resolverAppId>`; `requestedAccessTokenVersion` 2.
- [ ] Admin: scope `Projects.Manage`; app roles `CCOF.Projects.Read`, `CCOF.Projects.Write`; single-page
      application redirect URIs for the admin Function App; assignment required; editors and readers assigned.
- [ ] Security groups exist for each project and classification; object IDs in `groups[].groupId`;
      group owners add members (the pipeline adds none).
- [ ] Region B (DR 7.3): single-page application redirect URIs `https://<region B admin host>/api/console` and
      `/api/console-v3` added to the admin app, as printed by the standby Config step ("manual Entra handoff
      (pipeline)"). The pipeline always hands these over and makes no Graph call, even when the primary's
      Stage 4 was verified through Graph.
- [ ] `entra.manualVerification` committed with `confirmedBy` (name) and `confirmedOn` (yyyy-MM-dd).

Reference: [DEPLOYMENT-RUNBOOK.md](DEPLOYMENT-RUNBOOK.md), [Staged.Entra.ps1](../../infra/staged/Staged.Entra.ps1)
(`Invoke-StgStage4Manual`).

Signed (Entra team lead): ______________________
