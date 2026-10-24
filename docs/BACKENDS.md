# Backend connectivity options

Each request goes to the backend registered for its project (ADR-0002 decision 4). This page compares
the ways the gateway can reach Claude:
- in the gateway's own Entra tenant;
- in another tenant;
- on other providers.

All rows were researched on 2026-10-11 from the primary sources cited. The decision record is
ADR-0007 (internal record, not published) (Proposed).

## 1. Summary

| # | Backend | Dialect on the wire | Gateway → backend authentication | Secretless | Streaming | Billed figure for reconciliation (ADR-0005) | Gateway effort | State |
|---|---|---|---|---|---|---|---|---|
| 1 | Foundry in the gateway's tenant, any subscription | Anthropic Messages (`/anthropic/v1/messages`) | APIM managed identity, with Cognitive Services User on each account | Yes | SSE | Azure Cost Management, CCU per subscription | Policy `authentication-managed-identity` | Target of the E2E (WP-MI). Managed identity is confirmed same-tenant only (U-9) |
| 2a | Foundry in another tenant: managed identity as a federated credential on a multi-tenant app | Anthropic Messages | APIM managed-identity token for `api://AzureADTokenExchange`, used as a client assertion at tenant B's token endpoint | Yes | SSE | Tenant B's Cost Management | Two-step token chain in policy; no official sample | Blocked in the PoC backend tenant, which refuses multi-tenant apps |
| 2b | Foundry in another tenant: single-tenant app with a certificate | Anthropic Messages | Client assertion signed with a certificate | No shared secret, but a private key to protect | SSE | Tenant B's Cost Management | APIM cannot sign the assertion itself; needs a token broker (for example a Function with Key Vault) | Not built |
| 2c | Foundry in another tenant: single-tenant app with a client secret | Anthropic Messages | Client credentials, with the secret in an APIM named value | No | SSE | Tenant B's Cost Management | Built | Live in the PoC: 7-day secret cap, rotation open (U-10) |
| — | Azure Lighthouse | — | — | — | — | — | — | Not applicable: "Roles with DataActions permission aren't supported" |
| 3 | Anthropic API (first party) | Anthropic Messages (`/v1/messages`) | Workload Identity Federation: an Entra-issued token exchanged at `POST /v1/oauth/token` for a short-lived access token; or an API key | Yes, with federation | SSE | Admin Usage and Cost API: cache 5 min and 1 h split, per workspace, daily cost buckets | Low | Not built |
| 4 | Claude Platform on AWS | Anthropic Messages (`/v1/...`) | SigV4, or an API key sent as a bearer token | Not stated; temporary STS credentials with SigV4 are an option | SSE | AWS Marketplace CCU, aggregated (breakdown in the Claude Console) | Medium | Not built |
| 5 | Google Vertex AI | Vertex `rawPredict` / `streamRawPredict`: `anthropic_version` in the body, model in the URL | Workload Identity Federation with Entra as the identity provider → Google STS → direct access or service-account impersonation | Yes | SSE | Cloud Billing export at SKU level, with no token-type split | High: passthrough API, and clients switch dialect | Not built |
| 6 | Amazon Bedrock | Bedrock `InvokeModel` / `Converse`: `anthropic_version: bedrock-2023-05-31` | SigV4 with IAM keys; Bedrock API keys (short-term, up to 12 h); or STS `AssumeRoleWithWebIdentity` with an Entra OIDC token (1-12 h sessions) | Only with STS web identity | AWS event stream (binary), not SSE | AWS Cost and Usage Report / Cost Explorer, by model and token type | High: SigV4 in policy (Microsoft's sample stores IAM keys), APIM token policies do not cover Bedrock, and clients switch dialect | Not built |

Sources:
- **Rows 1-2:** [managed identity as a federated credential][fic] ("Accessing resources in another tenant is
  supported"); its general availability ([GA][fic-ga]); [Lighthouse roles][lighthouse]; [APIM
  credential manager][credmgr] (federated credentials only with the authorization-code grant); [app
  management policies][app-policy].
- **Row 3:** Anthropic [workload identity federation][a-wif] (Entra ID is a supported issuer; token
  lifetime 60-86,400 s, default 3,600), [API overview][a-api], [cost report][a-cost] (`token_type` values
  include `cache_creation.ephemeral_1h_input_tokens`, `cache_creation.ephemeral_5m_input_tokens`,
  `cache_read_input_tokens`).
- **Row 4:** [Claude Platform on AWS][cp-aws] and its [authentication][cp-aws-auth]
  (`aws-external-anthropic:CallWithBearerToken`); Anthropic [pricing][pricing] ("AWS Cost Explorer shows
  aggregated CCU").
- **Row 5:** Anthropic [Claude on Vertex AI][a-vertex] ("model is not passed in the request body"; the
  body carries `anthropic_version`), Google [workload identity federation with other clouds][g-wif],
  [standard billing export][g-billing].
- **Row 6:** AWS [InvokeModelWithResponseStream][b-stream], [Bedrock API keys][b-keys],
  [AssumeRoleWithWebIdentity][b-sts]; Microsoft Learn [Bedrock passthrough API][b-apim].

## 2. What the differences mean

- **The dialect is visible to clients.** Claude Code chooses its wire format from its settings:
  - `ANTHROPIC_BASE_URL` for Anthropic Messages;
  - `CLAUDE_CODE_USE_BEDROCK` with `ANTHROPIC_BEDROCK_BASE_URL`;
  - `CLAUDE_CODE_USE_VERTEX` with `ANTHROPIC_VERTEX_BASE_URL` ([env-vars][cc-env]).

  "When the client speaks the Amazon Bedrock or Google Cloud's Agent Platform format, Claude Code sends
  only the subset of its full capability set that those providers accept" ([gateway protocol][cc-gw]).
  A project on a Bedrock or Vertex backend therefore needs different client settings. Moving a project
  between dialects means reconfiguring every member's client.
- **Gateway features follow the dialect.** APIM's `llm-token-limit` and `llm-emit-token-metric` support
  "OpenAI Chat Completions or Responses API, Anthropic Messages API (currently supported in API Management
  v2 tiers), Google Vertex AI API" ([AI gateway capabilities][apim-genai]); Bedrock is not listed.
- **Streaming must pass through unbuffered.** "If your gateway buffers a response until it is complete,
  Claude Code stalls" ([gateway protocol][cc-gw]). Bedrock's binary event stream is a different format
  from SSE, so per-request cache categories (U-17) need a parser per format.
- **Reconciliation needs one adapter per billed source.** ADR-0005's daily reconciliation compares the
  ledger with what each provider bills:
  - Azure Cost Management: CCU.
  - AWS: the Cost and Usage Report for Bedrock (by model and token type), or aggregated CCU for Claude
    Platform on AWS.
  - Google Cloud Billing export: SKU level.
  - Anthropic Cost Report: by token type and workspace, daily.
- **Prompt-cache scope differs.** "Bedrock and Google Cloud maintain organization-level cache isolation"
  ([prompt caching][a-cache]).
- **Geography:** "On Amazon Bedrock and Google Cloud, the inference region is determined by the endpoint
  URL or inference profile, so `inference_geo` is not applicable" ([data residency][a-geo]). The pricing
  multiplier for those backends therefore comes from the backend's registration, not from the response.

## 3. Registry and onboarding changes

Each `backendId` gets a backend descriptor:
- provider;
- tenant relationship (same or other);
- authentication mode;
- dialect;
- region or endpoint type (global, data zone, regional);
- billed-figure source;
- failover pool membership (`docs/AVAILABILITY.md`).

Stage 2 (backend registration) asks the admin for each of these and records the answers. Stage 4 output
tells each member the client settings for their project's dialect.

## 4. What another tenant must allow

| Option | Tenant B prerequisites |
|---|---|
| 2a | The "Block multitenant applications" app-management policy is not in force; an administrator provisions the app's service principal (admin consent) and grants it Cognitive Services User on the account; Azure Policy does not block federated identity credentials ([blocking FICs][fic-block]) |
| 2b | A certificate lifetime allowed by any `asymmetricKeyLifetime` restriction ([app management policies][app-policy]) |
| 2c | A secret lifetime allowed by any `passwordLifetime` restriction (7 days in the PoC backend tenant) |
| All | The private endpoint connection is approved by the resource owner ("If you don't have approval permissions, the private endpoint connection stays in a Pending state until the resource owner approves it" — [Foundry private link][foundry-pl]) |

[fic]: https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity
[fic-ga]: https://devblogs.microsoft.com/identity/access-cloud-resources-across-tenants-without-secrets-ga
[fic-block]: https://learn.microsoft.com/entra/workload-id/workload-identity-federation-block-using-azure-policy
[lighthouse]: https://learn.microsoft.com/azure/lighthouse/concepts/tenants-users-roles
[credmgr]: https://learn.microsoft.com/azure/api-management/credentials-configure-common-providers
[app-policy]: https://learn.microsoft.com/entra/identity/enterprise-apps/configure-app-management-policies
[foundry-pl]: https://learn.microsoft.com/azure/foundry/how-to/configure-private-link
[a-wif]: https://platform.claude.com/docs/en/manage-claude/workload-identity-federation
[a-api]: https://platform.claude.com/docs/en/api/overview
[a-cost]: https://platform.claude.com/docs/en/api/beta/organization/cost_report/retrieve
[a-vertex]: https://platform.claude.com/docs/en/build-with-claude/claude-on-vertex-ai
[a-cache]: https://platform.claude.com/docs/en/build-with-claude/prompt-caching
[a-geo]: https://platform.claude.com/docs/en/manage-claude/data-residency
[pricing]: https://platform.claude.com/docs/en/about-claude/pricing
[cp-aws]: https://docs.aws.amazon.com/claude-platform/latest/userguide/welcome.html
[cp-aws-auth]: https://docs.aws.amazon.com/claude-platform/latest/userguide/authentication.html
[g-wif]: https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds
[g-billing]: https://docs.cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/standard-usage
[b-stream]: https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModelWithResponseStream.html
[b-keys]: https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html
[b-sts]: https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html
[b-apim]: https://learn.microsoft.com/azure/api-management/amazon-bedrock-passthrough-llm-api
[apim-genai]: https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities
[cc-env]: https://code.claude.com/docs/en/env-vars
[cc-gw]: https://code.claude.com/docs/en/llm-gateway-protocol
