# Permissions and identities

Every identity this design needs, what it needs, who in the customer's tenant must grant it, and how
much friction that grant involves. Two items here are genuinely unconfirmable from this design
session — they need the customer's tenant admin to check, not an assumption.

The people who perform each deployment step, and the role each needs, are in
`docs/DEPLOYMENT-GUIDE.md` under "People and roles" and "Deployment workbook".

## The table

| # | Identity | What it does | Needs | Type | Who grants it | Friction |
|---|---|---|---|---|---|---|
| 1 | Developer's own sign-in (Claude Code / VS Code / Desktop) | Authenticates to the gateway; self-checks their own group membership for fast-path key issuance | `openid`, `profile`, `User.Read`, and reading their own `memberOf` | Microsoft Graph **delegated** | Standard OIDC consent | **None** — already required for sign-in today |
| 2 | Periodic sync job (bulk, unattended; §4 "slow path"). Proof of concept: user-assigned identity `sample-pilot-sync-id` | Enumerates full membership of every registered classification group, for drift-correction and removals | `GroupMember.Read.All` (or `Group.Read.All`) | Microsoft Graph **application** | Privileged Role Administrator, the least privileged role for Microsoft Graph app roles, or Global Administrator. Procedure: `docs/DEPLOYMENT-GUIDE.md`, Step 7 | **High** — see "What to actually go check" below |
| 3 | Change-notification subscription (fast path, both directions) | Subscribes to group-membership changes, delivered to a webhook/Event Grid endpoint | `Group.Read.All` — the subscription API accepts `Group.Read.All`, not `GroupMember.Read.All`, for group resources (MS Learn, retrieved 2026-10-11) | Microsoft Graph application | Same admin as #2 | Same as #2 if #2 is granted as `Group.Read.All`; confirm app-only Graph subscriptions aren't blocked by a Conditional Access policy. At most 100 subscriptions per app per tenant, so one subscription on `/groups`, not one per group (`docs/MARKETPLACE-COST.md` §9, U-24) |
| 4 | Project onboarding (Stage 3, `docs/CHECKPOINT-SETUP.md`) | Writes `projects`/`subscriptionIndex` in Cosmos; resolves a group id to its display name to confirm it | A scoped Cosmos write role; `Group.Read.All` **delegated**, covered by the operator's own Groups Administrator sign-in | Azure RBAC (Cosmos) + Graph delegated | Resource-group Owner (one-time, Stage 0) + the operator's own directory role | Low |
| 5 | Backend registration (Stage 2) | Creates the private endpoint, approves the connection, registers the APIM Backend entity | Contributor, scoped to the designated subscription's resource group | Azure RBAC | That subscription's own Owner | Low — the real friction is organisational (needs a different person per subscription), not technical |
| 6 | Tenant bootstrap (Stage 0, once per tenant) | Creates the custom roles every other identity in this table uses | User Access Administrator or Owner | Azure RBAC | A platform/security lead, once | Medium — the single highest-privilege step in the whole design, but one-time |
| 7 | Reconciler | Reads Log Analytics; reads billed CCU for each designated subscription (Cost Details API, ADR-0005); writes `budgetState` | Log Analytics Reader; **Cost Management Reader on each designated subscription**; a scoped Cosmos write role | Azure RBAC | Resource-group Owner, and each designated subscription's Owner at Stage 2. The billing administrator also turns on subscription-scope cost visibility once (U-20) | **Medium** — see "What to actually go check" below |
| 8 | Resolver Function | Reads `entitlement`, `subscriptionIndex`, `budgetState` at request time; reads `projects` at sync time only | **Cosmos DB Built-in Data Reader** (or Contributor, if it also writes) — Cosmos's own **data-plane** RBAC, confirmed live 2026-10-09 to be a **separate system from Azure control-plane RBAC**: an Azure Owner/Contributor role on the account does not imply any data-plane access at all, and the two are granted by different commands (`az cosmosdb sql role assignment create`, not `az role assignment create`) | Cosmos data-plane RBAC (its own `sqlRoleDefinitions`, not an Azure built-in role) | Resource-group Owner, **plus** a second, Cosmos-specific grant step most checklists omit | Low once known, but a real gap if assumed — a Function's managed identity holding only Contributor on the account cannot read a single document |
| 9 | APIM's own managed identity | Reaches the resolver's private endpoint, and every **same-tenant** designated subscription's Foundry account, over private endpoints; reads TLS certs/secrets if Key Vault-backed | Cognitive Services User (per same-tenant backend); Key Vault Secrets User (if applicable) | Azure RBAC | Resource-group Owner (for the private endpoint), that backend subscription's Owner (for the role) | Low |
| 10 | Cross-tenant backend auth app (only when a designated subscription is in a **different** Entra tenant from the gateway — `docs/NETWORK.md`'s "Backend authentication" decision table) | Exchanges a client secret for a token APIM uses to call that one backend; **cannot** be a managed identity (confirmed live 2026-10-09 — a managed identity's token is always minted in its own home tenant, rejected cross-tenant regardless of RBAC) | Cognitive Services User, in the backend's own tenant; a client secret, rotated on whatever lifetime cap that tenant's own policy enforces (proven as low as 7 days in one real tenant) | Azure RBAC (role) + Entra App Registration (identity), both **in the backend's tenant**, not the gateway's | Application Administrator **in the backend's own tenant** — a materially different administrative domain from every other row here, since it is not the gateway's own tenant admin | **High** — needs a willing admin in a tenant this design otherwise never touches, and an ongoing secret-rotation commitment (U-10, OPEN) |

## What to actually go check (the two genuinely open items)

**#2/#3 — `GroupMember.Read.All` application permission, admin consent.** This is the one grant the
entire *automated* add/remove detection path (both the periodic sync and the change-notification
fast path) depends on. It needs a Privileged Role Administrator or Global Administrator to consent,
and the reference repository's own research (its `docs/UNKNOWNS.md` U17, U19 — read-only reference,
not reused code) found this **not grantable** in its own test tenant. This is not assumable for
SampleOrg's tenant either — logged as U-7.

**Proof-of-concept tenant (`REPLACE-id-...`), 2026-10-11:** granted. The owner activated an eligible
role through PIM and assigned `GroupMember.Read.All` to `sample-pilot-sync-id` from Cloud Shell. The
coordinator verified the assignment (`docs/DEPLOYMENT-GUIDE.md`, Step 7). This shows the grant is
possible; it does not settle it for the customer's tenant (U-7).

**If it's refused:** fall back to an **operator-delegated, manually-triggered sync** — a human
with Groups Administrator (or equivalent directory role) runs the sync using their own delegated
token, the same pattern the reference repository already uses for its non-optional path ("the
installer, the switch and `Sync-ClaudeAccess.ps1` use the operator's own sign-in"). This needs no
special admin consent at all, at the cost of needing a human to trigger it rather than running fully
unattended.

**#7 — subscription-scope cost visibility (changed 2026-10-11, ADR-0005).** The reconciler no longer
reads the Price Sheet. Researched 2026-10-11 (`docs/MARKETPLACE-COST.md` §1, §8), there is no discounted
CCU unit price to read: the CCU price is fixed, and discounts reduce the CCU quantity. The reconciler
reads billed CCU per designated subscription, with Cost Management Reader on that subscription. That role
shows cost only when the billing account allows it: on an EA, "AO view charges" enabled; on an MCA, the
"Azure charges" setting, which needs a Billing Profile Owner. This is a one-time setting, not a role held
by a service identity. Logged as U-20; U-8 (the billing-scope role) is MOOT.

## Why this table exists

Every one of the "High" friction rows above is a real dependency on someone *outside* this design's
own control — a tenant or billing administrator who has to say yes. Nothing in the architecture
(`docs/ARCHITECTURE.md`, `docs/NETWORK.md`) assumes either grant will be approved; both have a stated
fallback that works without it. Confirming these two is the most useful single thing to do next,
before any live proof — a design that depends on a permission nobody will grant is not a design, it's
a hope.
