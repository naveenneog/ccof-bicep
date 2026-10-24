# Developer self-service usage (`/usage`)

A developer can see their own CCOF budget for the month: spend, budget and remaining amount per
project, as of the last reconciler run. This adds no Azure resource, Entra application or permission.

## What a developer sees

In Claude Code, `/usage` (with the skill installed) or `ccof-usage` in a terminal prints:

```text
CCOF budget (this month, your own use)
  PILOT1 / STD: $42.10 of $100.00 used (42.1%), $57.89 left, as of 2026-10-23 09:55 UTC
  Figures at the approved rate card (100 CCU = USD 1); usage not yet priced is not included.
```

Flags appear when the budget is exhausted, the figures are older than the reconciler's freshness
window, or some usage is not yet priced. When the reconciler paces spend
([ADR 0035](adr/0035-budget-soft-limit-and-spend-pacing.md)), a project past the soft limit shows:

```text
  PILOT1 / STD: $85.00 of $100.00 used (85.0%), $15.00 left, as of 2026-10-24 09:55 UTC [WARNING: past the 80% soft limit, requests are slowed until the budget resets]
```

`ccof-usage --json` prints the API response.

Claude Code's built-in session screen stays available as `/cost`. A project skill named `usage`
replaces the built-in `/usage` in a local terminal session
([Claude Code skills](https://code.claude.com/docs/en/slash-commands)).

## How it works

| Part | Change | Source |
| --- | --- | --- |
| Gateway (APIM) | A separate API `<apiId>-usage` at path `ccof-usage`, one operation `GET /me/usage`. Its policy checks the token exactly as the Claude Messages policy does (same `validate-jwt`, `oid`, scope and client checks), refuses a failed check with 403 before any other step, rate-limits per person with its own counter, and calls the resolver with APIM's managed identity. The person is the token's `oid`; nothing from the request reaches the resolver. It never calls a model backend. | `infra/gateway/policy/my-usage.template.xml`, rendered by `infra/gateway/render.ts` to `<apiId>.usage.policy.xml`; `infra/quickstart/modules/apim-api.bicep` (created only when that policy is supplied) |
| Resolver Function App | Route `POST /api/me/usage`, body exactly `{"personId": "<GUID>"}`. Behind the same App Service Authentication gate as `/api/resolve`, which admits only APIM's managed identity (ADR-0009). Reads the person's entitlement and, for each active membership, the reconciler's `budgetState` document. Read-only. | `src/resolver/my-usage.ts`, `src/resolver/http-handler.ts` (`handleMyUsageRequest`), `src/resolver/function-app.ts` |
| Client | `ccof-usage` uses the existing CCOF sign-in (`ccof-token`) and calls `<gateway origin>/ccof-usage/me/usage`. `CCOF_USAGE_URL` overrides the URL (https only). The Claude Code skill runs it. No figures are written to disk. | `client/bin/ccof-usage.mjs`, `client/src/usage.mjs`, `client/skills/usage/SKILL.md` |

Response (`schema: "ccof.usage.me.v1"`): per project `spentCcu`, `budgetCcu`, `remainingCcu`, the
USD equivalents (100 CCU = USD 1, rounded down to cents), `percentUsed`, `exhausted`, `period`,
`computedAt`, `stale` (the document's `validUntil` has passed), `completeness`, `softLimitPercent` and
`softLimitReached` (both null unless the reconciler paces spend), and `state`:
`available`, `no_budget_state` (the reconciler has not reported this person and project yet) or
`invalid`. Amounts stay exact decimal strings.

## Deployment

| Path | What deploys it |
| --- | --- |
| Staged deployment | Stage 5 renders and deploys the usage API with the main policy; Stage 7 publishes the resolver with the new route. |
| Quickstart, Portal and manual paths | Not wired yet: they deploy only the Claude Messages API. The usage API can be added with `infra/quickstart/modules/apim-api.bicep` and its `usagePolicyXml` parameter. |

Permissions: none new. The resolver's Cosmos DB Built-in Data Reader at database scope already covers
`entitlement` and `budgetState`; APIM already holds the resolver token audience.

## Limits

- Figures are as current as the last reconciler run; requests not yet priced are not included.
- A developer sees only their own figures. Group totals are not returned.
- Usage checks count against a per-person limit (the same calls/period as the Claude Messages
  admission, with a separate counter).
- In budget-enforcement mode `token-limits-only`, the reconciler writes no budget documents, so every
  project shows `no_budget_state`.

## Tests

`tests/resolver-my-usage.test.ts`, `tests/gateway-render.test.ts` (own-usage section) and
`client/test/usage.test.mjs`. Mutation checks: the request-shape check, GUID check, active-membership
filter, remaining-amount floor, decimal-string check, the token-`oid`-only body and the 403 refusal
branch each fail their named test when broken.

## Live verification (SASET, 23 October 2026)

63 streamed `claude-sonnet-5` calls through the SASET gateway as one developer (project SASLAB1/STD),
recorded independently by a load script from each response's `usage` (3,465 input and 1,008,000
output tokens, no cache), priced at rate card 2026-10-11:

| Source | Spent |
| --- | --- |
| Load script (sum of responses) + baseline 0.0656 CCU | 1,008.6930 + 0.0656 = **1,008.7586 CCU** |
| `/usage` (`GET /ccof-usage/me/usage`), computedAt 13:30 UTC | **1,008.7586 CCU** ($10.08) |
| Admin console, Reconciler person snapshot | **1,008.7586 CCU** |
| Admin console, Chargeback Developers | **1,008.7586 CCU** ($10.087586) |

All four agree exactly. A comparison taken one minute after the last call showed lower figures in all
three CCOF views, because Log Analytics ingestion and the 2-minute reconciler run had not caught up;
nine minutes later they matched. `completeness: partial` reflects 28 requests the gateway logged with
no usage: Foundry 429 rate-limit refusals (`UserByModelByMinuteOutputTokens`), which cost nothing.

Contoso (no model access): a valid token returns 200 with only the caller's project
(`no_budget_state`); no token and an Azure Resource Manager token both return 401.
