# WP-FAMILY-QUOTAS: frozen implementation contract

**Design-only handoff, 2026-10-13. Owner changed scope: four independent implementation modules.
This contract supersedes the earlier additive-field proposal in this worktree.**

Baseline: `origin/wp/qs-seed-fn`, `0f382e6`. Contract metadata:
`config/model-families.json`. The design lead commits only these two files. Earlier implementation
experiments in the lead's worktree are uncommitted and are NOT implementation dependencies.
No Azure action, full suite, council or completed gate is claimed.

## 1. Families, exact model admission and prefix rules

Internal family names are case-sensitive lowercase `haiku`, `sonnet`, `opus`, `fable`, `mythos`;
display labels are Haiku, Sonnet, Opus, Fable, Mythos. They are identifiers, not prices or backends.

**Family membership is an explicit exact-ID registration.** A family entry's `models` array is
the exact model allow-list for that family. A request model must equal one configured value using
ordinal comparison. Searching the registered arrays must yield exactly one family.
There is no request-supplied family, inferred group-name permission or global fallback allow-list.

For canonical names, the entire name must match:

```text
^claude-(haiku|sonnet|opus|fable|mythos)-[A-Za-z0-9][A-Za-z0-9._-]{0,105}$
```

The captured family must agree with its explicit registration. This is an anchored,
delimiter-aware **consistency check**, not an admission rule. Never use bare `StartsWith`,
case folding, alias expansion or stripping dates/version suffixes to authorize a model.
`claude-haiku-unknown` is denied unless that exact ID is explicitly registered; `claude-haikux-5`
is not Haiku. Any ID starting with `claude-` that fails this pattern is rejected at configuration.
Non-`claude-` deployment aliases are allowed only as explicit exact IDs in a family entry, matching
`^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$`. Their family cannot be inferred from their prefix.
Duplicate models within/across families are configuration errors.

Fable/Mythos entries may exist **only under authoritative classification exactly `CYB`**.
`cyb`, `CYB-extra`, displayName `CYB Approved`, or a group name prefix grants nothing.
STD/PRM (and any other classification) containing either entry is invalid, even if it is empty or
has null limits. CYB may omit these families until real deployment IDs are supplied.
There are **no default Fable/Mythos model IDs, prices or working backends** in this contract.
The metadata file's empty deployment list does not constitute admission configuration.

Unknown/unregistered model, unknown family, or absent family on the selected group is refused:
**HTTP 403, internal reason `model_family_not_allowed`**. A requested canonical family whose exact
version is absent is also this refusal, never a prefix-based grant.

## 2. Cosmos registry contract (new shape, no dual-format migration)

Each classification in `projects` replaces its old top-level `modelAllowList` and `tokenLimits`
with **required `familyPolicy`**. Other project fields, CCU budget fields and aggregateMode are
unchanged. `familyPolicy` contains:

```json
{
  "aggregateLimits": {
    "person": { "tokensPerMinute": 1000000, "tokenQuota": 500000, "tokenQuotaPeriod": "Daily" },
    "group": { "tokensPerMinute": null, "tokenQuota": 2000000, "tokenQuotaPeriod": "Daily" }
  },
  "families": {
    "haiku": {
      "models": ["claude-haiku-4-5"],
      "person": { "tokensPerMinute": 200000, "tokenQuota": 250000, "tokenQuotaPeriod": "Daily" },
      "group": { "tokensPerMinute": 500000, "tokenQuota": 1000000, "tokenQuotaPeriod": "Daily" }
    },
    "sonnet": {
      "models": ["claude-sonnet-5"],
      "person": { "tokensPerMinute": 100000, "tokenQuota": 250000, "tokenQuotaPeriod": "Daily" },
      "group": { "tokensPerMinute": null, "tokenQuota": 1000000, "tokenQuotaPeriod": "Daily" }
    }
  }
}
```

These are existing sample deployment IDs, not evidence of deployments in a new customer account.
Every configured family has required nonempty unique `models`, required `person`, required `group`.
Each limit has **exactly** three required properties:
`tokensPerMinute`, `tokenQuota`, `tokenQuotaPeriod`. Null means no corresponding additional limit.
TPM is a positive safe integer <= 2147483647 or null. Quota is a positive safe integer
<= 9007199254740991 or null. Period is one of Hourly/Daily/Weekly/Monthly/Yearly or null.
Quota and period are both null or both nonnull. Zero, negative, fractional, stringified numbers,
unknown properties, unknown family keys and incomplete limits fail validation.
All-null limits still require exact model admission. Omitted family means **no access**, not
unlimited access. At least one family must be configured.

**Aggregate limits are retained inside the new object.** Family limits are additional ceilings;
both aggregate and selected-family counters run. Moving versions or families cannot multiply the
existing aggregate allowance. Dollar budgets, prices and budget reconciler behavior do not change.
Migrate the former aggregate limits verbatim to `aggregateLimits`; never split/multiply them.

Full project skeleton (unchanged surrounding fields abbreviated only in this explanation):

```json
{
  "id": "EXAMPLE01",
  "projectId": "EXAMPLE01",
  "displayName": "Example project",
  "status": "active",
  "backendId": "foundry-example",
  "designatedSubscriptionId": "11111111-1111-1111-1111-111111111111",
  "supersedes": null,
  "retiredAt": null,
  "classifications": {
    "STD": {
      "groupId": "22222222-2222-2222-2222-222222222222",
      "personBudget": { "amount": 25000, "currency": "CCU", "period": "monthly" },
      "aggregateBudget": null,
      "aggregateMode": "notify",
      "onboardingMode": "warn",
      "familyPolicy": {
        "aggregateLimits": {
          "person": { "tokensPerMinute": 1000000, "tokenQuota": 500000, "tokenQuotaPeriod": "Daily" },
          "group": { "tokensPerMinute": null, "tokenQuota": 2000000, "tokenQuotaPeriod": "Daily" }
        },
        "families": {
          "haiku": {
            "models": ["claude-haiku-4-5"],
            "person": { "tokensPerMinute": 100000, "tokenQuota": 250000, "tokenQuotaPeriod": "Daily" },
            "group": { "tokensPerMinute": null, "tokenQuota": 1000000, "tokenQuotaPeriod": "Daily" }
          }
        }
      }
    }
  }
}
```

`entitlement.projectMemberships[]` copies `familyPolicy` unchanged, plus existing `projectId`,
`classification`, `classificationGroupId` (the registered groupId, normalized lowercase GUID),
`backendId`, `aggregateMode`, timestamps/status and optional subscriptionId.
It no longer writes `modelAllowList`/`tokenLimits`. Existing generation/verification rules persist.
Any family/model/limit change must change the copied-field comparison and increment generation.
No new Graph read or per-request Graph call is needed for family policy.
The workbook peer's optional `classificationGroupDisplayName` remains informational only.

Old documents without familyPolicy fail closed with the existing malformed-entitlement/
invalid-project machinery; do not synthesize families from old prices or model prefixes.
Staged onboarding and quick-start examples must migrate in the same implementation release.

## 3. Shared type/validator API (Module C)

Create `src/contracts/model-families.ts`, owned only by C, exporting:

```typescript
type ModelFamily = "haiku" | "sonnet" | "opus" | "fable" | "mythos";
type TokenQuotaPeriod = "Hourly" | "Daily" | "Weekly" | "Monthly" | "Yearly";
interface TokenLimit {
  tokensPerMinute: number | null;
  tokenQuota: number | null;
  tokenQuotaPeriod: TokenQuotaPeriod | null;
}
interface FamilyEntry { models: string[]; person: TokenLimit; group: TokenLimit; }
interface FamilyPolicy {
  aggregateLimits: { person: TokenLimit; group: TokenLimit };
  families: Partial<Record<ModelFamily, FamilyEntry>>;
}
function parseFamilyPolicy(value: unknown, classification: string):
  | { ok: true; value: FamilyPolicy }
  | { ok: false; detail: "invalid_family_policy" | "family_classification_forbidden" };
function admittedModelFamily(policy: FamilyPolicy, classification: string, model: string):
  ModelFamily | null;
```

`admittedModelFamily` rechecks exact model registration and CYB restriction; null maps to
`model_family_not_allowed`. The shared module is pure, framework-free, no Azure/Graph/filesystem
dependencies, no resolver import cycle. B and D import it; C uses it in its project validator.
Module C owns runtime TS validation; D owns the PowerShell onboarding schema and boundary check
with matching rules (no runtime npm dependency added merely for PowerShell schema validation).
Use compile-time compatibility checks rather than divergent sync/resolver type definitions.

## 4. Resolver wire contract (Module B)

Input remains `{personId, projectId?, subscriptionId?, requestId?}`. The resolver does not need the
request model: it validates and returns the selected group's full policy. Gateway admission uses
the body model and this returned policy. No extra Cosmos read is introduced.
Success replaces top-level `modelAllowList`/`tokenLimits` with `familyPolicy`.
Other existing routing/budget fields keep their semantics.

```json
{
  "refused": false,
  "resolverOutcome": "success",
  "decisionVersion": 3,
  "personId": "33333333-3333-3333-3333-333333333333",
  "projectId": "EXAMPLE01",
  "classification": "STD",
  "classificationGroupId": "22222222-2222-2222-2222-222222222222",
  "backendId": "foundry-example",
  "familyPolicy": {
    "aggregateLimits": {
      "person": { "tokensPerMinute": 1000000, "tokenQuota": 500000, "tokenQuotaPeriod": "Daily" },
      "group": { "tokensPerMinute": null, "tokenQuota": 2000000, "tokenQuotaPeriod": "Daily" }
    },
    "families": {
      "haiku": {
        "models": ["claude-haiku-4-5"],
        "person": { "tokensPerMinute": 100000, "tokenQuota": 250000, "tokenQuotaPeriod": "Daily" },
        "group": { "tokensPerMinute": null, "tokenQuota": 1000000, "tokenQuotaPeriod": "Daily" }
      }
    }
  },
  "budgetEnforcement": "token-limits-only",
  "aggregateStrict": false,
  "aggregateState": null,
  "personBudgetScope": "33333333-3333-3333-3333-333333333333:EXAMPLE01",
  "personCeilingTokensPerMinute": null,
  "degraded": false,
  "degradedReasons": [],
  "budgetState": null
}
```

`backend` is optional as today. `classificationGroupDisplayName` may be an optional snapshot from
the workbook packet, never an admission input. Validate group ID as GUID before success.
Malformed/forbidden stored policies produce existing 503 malformed-entitlement handling with
internal detail `invalid_family_policy` or `family_classification_forbidden`; no partial success.
The requested-model 403 belongs to gateway (resolver has no requested model input).

## 5. Gateway policy, counters, refusals and telemetry (Module A)

Require `decisionVersion == 3`; validate familyPolicy using the same structural checks in C#,
not just a trusted cast. A malformed new resolver reply is unavailable under existing resolver
failure handling, not unrestricted admission. Before model service forwarding, independently check
CYB-only families and ordinal exact-ID membership.

Cache key:
`ccof-ent:d3:v{keyVersion}:{tenantId}:{oid}:{selector-or-dash}`.
This makes d1/d2 decisions unreachable. Existing allow TTL, refusal TTL, refresh backoff and
last-known-good grace remain. Never serve a lower-version decision as last-known-good.
Sync changes invalidate by refresh TTL; **urgent policy changes require incrementing configured
keyVersion** and deploying that policy. Do not claim generation eagerly evicts APIM's cache.

Policy variables (exact names, primitives/serialized JSON only):

| Variable | Meaning |
|---|---|
| `ccofModel` | request exact model ID, as today |
| `ccofModelFamily` | admitted lowercase family; initialize `""` before admission |
| `ccofClassificationGroupId` | verified selected group GUID |
| `ccofFamilyPolicy` | serialized validated policy JSON |
| `ccofFamilyPersonTpm`, `ccofFamilyGroupTpm` | selected-family int; null normalized to 0 |
| `ccofFamilyPersonQuota`, `ccofFamilyGroupQuota` | selected-family long; null normalized to 0 |
| `ccofFamilyPersonPeriod`, `ccofFamilyGroupPeriod` | selected-family period string; null -> `""` |
| `ccofPersonTpm/Quota/Period`, `ccofGroupTpm/Quota/Period` | existing aggregate variables, now from aggregateLimits |

Apply existing aggregate group then aggregate person policies **unchanged**, including existing
budget-derived person ceiling/minimum logic. Then selected-family group and person limits using
`llm-token-limit`, with rate+quota, rate-only and quota-only branches as today.
Do not overwrite aggregate consumed-token/remaining headers with family results.
No selected-family limit executes before exact admission; absent/null individual limit skips
only that policy, not admission or aggregate policies.

Counter keys:

```text
aggregate group: g:{projectId}:{classification}         (unchanged)
aggregate person: p:{projectId}:{oid}                 (unchanged)
family group: gf:{projectId}:{classificationGroupId}:{modelFamily}
family person: pf:{projectId}:{oid}:{modelFamily}
```

Versions in one family must share the same key; do not append model ID.
Different projects/people/groups/families must not share their respective scoped key.
Existing gateway-local counter limitations remain; no global atomic accounting claim is made.
Family policy IDs:
`ccof-limit-family-{group|person}-{rate-quota|rate|quota}`.
`on-error` must recognize these IDs without falling into the aggregate-only handler.

| Internal reason | HTTP | Anthropic error type | Message |
|---|---:|---|---|
| `model_family_not_allowed` | 403 | `permission_error` | `The requested model family is not available to your project classification. Ask your platform team for an approved model.` |
| `family_person_rate_exceeded` | 429 | `rate_limit_error` | `Your token rate limit for this model family is exceeded. Retry after the indicated interval.` |
| `family_group_rate_exceeded` | 429 | `rate_limit_error` | `Your group's token rate limit for this model family is exceeded. Retry after the indicated interval.` |
| `family_person_quota_exceeded` | 403 | `permission_error` | `Your token quota for this model family is used up for this quota period.` |
| `family_group_quota_exceeded` | 403 | `permission_error` | `Your group's token quota for this model family is used up for this quota period.` |

Use existing request-id envelope/headers and Retry-After behavior. A rate+quota policy maps APIM
429 to the matching rate reason and its quota failure to the matching quota reason.
Unknown model/family and non-CYB restricted models all use the same 403, no registry detail leak.
Malformed registry and resolver failures retain the existing 503 messages/codes.
Existing aggregate refusals remain unchanged.

**Telemetry field is `modelFamily`**, populated from `ccofModelFamily` as lowercase family for
admitted usage; null when not established. Counts only, no request/response body reading.
Module A owns policy telemetry and adds this field to usage traces. Workbook peer's revised scope
owns no policy/resolver/sync files; it consumes the field, with explicitly labeled historical
prefix-derived reporting where the old field is absent. Reporting inference never authorizes.
The resolver's trusted `classificationGroupId` must also reach admitted usage traces.
If optional `classificationGroupDisplayName` is present, A may emit it as informational metadata,
but neither A nor B invents historical names or infers classification from a display-name prefix.

## 6. Customer form and seed (Module D)

Each `groups[]` entry in `customer-form.bicepparam` / `main.bicepparam` replaces old
`modelAllowList` and `tokenLimits` with the same required `familyPolicy`:

```bicep
{
  groupId: 'REPLACE-group-object-id'
  projectId: project1
  classification: 'STD'
  displayName: 'Claude project standard'
  familyPolicy: {
    aggregateLimits: {
      person: { tokensPerMinute: 1000000, tokenQuota: 500000, tokenQuotaPeriod: 'Daily' }
      group: { tokensPerMinute: null, tokenQuota: 2000000, tokenQuotaPeriod: 'Daily' }
    }
    families: {
      haiku: {
        models: ['claude-haiku-4-5']
        person: { tokensPerMinute: 100000, tokenQuota: 250000, tokenQuotaPeriod: 'Daily' }
        group: { tokensPerMinute: null, tokenQuota: 1000000, tokenQuotaPeriod: 'Daily' }
      }
    }
  }
  personBudget: { amount: 25000, currency: 'CCU', period: 'monthly' }
  aggregateBudget: null
  aggregateMode: 'notify'
  onboardingMode: 'warn'
}
```

Form descriptions explain removing a family revokes that family; null limits do not revoke it.
To add CYB/Fable/Mythos: first establish real deployment IDs/backend reachability separately,
then explicitly add their family entries under classification CYB; no runnable placeholder model
IDs. Generic form values are not customer values and must not be exported as live configuration.

`New-QsSeedDocuments` validates every group before the first Azure call and copies `familyPolicy`
into `projects[].classifications[code]`. Payload remains
`{seedId, projects:[...], backends:[...]}`, base64 CCOF_SEED_DOCUMENTS; backend schema is unchanged.
`registrySeed` validates with C's shared validator before any Cosmos write, retains create-only/
409 readback comparison, never silently ignores familyPolicy. Rerun changed family policy returns
present-differs, never overwrite. Seed copy must retain aggregate values verbatim.
Update staged onboarding project schema and examples so new documents cannot bypass CYB checks.
Docs warn existing registry documents require an approved onboarding update (not create-only seed).

## 7. Exclusive implementation ownership

Patterns below are disjoint; explicit exceptions take precedence over directory ownership.
Agents must not edit another module's files or shared ledgers. Shared root README/CHANGELOG/
STATUS/ROADMAP/UNKNOWNS and integration merges are coordinator-owned.

| Module | Owns |
|---|---|
| A — gateway admission/quotas | `infra/gateway/policy/**` including family/group-ID telemetry; `tests/gateway-family-quotas.test.ts`; updates needed in existing `tests/gateway-{render,template,apim-xml}.test.ts` |
| B — resolver | `src/resolver/**`; `tests/resolver-*.test.ts`; `tests/helpers/resolver-fixtures.ts` |
| C — sync + shared types | `src/contracts/**`; `src/sync/**` **except `src/sync/registry-seed.ts`**; `config/model-families.json`; `tests/sync-*.test.ts` **except `tests/sync-registry-seed.test.ts`**; `tests/helpers/sync-fakes.ts`; `tests/model-families-contract.test.ts` |
| D — form/seed/docs | `infra/quickstart/**`; **`src/sync/registry-seed.ts` only**; **`tests/sync-registry-seed.test.ts` only**; `tests/Test-Quickstart*.ps1`; `scripts/Onboarding.Schemas.psm1`; `scripts/Onboarding.Projects.psm1`; `tests/Test-OnboardingTokenLimits.ps1`; `tests/Test-OnboardingPilotExamples.ps1`; `docs/examples/*stage3.answers.json`; `docs/QUICKSTART.md` |

The registrySeed exception resolves the otherwise overlapping C/D assignment.
Workbook peer exclusively owns workbook/KQL/assets and cost/reporting; its latest scope excludes
policy/resolver/sync edits. No quota agent modifies workbook files. Existing generic family experiment test in the
design lead's dirty worktree is not a file assignment or dependency.
This frozen contract file is coordinator/design-owned; modules consume it without editing.
Module A does not edit gateway config/render helpers unless coordinator assigns a newly discovered
dependency (family header additions are not required).

## 8. Required targeted offline checks

All modules: unset CCOF_LIVE_TESTS; isolated logged-out AZURE_CONFIG_DIR. No full suites, no
council/gates, no Azure calls. Record the specific initial failing check then passing command.
Typecheck may expose baseline fixture migrations; report them, do not weaken validations.

**A**
- Render/parse policy; require v3/d3, reject old cached format, preserve LKG only for validated v3.
- Exact registered ID admitted; familiar-prefix unknown ID and wrong case denied 403.
- Missing family denied; Fable/Mythos in non-CYB denied independently at admission.
- All four scopes execute; all-null family limits still preserve aggregate policies.
- Two versions in one family use identical family keys; different projects/people/groups differ.
- Rate+quota/rate-only/quota-only branches, safe int/long casts, period validation and both error
  statuses for group/person policy IDs; no family headers overwrite aggregate accounting.
- Emit trusted modelFamily/group ID without streamed response/body reading or KQL ownership breach.

**B**
- Parse valid policy and return response exactly with version 3 and group GUID.
- Old missing-policy records, malformed limits, duplicate models, canonical-family mismatches,
  unknown family and forbidden non-CYB entries fail closed.
- Token-limits-only reads no budget; aggregate limits and budget-state behavior remain unchanged.
- Cross-project selector/key checks unchanged, invalid policy in another project isolated.
- No request-supplied classification/model family, no Graph/new Cosmos read.

**C**
- Pure shared validator: every numerical/period/null/unknown-field boundary; omitted family is
  denied, not unlimited. Non-CYB empty Fable/Mythos entry also rejected.
- Exact prefix consistency and custom alias rules; no wildcard/date-stripping admission.
- Sync copies policy byte-equivalently (canonical JSON), writes generation on family changes,
  does not rewrite unchanged policy and preserves existing freeze/removal/conflict safeguards.
- Projection types compatible with B without import cycles; packaging includes shared module.

**D**
- Generic form/Bicep compiles offline; sample family structure and preserved aggregate values.
- New-QsSeedDocuments copies policy and rejects non-CYB restricted entries before writes.
- registrySeed negative batches make zero Cosmos calls for bad policies; 201, 409 equal and
  409 differing family quotas retain existing create-only outcomes.
- Staged onboarding schema accepts new example and rejects old/malformed shapes plus CYB bypass.
- No fabricated Fable/Mythos deployment IDs or prices, no public/customer checkout modification.

Integration coordinator runs only these targeted files/typecheck/Bicep, merges no branch without
the owner's instruction, and reports live APIM compilation/counting as outstanding until the
separate authorized proof. The shared-machine test tool/dependency availability is not assumed.
