# ADR 0033: Active/passive disaster recovery across East US 2 and Central US

Status: proposed, 2026-10-23. Design: [DR-ACTIVE-PASSIVE.md](../DR-ACTIVE-PASSIVE.md).
The implementation request refines backend pools to **per-project opt-in** and adds prerequisite-first
execution; [ADR 0034](0034-dr-project-routing-and-prerequisites.md) supersedes that part of this proposal.

CCOF runs in one region. Losing that region stops the gateway, entitlement reads, usage logging and
budget reconciliation.

Decision:

- Azure Front Door Premium with a WAF policy and built-in DDoS protection in front of two separate
  APIM Standard v2 instances (East US 2 active, Central US passive). Private Link supplies private
  inbound gateway access; outbound VNet integration supplies backend access. This is not Standard v2
  VNet injection. Premium v2 remains an alternative, not a requirement.
- One Cosmos DB account with provisioned throughput, East US 2 as the write region and Central US as
  the read region. Session consistency (unchanged) and service-managed failover.
- One Log Analytics workspace in East US 2, replicated to Central US. Switchover is manual, as Azure
  Monitor requires.
- Budget enforcement stays fail-closed. After failover the reconciler restarts only after a ledger
  continuity gate passes.
- Each APIM uses model-specific priority pools with per-member circuit breakers: compatible local
  Foundry endpoints first, approved remote endpoints next. Private network paths and identity grants
  cover all members. Claude quota stays shared per subscription. Breaker state is not globally shared,
  and a partially delivered generation stream is not replayed.

Rejected:

- **East US + West Central US.** APIM Premium v2 isn't offered in either region, and West Central US
  is not a Log Analytics replica location.
- **Active/active.** APIM token-limit counters are per instance, which would multiply per-person limits.
- **Strong consistency over two regions.** It loses write availability when one region fails.
- **A budget grace mode during logging outages.** It weakens a control and needs separate approval.

Consequences: the ledger, workbook and admin queries must read several APIM resource IDs. The
staged deployment gains a second-region option and backend-pool configuration. The ledger must retain
the actual serving backend's identity and inference geography. A failover runbook and a lab drill
are required before production use. The diagram is a proposal, not a deployment record.

Sources: [APIM v2 regions](https://learn.microsoft.com/azure/api-management/api-management-region-availability),
[APIM features by tier](https://learn.microsoft.com/azure/api-management/api-management-features),
[workspace replication](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication),
[Cosmos reliability](https://learn.microsoft.com/azure/reliability/reliability-cosmos-db),
[Claude regions](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-from-partners#region-availability-by-deployment-type),
[Claude quota scope](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/claude-models-quotas-limits),
[Front Door and APIM Private Link](https://learn.microsoft.com/azure/frontdoor/standard-premium/how-to-enable-private-link-apim),
[backend pools and circuit breakers](https://learn.microsoft.com/azure/api-management/backends).
