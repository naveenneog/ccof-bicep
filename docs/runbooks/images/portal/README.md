# Portal screenshot inventory

This public documentation includes **86 real, reviewed reference images**.

## Redaction and evidence boundary

Identifying values use opaque **middle-only** masks, retaining visible prefix/suffix context. Complete and clipped GUIDs, hashes, account/email labels, resource names and private address values were checked locally. Original unmasked captures, raw OCR text, customer values and browser profiles are not included. Credential-bearing screens are not selected. Prefix/suffix redaction is not an anonymity guarantee; do not copy image values into a deployment.

Images are historical creation forms, configured-resource references or navigation references, not a replay of every current step. A settings-name screenshot with hidden values is not configuration acceptance; an empty diagnostic list is explicitly before configuration; an operator Data Explorer denial is not evidence that the database is empty.

## Pending captures - not fabricated

Command-output images (`*-cli-middle-masked.png`) show the real lab output of a step's own
command or read-only check, rendered as text with the same middle-only masks. They stand in
where a Portal blade capture was not available; they are not Portal screenshots.

These slots keep their SVG placeholder, for the reason given:

| Slot | Why it is still pending |
|---|---|
| 01.1, 16.1 PIM activation | The lab tenant offers no eligible privileged role to activate |
| 04.2 data retention, 11.3 APIM system identity | Portal-only blades with no CLI check in the guide; the Portal capture session needs an interactive sign-in |
| 04.6 connection string | Credential-bearing screen; deliberately not captured |
| 11.2 APIM outbound VNet integration | Lab APIM tier does not support VNet integration |
| 12.1-12.5 resolver private inbound cutover | Not performed in the lab; doing so would remove the public test path. 12.5's check shows the pre-restriction state, so it is not used |
| 16.3 Graph permission grant | Requires a privileged directory role the lab operator does not hold; the 16.2 plan is shown instead |
| 20.5 workbook readers | No saved workbook resource in the lab yet |
| 21.2, 21.3 seed settings and registration | The lab seed already completed and was cleaned up; re-enabling it only for a picture would be an unnecessary write |
| 21.6, 21.7 timer enablement | The lab uses delegated-snapshot sync and token-limits-only mode, so these timers stay disabled |

## Included references

| Image | Kind | What is visible / limitation |
|---|---|---|
| [02-2-middle-masked.png](02-2-middle-masked.png) | creation-form | Historical resource-group creation form |
| [03-1-middle-masked.png](03-1-middle-masked.png) | historical-settings | Historical outbound Key Vault and Monitor rules; not a complete production egress policy |
| [03-2-middle-masked.png](03-2-middle-masked.png) | creation-form | Historical VNet creation form; use approved customer address space |
| [03-3-middle-masked.png](03-3-middle-masked.png) | historical-settings | Historical APIM subnet edit form; not proof of current APIM integration |
| [03-4-middle-masked.png](03-4-middle-masked.png) | historical-settings | Historical Functions subnet edit form |
| [03-5-middle-masked.png](03-5-middle-masked.png) | creation-form | Historical private-endpoint subnet form; endpoints are NICs, not the target PaaS services |
| [03-6-middle-masked.png](03-6-middle-masked.png) | creation-form | Historical private DNS zone creation form |
| [03-7-middle-masked.png](03-7-middle-masked.png) | creation-form | Historical DNS VNet link form; not a DNS resolution test |
| [03-8-middle-masked.png](03-8-middle-masked.png) | historical-settings | Historical subnet inventory; verify the actual caller network and approved egress |
| [04-1-middle-masked.png](04-1-middle-masked.png) | creation-form | Historical workspace creation form |
| [04-4-middle-masked.png](04-4-middle-masked.png) | creation-form | Historical resolver Application Insights form |
| [04-5-middle-masked.png](04-5-middle-masked.png) | creation-form | Historical sync Application Insights form |
| [05-1-middle-masked.png](05-1-middle-masked.png) | creation-form | Historical sync managed-identity creation form |
| [05-2-middle-masked.png](05-2-middle-masked.png) | creation-form | Historical reconciler managed-identity creation form |
| [06-4-middle-masked.png](06-4-middle-masked.png) | customer-ui-reference | Combined app Authentication reference; API exposure and redirects belong on that same gateway/developer registration |
| [06-7-middle-masked.png](06-7-middle-masked.png) | historical-settings | Group Members page showing one direct user; not entitlement or synchronization proof |
| [07-6-middle-masked.png](07-6-middle-masked.png) | historical-settings | Foundry IAM showing APIM identity Cognitive Services User; values are middle-masked |
| [08-1-middle-masked.png](08-1-middle-masked.png) | creation-form | Historical Cosmos basics form |
| [08-2-middle-masked.png](08-2-middle-masked.png) | historical-settings | Historical Cosmos private access showing an approved endpoint |
| [09-1-middle-masked.png](09-1-middle-masked.png) | creation-form | Historical storage creation form |
| [09-2-middle-masked.png](09-2-middle-masked.png) | creation-form | Historical blob private-endpoint form |
| [09-3-middle-masked.png](09-3-middle-masked.png) | historical-settings | Storage Containers navigation reference; review the actual deployment container |
| [10-2-middle-masked.png](10-2-middle-masked.png) | historical-settings | Resolver system-assigned identity On; no user credentials |
| [10-2-sync-middle-masked.png](10-2-sync-middle-masked.png) | historical-settings | Sync attached user-assigned identity reference |
| [10-3-middle-masked.png](10-3-middle-masked.png) | historical-settings | Sync deployment storage uses a user-assigned identity; visible access warning is not connectivity proof |
| [11-1-middle-masked.png](11-1-middle-masked.png) | creation-form | Historical APIM creation form; verify the actual SKU before private outbound integration |
| [15-1-middle-masked.png](15-1-middle-masked.png) | historical-settings | Storage IAM showing resolver Blob Data Owner; not queue/table role proof |
| [17-1-middle-masked.png](17-1-middle-masked.png) | historical-settings | Resolver environment-variable names; values are hidden |
| [17-1-sync-middle-masked.png](17-1-sync-middle-masked.png) | historical-settings | Sync environment-variable names; hidden values do not prove timers are disabled |
| [17-1-reconciler-middle-masked.png](17-1-reconciler-middle-masked.png) | historical-settings | Reconciler environment-variable names; values are hidden |
| [17-3-middle-masked.png](17-3-middle-masked.png) | historical-settings | Sync timer listed Disabled; not a successful sync run |
| [17-5-middle-masked.png](17-5-middle-masked.png) | historical-settings | Resolver requires authentication and returns anonymous 401; caller allow-lists still need verification |
| [18-3-middle-masked.png](18-3-middle-masked.png) | historical-settings | Resolver health and resolve HTTP functions; not inference acceptance |
| [18-3-reconciler-middle-masked.png](18-3-reconciler-middle-masked.png) | historical-settings | Reconciler timer listed Disabled before optional activation |
| [19-1-middle-masked.png](19-1-middle-masked.png) | historical-settings | APIM APIs inventory after creation; not a creation-form or operation view |
| [19-2-middle-masked.png](19-2-middle-masked.png) | historical-settings | Selected POST /v1/messages operation |
| [19-4-middle-masked.png](19-4-middle-masked.png) | customer-ui-reference | API Design navigation: select All operations before the inbound code editor |
| [20-1-middle-masked.png](20-1-middle-masked.png) | historical-gap | Diagnostic settings BEFORE configuration: no settings defined; not successful logging proof |
| [20-4-gallery-middle-masked.png](20-4-gallery-middle-masked.png) | archival-navigation | Archival workspace Workbooks gallery navigation; not the current report's content or saved-state proof |
| [21-4-middle-masked.png](21-4-middle-masked.png) | customer-ui-reference | Historical create-only seed result with two created documents; identifiers middle-masked, not another deployment's seed acceptance |
| [21-6-reader-middle-masked.png](21-6-reader-middle-masked.png) | customer-ui-reference | Data Explorer native data-role denial for the operator; this is not evidence that entitlement storage is empty |
| [22-2-middle-masked.png](22-2-middle-masked.png) | customer-ui-reference | VS Code User settings before gateway configuration; empty array is not a working sign-in |

`screenshots.json` records image hashes, masking counts and provenance categories. It contains no source capture path or unmasked field values.
| [13-1-cli-middle-masked.png](13-1-cli-middle-masked.png) | command-output | Step 13.1 check from the operator PowerShell 7 session: reviewed commit, Node and Azure CLI versions. Same commands as Cloud Shell; host was the operator workstation. |
| [14-1-cli-middle-masked.png](14-1-cli-middle-masked.png) | command-output | Step 14.1 dependency restore and npm ls on the reviewed commit. |
| [17-4-cli-middle-masked.png](17-4-cli-middle-masked.png) | command-output | Step 17.4 read-only check on the lab apps: only identity-based AzureWebJobsStorage__* settings remain; no key-based AzureWebJobsStorage. |
| [18-1-cli-middle-masked.png](18-1-cli-middle-masked.png) | command-output | Step 18.1 local resolver package build, SHA-256 and git-ignore check. No Azure call. |
| [18-2-cli-middle-masked.png](18-2-cli-middle-masked.png) | command-output | Step 18.2 function discovery after publish: resolver lists health and resolve. The upload itself is not re-run in this capture. |
| [21-1-cli-middle-masked.png](21-1-cli-middle-masked.png) | command-output | Step 21.1 CLI alternative against the lab sync Insights: earlier ccof.seed.result lines with outcome succeeded. |
| [21-5-cli-middle-masked.png](21-5-cli-middle-masked.png) | command-output | Step 21.5 read-only cleanup check on the lab sync app: payload absent and registrySeed disabled. |
| [22-1-cli-middle-masked.png](22-1-cli-middle-masked.png) | command-output | Step 22.1 client config validation on the lab config; values middle-masked. |
| [22-3-cli-middle-masked.png](22-3-cli-middle-masked.png) | command-output | Step 22.3 read-only checks: test developer group membership true; anonymous gateway request 401. Authorized-request evidence is not shown here. |
| [02-1-cli-middle-masked.png](02-1-cli-middle-masked.png) | command-output | Step 02.1 check: all nine required resource providers show Registered in the lab subscription. |
| [04-3-cli-middle-masked.png](04-3-cli-middle-masked.png) | command-output | Step 04.3 CLI alternative: workspace resource ID, Workspace ID (customerId) GUID and retention, middle-masked. |
| [05-3-cli-middle-masked.png](05-3-cli-middle-masked.png) | command-output | Step 05.3 CLI alternative: sync and reconciler identity client, principal and resource IDs, middle-masked. |
| [06-1-cli-middle-masked.png](06-1-cli-middle-masked.png) | command-output | Step 06.1 check: combined gateway registration is single-tenant (AzureADMyOrg) and has a service principal. |
| [06-2-cli-middle-masked.png](06-2-cli-middle-masked.png) | command-output | Step 06.2 check: gateway Application ID URI and access token version 2. |
| [06-3-cli-middle-masked.png](06-3-cli-middle-masked.png) | command-output | Step 06.3 check: enabled access_as_user scope on the gateway registration. |
| [06-5-cli-middle-masked.png](06-5-cli-middle-masked.png) | command-output | Step 06.5 check: separate resolver API registration with api:// URI, token version 2, no scopes and no redirects. |
| [06-6-cli-middle-masked.png](06-6-cli-middle-masked.png) | command-output | Step 06.6 check: lab classification group is a security group, not mail-enabled. |
| [07-1-cli-middle-masked.png](07-1-cli-middle-masked.png) | command-output | Step 07.1 check on a shared lab Foundry account: deployment list including the Claude deployments. Other models on that shared account are not part of this design. |
| [07-2-cli-middle-masked.png](07-2-cli-middle-masked.png) | command-output | Step 07.2 CLI alternative: Foundry account ID, custom subdomain and public network access, middle-masked. |
| [08-3-cli-middle-masked.png](08-3-cli-middle-masked.png) | command-output | Step 08.3 check: the Cosmos SQL database exists (ARM ID middle-masked). |
| [08-4-cli-middle-masked.png](08-4-cli-middle-masked.png) | command-output | Step 08.4 check: the eight containers with their partition key paths. |
| [10-1-cli-middle-masked.png](10-1-cli-middle-masked.png) | command-output | Step 10.1 check: resolver Flex app Running, Node 22, functions subnet, scale settings and system-assigned identity. |
| [10-4-cli-middle-masked.png](10-4-cli-middle-masked.png) | command-output | Step 10.4 check: resolver ID, default host name and principal ID, middle-masked. |
| [11-4-cli-middle-masked.png](11-4-cli-middle-masked.png) | command-output | Step 11.4 CLI alternative: APIM managed-identity client ID read from its service principal, middle-masked. |
| [19-3-cli-middle-masked.png](19-3-cli-middle-masked.png) | command-output | Step 19.3 check: one Foundry backend with HTTPS /anthropic URL and certificate chain/name validation True. |
| [07-3-cli-middle-masked.png](07-3-cli-middle-masked.png) | command-output | Step 07.3 check on the lab private Foundry endpoint: provisioning Succeeded, connection Approved. |
| [07-4-cli-middle-masked.png](07-4-cli-middle-masked.png) | command-output | Step 07.4 check from the Foundry account side: private endpoint connections Approved. |
| [07-5-cli-middle-masked.png](07-5-cli-middle-masked.png) | command-output | Step 07.5 check: Foundry private endpoint zone group with its privatelink.services.ai.azure.com record. |
| [12-6-cli-middle-masked.png](12-6-cli-middle-masked.png) | command-output | Step 12.6 private endpoint status listing in the lab: storage, Cosmos and Foundry endpoints Approved. The lab has no resolver inbound endpoint, and DNS resolution from caller networks is not shown. |
| [13-2-cli-middle-masked.png](13-2-cli-middle-masked.png) | command-output | Step 13.2: private form and evidence copied from the templates and confirmed git-ignored by the .env.* rule. |
| [13-3-cli-middle-masked.png](13-3-cli-middle-masked.png) | command-output | Step 13.3 result: key lines of the filled private lab form, values middle-masked. The editing itself happens in an editor. |
| [13-4-cli-middle-masked.png](13-4-cli-middle-masked.png) | command-output | Step 13.4: form compiled with az bicep build-params; tenant and subscription confirmed, middle-masked. |
| [13-5-cli-middle-masked.png](13-5-cli-middle-masked.png) | command-output | Step 13.5: helpers loaded, Bicep CLI present, functions subnet resolved. |
| [13-6-cli-middle-masked.png](13-6-cli-middle-masked.png) | command-output | Step 13.6: evidence filled from read-only Azure reads; no placeholders remain and the form compiles. |
| [14-2-cli-middle-masked.png](14-2-cli-middle-masked.png) | command-output | Step 14.2: artifacts exported locally (policy, settings, registry, seed, workbook); all nine present and git-ignored. No Azure write. |
| [14-3-cli-middle-masked.png](14-3-cli-middle-masked.png) | command-output | Step 14.3 review aid: exported artifact list and the registry's admitted families and quota for the lab classification. |
| [15-2-cli-middle-masked.png](15-2-cli-middle-masked.png) | command-output | Step 15.2 read-only access plan for the resolver: Cosmos reader, Storage Blob Data Owner, Monitoring Metrics Publisher. The scope column is truncated by console width. |
| [15-3-cli-middle-masked.png](15-3-cli-middle-masked.png) | command-output | Step 15.3 apply on the lab resolver: all three assignments already existed, receipt verified, nothing else changed. |
| [17-2-cli-middle-masked.png](17-2-cli-middle-masked.png) | command-output | Step 17.2 read-only check: every exporter-generated resolver setting matches the live app. |
| [01-2-cli-middle-masked.png](01-2-cli-middle-masked.png) | command-output | Step 01.2 check: the operator's effective roles at the lab resource-group scope, including inherited ones. |
| [16-2-cli-middle-masked.png](16-2-cli-middle-masked.png) | command-output | Step 16.2 read-only Graph permission plan for the sync identity: the three application permissions are still to grant. Nothing was granted. |
| [20-2-cli-middle-masked.png](20-2-cli-middle-masked.png) | command-output | Step 20.2 applied in the lab, then read back: API diagnostics with LLM logs enabled, request and response bodies off, client IP not logged. |
| [20-3-cli-middle-masked.png](20-3-cli-middle-masked.png) | command-output | Step 20.3 applied in the lab, then read back: FunctionAppLogs diagnostic setting on each app. One extra setting was created by a tenant policy. |
| [20-6-cli-middle-masked.png](20-6-cli-middle-masked.png) | command-output | Step 20.6 lab check: ApiManagementGatewayLogs and ApiManagementGatewayLlmLog now return rows. The only traffic was anonymous 401 test requests, with no authorized inference. FunctionAppLogs rows had not been ingested yet. |
