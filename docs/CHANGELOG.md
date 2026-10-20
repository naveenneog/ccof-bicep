# Change log

## 2026-10-20 — Stage 1 resources-only proof

- Completed live provider verification of the existing staged templates in an
  isolated new lab RG: 20 template resources at read-back (Application Insights
  later auto-added four Failure Anomalies alert rules, recorded in the report);
  all four private/keyless service checks pass, and no schema, application settings or runtime grants were created.
  Existing inference/admin deployments were not write targets. APIM is deferred.
- Added a scoped work ledger and local Ironclad charter/gate without installing
  hooks or changing CI. The stage contract remains the existing resources-only
  template and recursive offline test.
- Added the Stage 1 [live report](STAGE1-LIVE-VERIFICATION.md) and
  [permission/configuration/runbook](runbooks/STAGED-DEPLOYMENT-V2.md).
- Full packet gate, root regression/type-check/build and 95 admin tests pass.
  Later-stage entry points, Admin V3 Azure acceptance and scale/accessibility
  verification remain pending.
