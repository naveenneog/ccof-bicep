# Gateway family admission and token ceilings

This template implements Module A of
[`model-family-quotas.md`](../../../docs/design/model-family-quotas.md). Render it through
`infra/gateway/render.ts`; never edit the generated policy in the portal.

## Integration and invalidation

- Deploy with the v3 resolver, family-policy sync projection and migrated registry/onboarding
  documents. Old resolver replies are unavailable, not implicit grants.
- The entitlement cache namespace is `ccof-ent:d3:v{keyVersion}:…`. Cached allows must pass the
  v3/group-ID/family-policy checks before either fresh use or last-known-good use. Allow/refusal TTL,
  refresh backoff and grace still come from gateway configuration.
- A family change reaches existing cached allows after the refresh TTL. **For urgent revocation,
  increment configured `keyVersion` and deploy the rendered policy.** Entitlement generation does
  not eagerly evict the APIM cache.
- Malformed replies keep the existing unavailable/LKG handling; classified resolver refusals
  overwrite an earlier allow as before.

## Admission, accounting and telemetry

Admission is an ordinal exact match in exactly one registered family, including explicit deployment
aliases. Canonical prefixes are registration-consistency checks only. Unknown versions and wrong
case are refused with the generic family permission error, without revealing the registry. Fable
and Mythos entries require authoritative classification exactly `CYB`; group names grant nothing.

Existing aggregate group/person policies execute first with unchanged keys, headers and error
semantics. Family group/person policies add independent ceilings, sharing their counter across all
versions/aliases in a family. Null family limits skip that ceiling only; admission and aggregate
limits remain. Family policies never write aggregate accounting headers.

The frozen baseline has no budget-derived person TPM/minimum implementation. This module preserves
its aggregate token enforcement and does not introduce or claim new dollar-budget enforcement.
Token counters remain gateway-local; there is no globally atomic accounting guarantee.

Usage telemetry adds `modelFamily` and the trusted lowercase `classificationGroupId`. An optional
`classificationGroupDisplayName` string of 1–256 characters is copied exactly as informational
snapshot metadata, or emitted null when absent. No admission depends on that name and no historical
name is invented. Family telemetry introduces no request/response body reads and preserves the
existing non-streamed counts reader and unbuffered streaming path.

## Offline verification and remaining live proof

Run `node --test tests/gateway-family-quotas.test.ts tests/gateway-render.test.ts
tests/gateway-template.test.ts tests/gateway-apim-xml.test.ts` with `CCOF_LIVE_TESTS=0`.
The family tests render/parse the policy, then compile and execute its actual C# 7 expressions
using the repository-required PowerShell 7/Newtonsoft runtime. They are not an APIM emulator.

Live APIM compilation, all four active token counters, 403/429/Retry-After behavior, aliases sharing
counters, aggregate exhaustion across families, LKG/cache invalidation and streamed accounting
remain to be proven on an authorized non-current revision. Do not infer this proof from the offline
harness or run real-model load without an approved scope/cost.

Allowed C# collection/JSON/regex types were checked against
[Microsoft Learn policy expressions](https://learn.microsoft.com/en-us/azure/api-management/api-management-policy-expressions)
(retrieved 2026-10-13). The platform compiler/runtime still requires the separate live proof.
