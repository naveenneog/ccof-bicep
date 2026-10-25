# Deployment packets

| Packet | Status | Acceptance |
| --- | --- | --- |
| V3-names | Complete | Names plus full IDs across V3; authenticated Graph lookup with explicit failures; admin-only VDI upgrade guide |
| Stage 1 resources-only proof | Complete | Compile and inspect templates, deploy new lab services, verify live properties, document permissions and evidence |
| Later-stage separation | Not started | Separate network, schema, grants, Entra, settings, packages and acceptance into explicit stage interfaces |
| Admin V3 Azure acceptance | Pending | Verify deployed root redirect, Entra sign-in, real telemetry and onboarding settings |
| Admin V3 scale/accessibility | Pending | Measure 10,000-project behavior and perform assistive-technology checks |

Later stages are not implicitly executed by the Stage 1 proof.

- [x] S1 — Verify and document the resource-only Stage 1 in Azure.
- [ ] S2 — Implement later-stage entry points with their permission boundaries.
- [ ] V3-live — Complete Admin V3 Azure acceptance.
- [ ] V3-scale — Measure scale and accessibility.
