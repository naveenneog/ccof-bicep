# Lower-level contract overview

The current integrated contracts are described in
[ADR-0028](adr/0028-core-module-reconciliation.md), the
[family-policy design](design/model-family-quotas.md) and
[architecture overview](ARCHITECTURE.md).

The resolver point-reads entitlement, project, budget state and the selected backend.
Sync projects the strictly validated family policy with generation/freeze/removal
safeguards. The reconciler derives its pricing model set from the same exact registered
models. Gateway decision version 3 preserves aggregate limits and adds family ceilings.
Identifiers and exact configured Entra names are never guessed.

### `projects`

The following is a **budget-field excerpt**, not a deployable registry document.
Complete projects also require identity, routing, classification and strict family
policy fields; use the customer form and accepted contract, not this excerpt.
These illustrative values preserve the historical CCU/USD unit-conversion examples.
They are not negotiated prices or a dollar-enforcement guarantee.

```json
{
  "id": "EXAMPLE01",
  "classifications": {
    "STD": {
      "personBudget": { "amount": 25000, "currency": "CCU", "period": "monthly" },
      "aggregateBudget": { "amount": 2000000, "currency": "CCU", "period": "monthly" }
    },
    "PRM": {
      "personBudget": { "amount": 100000, "currency": "CCU", "period": "monthly" },
      "aggregateBudget": { "amount": 1500000, "currency": "CCU", "period": "monthly" }
    },
    "CYB": {
      "personBudget": { "amount": 250000, "currency": "CCU", "period": "monthly" },
      "aggregateBudget": null
    }
  }
}
```

Fixed list-price reporting, partial streamed-cache observations and unsettled billing
must remain distinguishable. Customer retention, geography, grants and capacity need
separate decisions; local fixtures and mock load do not supply those decisions.
