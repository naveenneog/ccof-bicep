# DR implementation: prerequisites, project routing and staged proof

Branch: `feat/CCOF-DISASTER-RECOVERY`. Baseline: `63ca876`.
Contract: [ADR 0034](../adr/0034-dr-project-routing-and-prerequisites.md).
The [architecture diagram](../DR-ACTIVE-PASSIVE.md) is a proposed target, not deployed DR.

## Implementation boundary

Existing deployments continue to work with failover disabled. The first live action is read-only
inventory. Resource IDs, account identities and discovery evidence are stored in private environment
handoffs, not in this public repository. No inference-spend exercise is part of discovery.

| Test environment | Intended use | Ownership boundary |
| --- | --- | --- |
| SASET | Positive Claude calls and later continuity comparisons | Existing shared RG; only explicitly scoped CCOF resources can be changed |
| Contoso | Negative cases and infrastructure acceptance | Existing sandbox restriction prevents a successful Claude purchase; never counted as inference acceptance |
| Supplied third subscription | Additional same-tenant Foundry/APIM compatibility and failure tests | Existing APIM and Foundry are discovery-only until an approved adoption manifest lists allowed changes |

The supplied third environment and SASET have the same tenant identifier but different
subscriptions. Contoso is a different tenant and remains an isolated test environment; its
endpoints are not automatically inserted into a SASET project pool.

Read-only discovery on 2026-10-23:

| Environment | Result | Meaning |
| --- | --- | --- |
| SASET | APIM Standard v2 and Foundry in East US 2; two deployments listed | Resource visibility only; no new model calls, failover or standby test |
| Contoso | APIM Standard v2 and Foundry in East US 2; zero deployments listed | Infrastructure/negative tests only; no positive model proof |
| Supplied third subscription | ARM subscription metadata and the exact APIM, Foundry and deployment-list reads returned HTTP 403 with the tenant-pinned lab profile | Access blocker for this identity; not evidence that the resources do not exist. Reader at the target scope is the initial discovery prerequisite; later deployment/consent permissions are separate |

Detailed IDs and responses are in session-private `dr-implementation` inventory files, not git.

## Implemented and proven (2026-10-23)

| Area | Implementation | Evidence |
| --- | --- | --- |
| Routing contract | `src/contracts/project-routing.ts`: `failover` field, pool/member IDs (slug + hash of the exact project ID), registry and breaker validation, compatibility | `tests/project-routing.test.ts`; mutation checks 15/15 caught |
| Sync / resolver | Membership `routeBackendId` only while enabled and verified; resolver forwards only the pool pattern | `tests/sync-plan.test.ts`, `tests/resolver-freshness.test.ts` |
| Gateway | Live and cached decisions validate `routeBackendId` (fail closed); managed-identity branch forwards to it | 325 compiled C# vectors in `tests/gateway-family-quotas.test.ts` |
| Admin 3.3 | Backends page (optional breaker), project failover, `routing/pending`, `routing/{id}/publication`, write-ahead change records | `admin/tests/backend-routing.test.ts`; Edge check of the UI |
| Publisher | `infra/dr/Publish-ProjectRouting.ps1`: members, pool, read-back, then publication | `tests/Test-ProjectRouting.ps1` |
| Prerequisites P0-P2 | `infra/dr/Invoke-DrPrerequisites.ps1` (Discover, Bootstrap, Verify) and `dr-prerequisites.bicep` | `tests/Test-DrPrerequisites.ps1` |

Live results:

| Environment | Result |
| --- | --- |
| Contoso | P0 passed except the known blocker (no Claude deployment). P2 in Central US: VNet with delegated APIM/Functions subnets, private-endpoint subnet, links to the five primary DNS zones, two-way peering `Connected`, identities `sync-b`/`reconciler-b`. Wrong prefix, missing identity and wrong tenant all failed closed. Stages 5 and 7 deployed admin 3.3 and the fragment policy. Publisher negative: a registry URL that differs from the project's APIM backend was refused, the project stayed unpublished and no pool entity was written |
| SASET | P0 passed. P2 in Central US in the existing resource group (no resource-group create right; recorded opt-in). Stages 5 and 7 deployed admin 3.3 and the new gateway policy. SASLAB1 proof: pool member primary served 200; primary member broken (404) tripped its breaker and the fallback member served 200; restored primary served 200; failover off returned routing to `foundry-lab1`. Quotas raised for the test and restored, all in the change record |
| Third subscription | Still HTTP 403 on subscription, resource group, Foundry and APIM for the lab identity; Reader on `rg-lab3` is required before P0 |

Limits observed:

- SASET has one Claude account, so the fallback entry points at the same account. The proof
  covers routing, breaker scope and publication, not regional independence.
- The request that trips a breaker is returned to the client; APIM breaker state is per gateway
  node. A policy-level retry is a separate decision (streamed bodies).
- From 2026-10-23 both Standard v2 gateways refused API policy documents over 16 KiB, including
  the unchanged live policy; the documented v2 limit is 512 KiB
  ([service limits](https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits)).
  `infra/quickstart/modules/apim-api.bicep` now deploys each policy section as a policy fragment
  ([include-fragment](https://learn.microsoft.com/azure/api-management/include-fragment-policy)).
- Pending: standby regional shells and data (DR-07), Front Door, and the region drill (DR-08).
The third subscription was absent from the CLI cache; the direct ARM reads distinguish cached
subscription discovery from actual resource authorization. No default Azure profile was used.

## Prerequisite handoffs

### Entra app registrations

These are same-tenant shared application contracts across both DR regions. Each environment still
has its own approved application IDs. Existing registrations are reused only by exact ID.

| Suggested name | Purpose | Required configuration | Owner / evidence |
| --- | --- | --- | --- |
| `CCOF Gateway <environment>` | Developer token audience for both regional APIMs and `/ccof-usage/me/usage` | Single tenant; URI `api://<gateway-client-id>`; enabled delegated `access_as_user`; token version 2; public-client redirects `http://localhost` and `ms-appx-web://Microsoft.AAD.BrokerPlugin/<gateway-client-id>` for the approved helper flow; self-preauthorization plus Azure CLI preauthorization for CLI acceptance; no secret | App owner/admin; app and service-principal IDs, scope ID and approved redirect list |
| `CCOF Resolver API <environment>` | APIM managed-identity token audience | Single tenant; URI `api://<resolver-client-id>`; token version 2; no developer-facing redirect or client secret | App owner; both APIM caller application/principal pairs included in resolver platform authorization |
| `CCOF Admin <environment>` | Admin UI and API | Single tenant; URI `api://<admin-client-id>`; token version 2; `Projects.Manage` admin-consent delegated scope; `CCOF.Projects.Read` and `CCOF.Projects.Write` user/group roles; assignment required; SPA redirect `https://<stable-admin-host>/api/console-v3` and `/api/console`, plus approved retained regional hostnames; self and approved acceptance-client preauthorization; no secret | App owner and role-assignment owner; scope, role and recipient principal IDs |

Azure CLI client ID is `04b07795-8ddb-461a-bbee-02f9e1bf7b46`. Preauthorization, runtime client
allow-listing and user app-role assignment are distinct checks. Corporate Conditional Access stays
in effect. Source: [deployment runbook](../runbooks/DEPLOYMENT-RUNBOOK.md#1-entra-administrator-handoff).

### Groups and managed identities

| Object | Configuration | Access / gate |
| --- | --- | --- |
| Project classification group | Existing security group, exact object ID, owner, direct user membership | One approved group per classification; no nested expansion |
| Admin reader/editor assignment | Roles on the admin enterprise application | Directory labels do not grant model access |
| APIM A and APIM B | Separate identities; record both client/application IDs and principal IDs | Cognitive Services User on every explicitly eligible Foundry account; resolver allows only the approved APIM callers |
| Resolver A/B | Separate managed identities | Cosmos reader, own storage/telemetry; regional Cosmos read preference |
| Admin A/B | Separate managed identities | Project/config read-query-create-replace, own telemetry; Graph `GroupMember.Read.All` and `User.Read.All`; standby writes fenced |
| Sync A/B | User-assigned identity or approved reuse | Graph `GroupMember.Read.All`, `User.Read.All`, `Application.Read.All`; current scoped Cosmos and own storage grants; standby timer disabled |
| Reconciler A/B | User-assigned identity or approved reuse | Shared ledger read and scoped budget/lease writes; standby timer disabled |
| Routing publisher | Operator identity initially; managed execution requires a separate role grant | Custom role for approved APIM backend entities, not subscription Contributor; the browser never receives ARM authority |

The current resolver, admin and APIM use system-assigned identities, which exist only with their
parent resources. Therefore "identities first" has two supported design paths:

1. Retain system identities and create minimal, deployment-owned service shells during prerequisite
   bootstrap; grant access before runtime deployment.
2. Import precreated UAMIs after DR-06 adds and tests credential/client-ID wiring. The existing
   templates cannot silently substitute UAMIs today.

Each handoff states which path is used. No synthetic principal IDs or manually fabricated stage
state are accepted. Graph consent belongs to the tenant administrator, not the subscription owner.

### Network readiness

| Boundary | Required preparation | Gate before runtime |
| --- | --- | --- |
| Regional VNets | Non-overlapping CIDRs; approved hub/peering/firewall routes | Private reachability to all approved local and remote pool members; DNS alone is insufficient |
| APIM integration subnet per region | Dedicated subnet; `Microsoft.Web/serverFarms` delegation for Standard v2 | Outbound integration, NSG and approved egress; not VNet injection |
| Functions integration subnet per region | Separate subnet; `Microsoft.App/environments` delegation for Flex | Runtime and publishing/deployment storage paths verified |
| Private-endpoint subnet per region | Undelegated; capacity for Foundry, Cosmos, Monitor, Function sites/SCM and app storage endpoints | Approved PE connections; addresses from actual endpoint NICs |
| Private DNS | Foundry `services.ai`, `cognitiveservices`, `openai`; Cosmos `documents`; Functions `azurewebsites`; blob storage; Azure Monitor zones required by AMPLS | Regional VNet links and corporate/VDI DNS forwarding; test names from actual callers |
| Front Door Premium | Custom domain/certificate owner; WAF policy; managed Private Link origins to APIM and admin apps | Origin approval and end-to-end TLS before disabling public origin access |
| Azure Monitor | One workspace with supported shadow region; AMPLS and regional query PEs | Corporate users and both writer regions can query privately; diagnostic ingestion is a separate Microsoft-managed path |

Front Door is a public edge. Its managed origin PEs are not NICs in customer subnets. Cosmos,
Foundry and Log Analytics remain managed services outside the VNets.
Sources: [network handoff](../runbooks/DEPLOYMENT-RUNBOOK.md#2-network-handoff),
[Front Door Private Link](https://learn.microsoft.com/azure/frontdoor/standard-premium/how-to-enable-private-link-apim),
[AMPLS network controls](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-design#control-network-access-to-ampls-resources).

### Private environment handoff contract

Before any apply, the environment record contains:

- Tenant/subscription IDs, exact existing resource IDs, create/reuse/discovery-only ownership.
- App registration/client, service-principal, scope, role, group and managed-identity IDs.
- Primary/standby locations, VNet/subnet/DNS IDs, endpoint approvals and network test evidence.
- Approved logical/physical backend IDs, deployed model versions, deployment aliases, authentication,
  geography, billing attribution and grant scope for each APIM caller.
- Deployment and runtime identities, stage permissions, artifact hashes and last verified revision.
- Proposed changes, cost ceiling, permitted test failure injections, recovery owner and rollback.

Secret values, tokens and customer email lists are not handoff fields. Identity/network preparation
does not confer permission to rewrite an existing APIM policy, stop a shared endpoint or remove a
resource. The apply plan lists exact write targets.

## Optional project failover in the admin console

| Admin action | Result |
| --- | --- |
| Register a backend | Records an approved existing Foundry deployment; does not create/purchase a model or give every project access |
| Select a project's primary backend | Preserves today's explicit `backendId` assignment |
| Leave failover off | No new pool/breaker is created or used for that project |
| Enable backend failover | Admin selects ordered compatible fallback backends from approved registry entries |
| Review and save | Permission, compatibility and ETag checks; write-ahead audit; publication status is pending |
| Publish and verify | Authorized publisher applies a project/revision-specific pool in both regional APIMs; only verified configuration becomes active |
| Disable failover | New requests return to the verified direct route after the bounded cache window; active streams drain |

The choice is a fallback target, not "a backend acting as the circuit breaker". The breaker
detects configured failures on a member and temporarily excludes it. Eligible routing is never
expanded by failure. A model mismatch, disabled endpoint, self-reference, duplicate fallback,
unapproved geography, missing caller grant or incomplete publication blocks activation.

Projects with failover off must not inherit another project's breaker via a shared backend entity.
Pool/member entities are scoped to the project routing revision. Actual serving account,
subscription, deployment and inference geography stay available for chargeback.

## Prerequisite-first DR stages

This is a new, gated DR workflow. The current `Invoke-StagedDeployment.ps1` stage numbers stay
unchanged; the table is the implementation contract, not an executable CLI available today.
Cosmos is one **multi-region account with one write region**, not two independent databases or
multi-writer active/active. Application-writer fencing is additional to database-region failover.

| Stage | Owner permission | Observable exit condition |
| --- | --- | --- |
| P0: discover | Read-only ARM/directory | Tenant/subscription matches, resource ownership and service/model availability recorded; any denial is a blocker |
| P1: identity bootstrap | App/group owner, identity RG write and approved shell creation | Apps, groups and MI inventory exists; roles/consent can be requested against real principals |
| P2: network bootstrap | Network/DNS contributor at explicit scopes | Both regional networks, PEs, routes and DNS pass configuration and caller-path checks |
| P3: access handoff | Scoped RBAC/Cosmos grant owner; tenant consent authority separately | Grants/consent read back; each stage operator uses its own isolated Azure profile |
| D1: data and service shells | Contributor on deployment-owned resources only | Provisioned single-writer Cosmos/replica, workspace replication and regional shells; no standby writers |
| D2: schema and configuration | Cosmos ARM/schema and service configuration writer | Correct partition keys, two-gateway ledger scope, runtime settings, resolver caller allow-list and backend registry |
| D3: code and routing publication | App publisher and scoped backend publisher | Identical approved packages, routing revision verified in both APIMs, standby timers off; create-only seed never overwrites admin data |
| D4: edge cutover | Front Door/domain/certificate owner | Origins private, WAF qualified, gateway/usage/admin paths work; direct origin bypass refused |
| D5: acceptance | Authorized user and telemetry reader | Positive/negative calls, exact accounting, permission and publication-failure cases pass |
| D6: failure drill | Explicit approval for each failure injection | Backend failure, regional origin failure, database failover, workspace switchover and failback proven separately |

D1 can precede completion of PE approvals only where P2 explicitly records a deferred target
resource ID. Runtime deployment never treats a pending PE as network readiness.
System-identity shells required by P1 are reused by D1, not recreated.

## Test sequence and non-negotiable gates

1. Offline negative tests: default-off compatibility, unauthorized admin writes, stale ETags,
   publication partial failure, incompatible targets and no arbitrary endpoint/secret input.
2. Lab backend exercise: two approved endpoints; one project opts in and another stays direct.
   An open breaker may change only the opted-in project's eligible selection.
3. Chargeback comparison: response usage, `/usage`, reconciler state, admin table and CSV agree for
   actual serving members. Usage from both APIM IDs is included once.
4. Prerequisite drill: a wrong tenant/profile, missing consent, wrong DNS address, unapproved PE or
   inaccessible remote endpoint fails the gate without changing security settings.
5. Region drill: no automatic promotion of standby writers; stable client hostname, independent
   counter behaviour and interrupted streams are observable.
6. Logging drill: missing early-month or recent usage cannot lower persisted spend. A recent record
   or successful KQL query is not proof of completeness. Workspace replication does not backfill.
7. Failback: first fence the outgoing writer; restore verified routes and check that spend,
   entitlements and audit records persist. Replicated Cosmos leases alone do not fence regions.

Test resource metadata and inference success are separate outcomes. Contoso remains negative-only
until its Marketplace restriction is removed. An additional subscription does not imply an
independent quota or approved cross-project fallback.

## Packet and evidence record

DR-01 records the design, unknowns and read-only discovery. Later packets in
[ROADMAP.md](../ROADMAP.md) use test-first implementation, five-role review where required,
the repository gate and a focused commit. No claimed recovery-time or zero-loss guarantee precedes
an actual drill. No infrastructure or application behaviour changes are made by this document.
