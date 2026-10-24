# Gateway policy — operator guide

The `claude-messages` API on API Management enforces, for every request: the developer's Microsoft
Entra token, their entitlement through the resolver, the model allow-list of their classification, and
the per-person and per-group token limits. Decision record: ADR-0017 (internal record, not published).
Evidence, availability settings and failure modes: WP-GW status (internal record, not published).

## Files

| Path | What it is |
|---|---|
| `infra/gateway/gateway-config.schema.json` | The configuration contract. Every value is required; none has a default |
| `infra/gateway/config/<env>.json` | One environment's values (`sample-pilot.json` for the PoC). No secrets: a backend secret is referenced by the name of an APIM secret named value |
| `infra/gateway/policy/` | The policy template and the per-credential backend fragments. No environment value may appear in them; the renderer refuses one that does |
| `infra/gateway/render.ts` | Validates a configuration and renders the policy |
| `infra/gateway/Deploy-GatewayRevision.ps1` | Creates a new non-current revision; `-MakeCurrent` makes a revision current |
| `infra/gateway/out/` | Rendered policies, diffs, `render.json`, `deployment.json`, `make-current.json`, `audit.jsonl`. Git-ignored |

## What a request goes through

1. **Token.** `validate-jwt`: issued by the configured tenant (v1 `https://<v1IssuerHost>/<tenant>/` or
   v2 `<authorityHost>/<tenant>/v2.0`), for one of the configured audiences, with `tid` = the tenant and a
   GUID `oid`. A person's (delegated) token must carry the configured scope in `scp` and come from a client
   application in `entra.delegatedClientAppIds` (its `azp`, or `appid` in a v1 token): the developer sign-in
   app. Any application that is granted the scope gets tokens that carry it, so the scope alone does not
   name the client (WP-SEC finding A3, `docs/status/WP-SEC.md`). An app-only token is
   refused unless `entra.testIdentities` allows it, its client id is listed and its `roles` claim holds
   `entra.testIdentities.appRole` (exact match; WP-NET finding S1). Test identities only; production sets
   `allowAppOnlyTokens` false and `appRole` null.
2. **Admission.** At most `admission.perPerson.calls` requests per `renewalPeriodSeconds` per person,
   before anything else is looked up.
3. **Entitlement.** One cache entry per tenant, person and project selector. A fresh allow is used as is;
   otherwise the resolver is asked (`POST resolver.url` with `{personId, projectId?, requestId}`, APIM's
   managed identity for `resolver.tokenAudience`). A miss is admitted under gateway-wide limits on resolver
   calls (`admission.resolverMisses`); the refresh of an expired allow is not, so a person who holds
   last-known-good keeps it when those limits trip. If a refresh fails, the old allow is served, marked
   `x-ccof-entitlement: degraded`, until `allowTtlSeconds + lastKnownGoodGraceSeconds` after it was
   obtained, and the resolver is not asked again for that person for `refreshBackoffSeconds`. The project
   selector is the optional header `resolver.projectHeaderName` (pilot: `x-ccof-project`); a person with
   one active project needs none.
4. **Allow-lists.** The resolver's `backendId` must be a configured static backend or come with the
   resolver's backend descriptor (C-8: the gateway routes only to what the resolver returns), and the
   request's `model` must be in the person's `modelAllowList`.
5. **Token limits.** The resolver's `tokenLimits` (C-2): the group's limits on counter
   `g:{projectId}:{classification}`, then the person's on `p:{projectId}:{oid}`. A `null` limit is not
   applied. A rate refusal is 429, a quota refusal 403.
   - The limits count `input_tokens` and `output_tokens` only. Claude's cache writes and reads are not
     counted, streamed or not; a streamed request is counted when its stream ends (live, 2026-10-12;
     Microsoft Learn "llm-token-limit": "counts prompt and completion tokens only").
   - The configured `tokenLimits.headers` carry the limits' values. The remaining-quota headers are an
     estimate (Learn); live, they showed the quota minus the current request, not the period's total.
   - On a streamed reply every limit header leaves before the reply is counted.
6. **Forwarding.** The client's `Authorization`, `x-api-key`, `api-key` and the selector header are removed;
   `anthropic-version` (set to `forwarding.defaultAnthropicVersion` if absent) and `anthropic-beta` pass.
   The backend's own credential is added (see "Backends" below). The API's backend section forwards the
   request itself rather than inheriting the service scope: a request with `"stream": true` with
   `buffer-response="false"`, so each server-sent event reaches the client as the backend sends it (owner
   approval (d); Microsoft Learn "forward-request" and "Configure API for server-sent events"); any other
   request with a bare `forward-request`, as the service scope does (platform defaults, timeout 300 s). A
   change to the service scope's `forward-request` does not reach this API.
7. **Telemetry.** `ccof.resolver.v1` when the resolver was asked; `ccof.usage.v1` for every forwarded
   request (counts only; a streamed body is never read, so nothing holds a stream back) — `docs/TELEMETRY.md`.
   A non-streamed body is read by a policy of its own that a streamed reply never reaches: the gateway reads
   the whole reply before any policy that mentions the response body runs (live request traces, 2026-10-12).

A request whose method and path match no operation of the API never reaches step 1. API Management raises
`OperationNotFound` (source `configuration`) before any policy runs, and the policy's on-error answers 404
`not_found_error`: no token check, resolver call or backend call, and nothing is counted (Learn, "Error
handling in Azure API Management policies"; `docs/status/WP-GW.md` AC16). Claude Code sends one such request
at startup, `HEAD /api/hello`, and ignores the answer. Revision 8 answers these requests 500; the 404 comes
with revision 9.

## Backends

Two deployment shapes share the same policy (owner, 2026-10-11): **(A)** the core in the Foundry tenant,
where APIM reaches Foundry with its managed identity; **(B)** APIM in another tenant, reaching Foundry
through an app registration in the Foundry tenant with client credentials (the live PoC).

- **By data (no policy change).** The resolver returns a descriptor for the backend it selected (C-8),
  when its backend registry holds a document for that `backendId`:
  `{"id", "apiFormat": "anthropic-messages", "auth"}` with `auth.mode`
  - `managed-identity` and `resource` (shape A; for Foundry `https://cognitiveservices.azure.com`). The
    gateway checks only its form (an `https` or `api` URI, or a GUID); the resolver validates the
    registry document. APIM's system-assigned identity needs Cognitive Services User on the account:
    stage D3 grants it from `infra/gateway/assignments.json`, one assignment per managed-identity backend.
  - `credential-manager` with `providerId` and `connectionId` (shape B without a secret in the policy):
    an APIM credential manager connection, Microsoft Entra provider, client-credentials grant, whose
    access policy admits APIM's system identity. Created in the portal by the owner (U-43).
  - `backend-entity`: keys or headers configured on the APIM backend entity.

  To add a backend: create its APIM backend entity and register it (onboarding Stage 2 writes the
  resolver's `backends` document). Nothing changes at the gateway: there is no gateway-side list of
  backends or resources (owner decision 15; a gateway-side binding is proposal P-GW-1 in
  `docs/status/WP-GW.md`). A malformed descriptor makes the resolver's answer "unavailable" (last-known-good
  or 503); a `backendId` with neither a descriptor nor a static branch gets 503 "not configured". Nothing
  is forwarded in either case.
- **Static (policy change).** `backends[]` in the configuration lists backends whose credential needs a
  secret named value in the policy: today `foundry-sample-hub`, cross-tenant client credentials with the
  named value `foundry-crosstenant-client-secret`, exactly as the original policy. It is the fallback
  while credential manager is unproven for the second-tenant path; a static backend's branch takes
  precedence over its descriptor. Shape A has none (`backends: []`).

Every refusal is answered in Anthropic's error shape, `{"type":"error","error":{"type":...,"message":...}}`,
with the gateway request id at the end of the message and in the `x-ccof-request-id` header.

| Situation | Status | `error.type` |
|---|---|---|
| No token, invalid, expired, other audience or tenant | 401 | `authentication_error` |
| Token without the scope; a person's token from a client application not in `entra.delegatedClientAppIds`; an application token that is not a test identity or lacks the app role | 403 | `permission_error` |
| Not entitled (no active membership for the project) | 403 | `permission_error` |
| Model not in the person's allow-list (the message lists the allowed models) | 403 | `permission_error` |
| Invalid project header; body not JSON or without `model`; more than one project and no selector | 400 | `invalid_request_error` |
| A method or path the gateway does not serve, for example Claude Code's `HEAD /api/hello` probe, `GET /v1/models` or `/v1/messages/count_tokens` (from revision 9; revision 8 answers 500) | 404 | `not_found_error` |
| Too many requests from one person; gateway busy checking access | 429 + `Retry-After` | `rate_limit_error` |
| Person or group tokens-per-minute reached | 429 + `Retry-After` | `rate_limit_error` |
| Person or group token quota used up (the message names which, and when it resets) | 403 | `permission_error` |
| Person's or classification's CCU budget used up (C-7; the message names which) | 403 | `permission_error` |
| Access cannot be confirmed (resolver unavailable, no last-known-good) or budget state stale | 503 + `Retry-After` | `api_error` |
| Backend credential unavailable; backend not configured; backend unreachable or slow | 503 / 502 / 504 | `api_error` |

## Render

```powershell
node infra/gateway/render.ts --config infra/gateway/config/sample-pilot.json
```

Prints the configuration id, the policy, configuration and template SHA-256 digests and the output path.
A missing or invalid value is refused with the field named; nothing is written.

## Deploy a new revision (never current)

```powershell
pwsh -NoProfile -File infra/gateway/Deploy-GatewayRevision.ps1 -ConfigPath infra/gateway/config/sample-pilot.json
```

The script renders, reads the API, its revisions and the current policy through ARM REST (a token from
`az account get-access-token --subscription <apim.subscriptionId>`; the Azure CLI login is not changed),
shows the whitespace-insensitive diff (also saved to `out/<configurationId>/diff-vs-rev<N>.txt`), and asks
you to type the first 12 characters of the policy digest. It then creates revision N+1 from the current
revision, saves the policy to it and checks it is not current. Test it at
`https://<gateway>/<apiPath>;rev=<N+1>/v1/messages`.

Non-interactive runs need an answers file; every field is required:

```json
{
  "action": "createRevision",
  "apiId": "claude-messages",
  "configurationId": "sample-pilot-gateway-20261011",
  "expectedCurrentRevision": "1",
  "policySha256": "<the digest render.ts printed>",
  "approvedBy": "<object id of the approver>"
}
```

```powershell
pwsh -NoProfile -File infra/gateway/Deploy-GatewayRevision.ps1 -ConfigPath <config> -AnswersPath <answers> -NonInteractive
```

The answers file approves exactly one policy: if the rendered digest, the configuration id or the current
revision differ, the script refuses before any write.

## Make a revision current, and roll back

Only after the revision has passed its live tests (`tests/Test-GatewayLive.ps1`) and the live smoke suite:

```powershell
pwsh -NoProfile -File infra/gateway/Deploy-GatewayRevision.ps1 -ConfigPath <config> -MakeCurrent -Revision <N> -ReleaseNote '<why>'
```

You confirm by typing `<apiId>;rev=<N>` (or an answers file with `action` `makeCurrent`, `revision`,
`expectedCurrentRevision`, `releaseNote`, `approvedBy`). The script brings revision N online if it is
offline, creates an API release, checks that revision N is current, and then takes the revision it
replaced **offline**: API Management answers every online revision at `<apiPath>;rev=<N>` whichever is
current, so a replaced revision with an older policy would otherwise stay callable. Offline takes effect
at the gateway within about 30 seconds (measured 2026-10-11: `;rev=5` answered 401 just after the change and
404 some 30 s later). The script prints the rollback command, and writes its record, `make-current.json`
(the revision, the revision current after the release, the previous one), to the output folder;
`deployment.json` stays the record of the revision's creation. **Rollback** is the same step for the previous
revision: `-MakeCurrent -Revision <previous> -ReleaseNote 'rollback: <why>'`; it brings the previous revision
online first. A revision is never deleted by these scripts.

To take a superseded non-current revision offline without a release (for example after testing a newer
one): `-TakeOffline -Revision <N>`, confirmed by typing `<apiId>;rev=<N>` or an answers file with `action`
`takeOffline`, `apiId`, `revision`, `expectedCurrentRevision`, `approvedBy`. It refuses for the current
revision. To bring such a revision back for a test, make it current (above) or set `isOnline` to true on
`apis/<apiId>;rev=<N>` through ARM with `If-Match: *`.

## Live tests

```powershell
$env:CCOF_LIVE_TESTS = '1'
$env:CCOF_GW_LIVE_CONFIG = '<a filled copy of infra/gateway/live-test.example.json>'
pwsh -NoProfile -File tests/Test-GatewayLive.ps1
```

Stage `no-app-role` (the test client is not assigned `entra.testIdentities.appRole`): 401 for no, malformed
and wrong-audience tokens; the test client's app-only token refused 403 as an application token (AC15,
WP-NET S1). In every stage the test token's client id must be in the configuration's
`entra.testIdentities.clientAppIds` (the policy's app-only allow-list). Stage `unseeded` (the test client
holds the role): the same 401s, and 403 "not entitled" for the test identity, which shows the role passed
the identity step. Stage `seeded`: 200 for an allowed model, 403
for a disallowed one, a streamed reply whose server-sent events arrive in at least five different 100 ms
intervals (AC14; `tests/helpers/GatewayStream.psm1`, tested offline by `tests/Test-GatewayStream.ps1`), and
the person quota's 403 within the configured number of requests (the test identity's project needs a low
person quota). `quotaProbeMaxRequests` 0 leaves the quota unprobed, reported as NOT RUN, because the probe
uses up the test identity's quota until the period resets. Without both variables the script reports itself
skipped and makes no call.

## The cache is volatile

APIM's built-in cache "is volatile and is shared by all units in the same region" (Microsoft Learn). A
gateway restart, scale operation or platform update can empty it. Then every request is a miss and the
resolver is asked again, within the resolver admission limits. If the resolver is down at the same time,
nobody whose entry was lost has a last-known-good decision, and they get 503 until it returns. For
production, `entitlementCache.cachingType` `external` with a zone-redundant Redis-compatible cache keeps the
entries across gateway restarts (ADR-0014; an administrator decision with a cost).

To drop every cached decision on purpose (for example after a data correction), raise
`entitlementCache.keyVersion` and deploy. Do not do it during a resolver outage.

During a resolver outage, a person whose allow has expired but is within the grace gets one resolver
attempt (up to `resolver.timeoutSeconds`), then last-known-good without resolver calls for
`refreshBackoffSeconds`, then one more attempt, and so on until the grace ends. A refusal or a budget-state
refusal from the resolver replaces the entry at once; last-known-good is never served after one.

## Troubleshooting

- **Find a request.** Every gateway answer carries `x-ccof-request-id`. In Log Analytics:
  `ApiManagementGatewayLogs | where CorrelationId == "<id>"` gives `ResponseCode`, `LastErrorSource`,
  `LastErrorReason` and `TraceRecords` (the `ccof.resolver.v1` and `ccof.usage.v1` traces).
- **Everyone gets 503 "could not confirm your access".** The resolver is unreachable or refusing APIM:
  check its health and App Service Authentication (ADR-0009); APIM's managed identity must be the one
  allowed. `resolverOutcome` `unavailable` in `ccof.resolver.v1` confirms it.
- **Everyone on one backend gets 503 "could not get a credential".** The backend's credential failed; for
  cross-tenant backends, check the secret named value's expiry (U-10).
- **A model is refused that should be allowed.** The allow-list comes from the person's project and
  classification (`projects`, Stage 3); the cache keeps it for up to `allowTtlSeconds`.
