# ADR-0028: Integrate the frozen family contract without parallel implementations

- **Status:** Accepted for integration (owner instruction, 2026-10-13)
- **Date:** 2026-10-13
- **Packet:** WP-CORE-INTEGRATION
- **Amends:** legacy modelAllowList/tokenLimits descriptions in ADR-0017/0018 and PILOT.
- **Preserves:** ADR-0019 staged handoffs, ADR-0024 quickstart, ADR-0025 reporting,
  ADR-0026 combined public client and separate internal resolver.

## Context and decision

The owner requires one testable bundle of the existing independently produced modules,
not another implementation. The frozen contract at `cb6967e` replaces legacy policy
fields with a required validated familyPolicy. Exact model registration determines
admission; family prefixes never grant permission. Fable/Mythos require authoritative
classification exactly CYB. Decision version 3 and cache namespace d3 isolate old allows.
Aggregate ceilings remain additional to family ceilings, not divided among families.

Cherry-pick published commits only; deduplicate the shared validator's equivalent
commits. Never read dirty producer changes into the integration tree. The integration
branch is an acceptance candidate, not a deployment approval or customer change.

The reconciler's private modelAllowList pricing input must be derived from the validated
familyPolicy's exact registered models. Keeping its legacy project reader would silently
stop writing budget states for every newly seeded project. Reuse the shared pure validator;
reject legacy/mixed project fields, preserve CCU budget calculation and failure isolation.
Migrate fixtures, never relax the required boolean budget.exhausted schema.

Quickstart groups select a registered backendId explicitly when multiple backends exist;
groups within a project must agree. Single-backend omission remains compatible. Client
exports require an explicit project/classification and choose only the intersection of
that policy and that backend's deployment keys. Both onboarding.json and client-config.json
use the existing strict client schema. Graph display names are exact informational snapshots,
never authority. The combined client/gateway registration remains separate from the resolver.

The fixed-price workbook is reporting, not settled Azure cost or budget enforcement.
Full content must exist and verify before step 3; -Only 3 never replaces it with a shell.
Manual deployment reuses modules and preserves staged authority boundaries.
The preparatory bounded load driver defaults to its controlled local mock and is
discovered by the existing test runner through an approved root shim. Remote use
requires explicit isolated-mock prerequisites; it cannot prove backend isolation
by operator attestation alone. Keep the existing explicitly confirmed paid-inference
smoke separate. This integration packet runs unit tests, not the load command.

## Alternatives and consequences

Merging unfinished worktrees or rebuilding modules would duplicate ownership and erase
test provenance; both are rejected. Integration-only compatibility changes get failing
tests before production changes. Published producer versions and actual gate/review outcomes
are recorded in STATUS. Offline suites and Kusto/C# compilation do not establish Azure
deployment, live token acquisition, query execution, streaming, or load acceptance.
The final coordinator alone promotes after acceptance and authorized live proof.
The owner's subsequent integration correction identified the published live-fix chain
`803edc0` → `ce5b6f9`: use Function App module outputs for newly created App Insights
and resynchronize triggers while registrySeed remains unlisted. Integrate both in
dependency order; family seeding, readback, cleanup and full-workbook guards remain.
Record targeted checks on the resulting exact candidate, not the earlier gate tree.

Baseline no-run audit: PASS, 20 passed / 2 warnings (quickstart file size and 61 open
historical unknowns). Release must report remaining unknowns honestly, not close them
by assertion or weaken the charter. Five bounded independent council seats remain required.
