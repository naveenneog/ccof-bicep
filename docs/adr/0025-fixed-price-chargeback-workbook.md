# ADR-0025: Fixed-price reporting with directory name snapshots, independent of budgets

- Status: Accepted for the owner's scoped offline packet, 2026-10-13
- Packet: WP-CHARGEBACK-OCT13

## Context and precedence

The owner expressly requested fixed hardcoded model prices, exact Entra group names,
per-developer/group token spend, and Cloud Shell deployment without a reconciler.
For this reporting surface this supersedes the negotiated-billing goal in CHARTER
and ADR-0011's reconciler dependency; it does not change budget or token enforcement.
The owner's initial implementation instruction stopped full suites, gates, live
tests and councils. The later five-hour integration instruction reinstated Ironclad
review/gates; it supersedes that earlier safeguard override. This isolated module
has targeted offline validation and the pre-commit audit, not integrated acceptance.
The coordinator owns integrated council and full packet gates across the disjoint
modules. Those remain pending, not waived or claimed passed here. No Azure mutation
or load test is authorized from this worktree.

## Decision

Reuse `analytics/ledger.kql`, the workbook rate-card compiler/rollups/native Azure
Monitor controls, and `src/cost` decimal pricing rather than another usage ledger.
Prior art: reference repository `analytics/chargeback-cost.kql` uses disjoint input,
output and cache costs, null unknown prices, retained historical attribution.
Its aggregate cached metrics and current-membership remapping are NOT copied:
our request ledger preserves request-time attribution and does not invent streamed cache.

Embed a source-controlled reporting rate card, pinned USD list prices, excluding
Fable/Mythos until exact Foundry IDs/prices are independently verified. No inference
from family names, no price lookup API, no budget reconciler required.

Read actual Graph group `id,displayName` once per group during quickstart build.
Preserve case, punctuation and spacing in deploy-only workbook metadata. The owner's
revised ownership prohibits edits to sync/resolver/policy. Existing baseline traces
have no group ID: the workbook explicitly labels the current metadata association
`current_mapping_historical_unverified`, never silently claims request-time mapping.
Future request group ID/name snapshots take precedence and remain stable historically.
A name read failure never changes admission.
No developer directory lookup is introduced: the authorized Entra object ID stays
the person key; no fabricated display names. Never embed directory/customer data
in generated source content. Filters are display filters, not authorization.
Model family is inferred from the `claude-{haiku|sonnet|opus|fable|mythos}` prefix
for reporting only, independently of the family-quota implementation.

Quickstart step 2 builds full serialized workbook content. Step 3 refuses missing
generated content rather than replacing a full workbook with an empty shell.
Direct incremental Bicep deployment without content leaves the existing workbook
untouched; this is not a preservation guarantee for ARM complete-mode deployments.

## Consequences and detectors

List-price reporting is not Azure settlement or dollar-budget enforcement.
Unknown cache/TTL/geography/usage produces explicit partial/unpriced lower bounds.
Existing unbuffered streams remain partial; ADR-0022 is still only a proposal.
Synthetic tests cover escaping, rename/history, reconciliation, cache TTL costs,
missing usage, unknown prices, duplicate/conflict/failure diagnostics and deployment.
Workbook access/export requires existing workspace permissions, not project RBAC.

## Offline evidence and remaining acceptance

Initial generator import failed before implementation; milestone `9c979b14`
passed 28 targeted tests, typecheck and production build. Follow-up detectors first
failed on missing full content, family/identity metadata, aggregate completeness
and complete-but-failed request diagnostics before their production fixes.
The official Microsoft Kusto language compiler caught the duplicate `PricedUsage`
declaration; the corrected ten queries have zero semantic errors. This verifies
syntax/schema semantics, not execution or portal rendering.

Final focused evidence: 139 Node reporting/accounting/existing pricing-workbook
tests; 15 chargeback quickstart, 22 baseline step, 68 baseline quickstart and
91 telemetry-ledger PowerShell checks; TypeScript typecheck/build; local Bicep
template and both parameter-file compilation. No full suite, council, Azure
deployment, live query execution or load proof is represented by those counts.
Integrated review/gates and authorized live proof remain coordinator work.

## Sources (read 2026-10-13)

- https://platform.claude.com/docs/en/about-claude/pricing
- https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- https://platform.claude.com/docs/en/build-with-claude/streaming
- https://learn.microsoft.com/graph/api/group-get
- Reference: https://github.com/naveenneog/claude-code-foundry-gateway/blob/main/analytics/chargeback-cost.kql
