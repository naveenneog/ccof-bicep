# Current deployment unknowns

| ID | State | Question / evidence |
| --- | --- | --- |
| S1-01 | RESOLVED | Azure accepted private/keyless Flex shells without runtime grants or network attachments in the tested lab configuration. Deployment and all-app read-back passed; see [live evidence](STAGE1-LIVE-VERIFICATION.md). Customer-policy compatibility remains unverified. |
| S1-02 | RESOLVED | New APIM cannot be treated as a private-only no-network shell. This proof leaves `approveNewPublicApimBootstrap=false`; APIM is explicitly deferred. See the existing [staged runbook](runbooks/STAGED-CUSTOMER-DEPLOYMENT.md). |
| S1-03 | ASSUMED | The authorized live proof uses a fresh RG in the isolated lab subscription already used by this session. It does not modify existing CCOF resources. Capacity/policy results apply only to this lab, not customer environments. |
| S1-04 | RESOLVED | Existing deployment paths bundle settings/grants/networking and are not Stage 1 substitutes. The recursive checks in `tests/Test-StagedCustomerDeployment.ps1` cover the separate `infra/staged` entry point. |
