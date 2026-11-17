# ADR 0040: Pipeline onboarding of a Foundry backend in both regions

Status: accepted, 2026-11-17 (branch feat/cicd-foundry-onboarding).
Related: [CICD-FOUNDRY-ONBOARDING.md](../runbooks/CICD-FOUNDRY-ONBOARDING.md),
[ADMIN-OPERATIONS.md section 7](../runbooks/ADMIN-OPERATIONS.md#7-add-another-same-tenant-foundry-backend).

## Context

Adding a Foundry account to a running deployment was manual: edit `backends[]`, rerun Stages 3, 5 and 6,
write the Cosmos descriptor by hand in Data Explorer, and repeat region B by rebuilding standby phases.
Three problems blocked automation:

1. Stage 5 replaces each Function App's complete app settings. `ADMIN_GRAPH_ENABLED` and
   `ADMIN_USER_NAMES_ENABLED` are read by the admin app (`admin/src/operations.ts`,
   `admin/src/user-directory.ts`) but were set by hand after Graph consent, so any Stage 5 rerun
   silently turned off group search and user names.
2. Only the sync identity could create `backends` descriptors; a pipeline had no least-privilege path.
3. Region B had no narrow path: the standby Grants and Config phases rebuild more than the backend.

## Decision

- **Stage 5 settings.** New optional fields `admin.graphEnabled` and `admin.userNamesEnabled` write the
  two settings; absent fields write nothing (existing configurations deploy the same settings). Before
  writing, Stage 5 lists the live settings of all four apps and refuses an apply that would drop a
  live setting the last apply did not leave and the configuration does not write
  (`stage5_settings_would_drop`), unless `stage5.allowDroppedSettings` acknowledges it. We chose explicit
  fields over copying live values so the configuration stays the source of truth and a hand-set value is
  never carried forward unseen.
- **Descriptor.** `automation.backendWriterPrincipalIds` makes Stage 3 assign the existing create-and-read
  Cosmos role (`onbProjectWriter`) on the `backends` container only. `Set-CicdBackendDescriptor.ps1`
  creates or verifies, never replaces or deletes.
- **Region B.** `Invoke-DrStandby.ps1 -Phase Backends -BackendIds` reruns region B Stage 3 and Stage 5 only
  after proving that region B inputs differ from the verified ones by the named backends alone, and only
  while region B writers are off. The Grants, Config and Code records stay; Verify must run again.
- **Workflow.** `.github/workflows/onboard-foundry.yml`: offline pull request check on a GitHub-hosted
  runner; Azure work only for `workflow_dispatch` on `main`, on the private runners with their managed
  identities, inside main-only GitHub environments (`<env>-preview`, `<env>-gate-privatelink`,
  `<env>-apply`). A private link created by another team is a manual gate. Driver state lives on the
  `cicd-state/<env>` branch; only the apply job saves it, and only after a successful restore and a
  started driver step. A GitHub-hosted `resolve` job proves the environments' protection before any
  self-hosted job is queued. The shared `ccof-env-<env>` group uses `queue: max` so a waiting run is not
  replaced (more than 100 waiting runs are cancelled).
- **Approval fails closed.** Workflow conditions and GitHub environments can be bypassed or auto-created
  without protection, so the gate and apply jobs verify, with the job token, that the environment has
  required reviewers, a `main`-only branch policy and an approval for this run before any Azure sign-in;
  the step runner refuses `-Apply` without that record. A re-run is refused because the approvals API is
  per run. The runner host's job hook is the real control against untrusted code.
- **Settings values.** Stage 5 carries the exact live value of the Stage 7 `snapshotApply` flag and
  refuses to change defaulted settings silently (`stage5_settings_would_change`); other written values
  come from the configuration.
- **Smoke.** The smoke test checks the effective policy (fragments followed, XML-decoded) for static or
  registry admission plus the managed-identity route, not a text search for the id.

## Consequences

- Operators who enabled Graph features by hand must add the two fields before the next Stage 5 apply;
  otherwise Stage 5 stops and names the setting.
- The pipeline cannot remove a backend; withdrawal is a reviewed manual procedure.
- A Foundry account in another subscription needs Reader for the preview runner identity and a role
  assignment right (or pre-assigned Cognitive Services User) for the apply identity on that account.
- Runner-level isolation (runner groups limited to selected workflows) is still required: a workflow
  that targets the runner labels gets the runner's identity regardless of this workflow's guards.
- A private repository needs GitHub Enterprise for required reviewers; on other plans the apply always fails.
- A failed apply is repeated with a new dispatch, not a GitHub re-run.
