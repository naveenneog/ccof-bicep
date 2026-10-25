# Current deployment unknowns

| ID | State | Question / evidence |
| --- | --- | --- |
| V3-N1 | RESOLVED | Graph GET `/users/{id}` application permission is `User.Read.All`; request only `id,displayName,userPrincipalName`. Source: [Get user](https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0), retrieved 2026-10-22. Grant to the admin managed identity, not the SPA or sync identity. |
| V3-N2 | ASSUMED | Names are current directory labels, not historical attribution. Object IDs remain authoritative. Memory-only bounded five-minute caches; no PII in persisted data or logs. Failed lookups retain IDs and show an explicit state. |
| S1-01 | RESOLVED | Azure accepted private/keyless Flex shells without runtime grants or network attachments in the tested lab configuration. Deployment and all-app read-back passed; see [live evidence](STAGE1-LIVE-VERIFICATION.md). Customer-policy compatibility remains unverified. |
| S1-02 | RESOLVED | New APIM cannot be treated as a private-only no-network shell. This proof leaves `approveNewPublicApimBootstrap=false`; APIM is explicitly deferred. See the existing [staged runbook](runbooks/STAGED-CUSTOMER-DEPLOYMENT.md). |
| S1-03 | ASSUMED | The authorized live proof uses a fresh RG in the isolated lab subscription already used by this session. It does not modify existing CCOF resources. Capacity/policy results apply only to this lab, not customer environments. |
| S1-04 | RESOLVED | Existing deployment paths bundle settings/grants/networking and are not Stage 1 substitutes. The recursive checks in `tests/Test-StagedCustomerDeployment.ps1` cover the separate `infra/staged` entry point. |
