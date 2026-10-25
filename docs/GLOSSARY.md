# Glossary

Terms used across the CCOF documentation, in alphabetical order. Microsoft Learn links give the
product definition; repository links give the CCOF-specific use.

| Term | Meaning in CCOF |
| --- | --- |
| **Admin console** | Web pages served by the admin Function App (`/api/console-v3`) for projects, limits, budgets, chargeback and audit. See [admin operations](runbooks/ADMIN-OPERATIONS.md). |
| **AMPLS** | Azure Monitor Private Link Scope: connects private endpoints to Log Analytics workspaces ([Learn](https://learn.microsoft.com/azure/azure-monitor/logs/private-link-security)). Used only in the DR design. |
| **APIM** | Azure API Management, the gateway in front of Claude. It checks the developer's token, applies limits and forwards the request to Foundry ([Learn](https://learn.microsoft.com/azure/api-management/api-management-key-concepts)). |
| **App registration** | An application object in Microsoft Entra ID. CCOF uses one for the gateway/developer sign-in, one for the resolver and one for the admin console ([deployment runbook](runbooks/DEPLOYMENT-RUNBOOK.md#app-registrations)). |
| **Backend** | One Foundry account (and its model deployments) that APIM can send requests to. Each project names one primary backend. |
| **Backend pool / circuit breaker** | An APIM feature: a pool lists several backends in priority order; a circuit breaker stops sending to a backend for a set time after failures ([Learn](https://learn.microsoft.com/azure/api-management/backends)). In CCOF it is optional per project ([ADR 0034](adr/0034-dr-project-routing-and-prerequisites.md)). |
| **Budget** | A monthly spending amount, per person in a project or per access group, in USD or CCU. The reconciler compares spend with it. |
| **CCU** | Claude Consumption Unit, the single billing unit for Claude on Foundry; 1 CCU = USD 0.01 ([Learn](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/claude-models-billing)). |
| **Chargeback** | Reports of usage cost per project, group, person and model, at the approved list rate card. Not an Azure invoice ([chargeback](CHARGEBACK.md)). |
| **Classification** | A project's access tier, for example `STD`, `PRM` or `CYB`. Each classification has its own Entra group, allowed models and limits. |
| **Cosmos DB** | The registry database: projects, memberships (entitlements) and budget state ([Learn](https://learn.microsoft.com/azure/cosmos-db/introduction)). |
| **Delegated snapshot** | A sync mode where a signed-in operator reads the Entra groups and applies the result once, instead of the sync app reading them on a timer ([sync](SYNC.md)). |
| **Entitlement** | The record that a person may use a project at a classification, written by the sync app from Entra group membership. |
| **Exhausted** | Budget state when spend has reached the budget. The gateway refuses further requests with `budget_exhausted`. |
| **Family** | A group of Claude models with shared limits: Haiku, Sonnet, Opus, Fable, Mythos. |
| **Foundry** | Microsoft Foundry, the Azure service that hosts the Claude model deployments ([Learn](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure)). |
| **Front Door / WAF** | Azure Front Door is a global entry point; its Web Application Firewall filters requests ([Learn](https://learn.microsoft.com/azure/frontdoor/front-door-overview)). Used only in the DR design. |
| **Ledger** | The usage records in Log Analytics that the reconciler and chargeback read. One record per gateway request. |
| **Log Analytics** | The Azure Monitor workspace that holds gateway and Function logs ([Learn](https://learn.microsoft.com/azure/azure-monitor/logs/log-analytics-overview)). |
| **Managed identity** | An Azure-managed identity for a resource, so it can call other services without a secret. *System-assigned* belongs to one resource; *user-assigned* (UAMI) is a separate resource ([Learn](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview)). |
| **Pacing window** | Minutes over which the reconciler spreads a person's remaining budget when it sets the per-minute token limit. See [budgets and the soft limit](BUDGETS.md). |
| **Private endpoint (PE)** | A network interface in a customer subnet that gives private access to an Azure service ([Learn](https://learn.microsoft.com/azure/private-link/private-endpoint-overview)). |
| **Project** | A unit of access and cost: a name, its Entra groups per classification, allowed models, limits, budgets and backend. |
| **Rate card** | The approved price list (per model and token category) used to turn tokens into CCU (`config/rate-card.json`). |
| **Reconciler** | Function App that reads the ledger every few minutes, computes spend per person and group, and writes budget state ([ADR 0035](adr/0035-budget-soft-limit-and-spend-pacing.md)). |
| **Resolver** | Function App that APIM calls to look up a person's project, classification, allowed models, limits and backend. Only APIM's managed identity can call it. |
| **Soft limit** | A percentage of the budget (for example 80%). Past it, the developer sees a warning and requests are slowed. See [budgets and the soft limit](BUDGETS.md). |
| **Stage** | One step of the staged deployment (`infra/staged/Invoke-StagedDeployment.ps1`, stages 0-8). Each stage has a preview, an apply and a read-back ([staged deployment](runbooks/STAGED-DEPLOYMENT-V2.md)). |
| **Standard v2** | An API Management pricing tier with outbound virtual network integration and inbound private endpoints ([Learn](https://learn.microsoft.com/azure/api-management/v2-service-tiers-overview)). |
| **Sync** | Function App that copies Entra group membership into Cosmos entitlements ([sync](SYNC.md)). |
| **TPM** | Tokens per minute. APIM's `llm-token-limit` policy counts tokens per key and refuses requests past the limit with 429 ([Learn](https://learn.microsoft.com/azure/api-management/llm-token-limit-policy)). |
| **VNet integration** | Outbound connection from APIM or a Function App into a customer subnet, so it can reach private endpoints ([Learn](https://learn.microsoft.com/azure/app-service/overview-vnet-integration)). |
| **What-if** | An Azure Resource Manager preview of the changes a deployment would make ([Learn](https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-what-if)). |
