// Contextual help, shown in the Help drawer for the current page and listed on the Help page.
export interface HelpTopic { title: string; summary: string; figures?: [string, string][]; permissions?: string[]; troubleshooting?: [string, string][] }

export const HELP: Record<string, HelpTopic> = {
  overview: {
    title: "Overview",
    summary: "Where to look first: this month's list-price cost by model family, budgets near or over their limit, telemetry coverage, health concerns and the latest changes.",
    figures: [
      ["Known cost", "List price of the usage that could be priced. When some usage can't be priced, this is a lower bound and the complete figure stays blank."],
      ["Blank is not zero", "A dash means the amount is unknown (unpriced, unattributed or no data), never that nothing was spent."],
      ["Coverage", "Whether every observed request was priced and attributed. 'Incomplete' means some were not; open Chargeback → Unpriced."],
      ["Budgets near limit", "Access groups at 80 % or more of their monthly budget, from the reconciler's latest calculation."],
      ["Cost breakdown", "Month-to-date known cost by project. Select a project slice (or legend row) to split it by classification (STD, PRM, CYB, ...), then select a classification. The users and models split beside the chart follow the selection. Tags select projects that carry all chosen tags."],
    ],
    permissions: ["Chargeback: Log Analytics Reader on the gateway telemetry workspace.", "Budgets and reconciler: Log Analytics Reader on the workspace with the reconciler's logs.", "Audit: Log Analytics Reader on the admin app's workspace."],
    troubleshooting: [["A panel says 'not configured'", "That integration's app setting is missing. Each panel names the setting or role it needs; the rest of the console still works."]],
  },
  projects: {
    title: "Projects",
    summary: "Every project in the registry, searched and filtered on the server and paged 25 at a time, so the list stays fast with 10,000 projects.",
    figures: [
      ["Tags", "Admin tags. Selecting several tags shows projects that carry all of them."],
      ["Backend", "The Foundry backend (APIM backend ID) the project routes to today."],
      ["Budget used", "The highest share of monthly budget used by any of the project's access groups, from the reconciler."],
    ],
    permissions: ["Reading: the CCOF.Projects.Read role (or the reader list). Creating and editing: CCOF.Projects.Write."],
    troubleshooting: [["The registry is unavailable", "The admin app can't reach Cosmos DB: check its private endpoint, DNS and the Cosmos data role of its managed identity."]],
  },
  project: {
    title: "Project",
    summary: "One project: its models and token limits per access group, the access groups themselves, budgets with the budget assistant, settings and recent activity.",
    figures: [
      ["TPM", "Tokens per minute, enforced by the gateway per person and per group."],
      ["Quota", "Tokens per period (usually monthly). Empty means no quota."],
      ["Aggregate limits", "Limits across all model families of the access group, on top of each family's own limit."],
      ["Person / group budget", "Monthly spend caps in USD or CCU (100 CCU = USD 1). Strict mode blocks when exhausted; notify only reports."],
      ["Onboarding", "Per classification, download config.json (the CCOF helper's client configuration, with this project's selector header and allowed models) and onboarding.json (group, install paths and steps). No secrets are included. Missing admin settings (ADMIN_CLIENT_ID, ADMIN_GATEWAY_URL, ...) are listed and filled with REPLACE- placeholders the client refuses."],
    ],
    permissions: ["Editing needs CCOF.Projects.Write. Every save shows the field-level change first and is sent with the version tag (If-Match), so a concurrent change is never overwritten."],
    troubleshooting: [
      ["'Someone else changed this'", "The project changed after you opened it. Reload, then make your change again."],
      ["Changes don't reach developers", "Limits reach the gateway after the next entitlement sync run."],
    ],
  },
  "new-project": {
    title: "New project",
    summary: "Create a project in four steps: basics, access groups, models and budgets (with the budget assistant), and a final review of the document that will be saved.",
    figures: [["Access group", "An Entra security group. Members get the classification's models and limits. Paste its Object ID; directory search needs Microsoft Graph."]],
    permissions: ["CCOF.Projects.Write."],
    troubleshooting: [["The registry refused the project", "The review lists each problem by field path, for example classifications.STD.groupId:invalid."]],
  },
  chargeback: {
    title: "Chargeback",
    summary: "The chargeback workbook's figures inside the console, computed server-side from the same ledger, pricing and rate card. The browser never sends a query; filters are validated and bound on the server.",
    figures: [
      ["Period", "UTC and half-open: [start, end). Custom ranges are capped (62 days by default)."],
      ["Known list cost", "Sum of priced usage at the approved rate card. List price, not an invoice."],
      ["List cost (complete)", "Shown only when every request was priced and attributed; otherwise blank."],
      ["Coverage state", "observed_token_usage_complete, incomplete, retention_truncated or no_data_not_zero."],
      ["Foundry backend", "The backend recorded on each request at request time, not the project's current backend."],
      ["Model family", "Derived from the model ID (claude-<family>-…), as in the workbook."],
      ["Truncated", "A view returned its row cap; export and paging say so."],
    ],
    permissions: ["Log Analytics Reader on the gateway telemetry workspace (ADMIN_CHARGEBACK_WORKSPACE_ID or ADMIN_WORKSPACE_ID) and ADMIN_GATEWAY_RESOURCE_ID set."],
    troubleshooting: [
      ["Costs are blank", "Open Unpriced: rows show the reason, such as no_rate_in_force or geography_not_in_rate_card."],
      ["Figures differ from the workbook", "Check the period and the rate card version shown on both; the console and the workbook use the same query builder."],
    ],
  },
  budgets: {
    title: "Budgets",
    summary: "Today's group and person budgets from the reconciler, with a burn-down for each access group against its monthly budget.",
    figures: [
      ["Spent", "Month-to-date spend calculated by the reconciler at the approved rate card, in CCU with the USD equivalent."],
      ["Snapshot state", "current (valid now), expired (validUntil passed: the reconciler is late), historical (an earlier period)."],
      ["Partial", "Some usage could not be priced, so spent is a lower bound."],
    ],
    permissions: ["Log Analytics Reader on the workspace receiving the reconciler's logs (ADMIN_WORKSPACE_ID, ADMIN_LOG_RESOURCE_IDS)."],
    troubleshooting: [["Snapshots are expired", "The reconciler hasn't written state recently: open Reconciler and check the latest run's outcome."]],
  },
  reconciler: {
    title: "Reconciler",
    summary: "The budget reconciler's runs and the budget state it wrote, person and group scope, with filters and server-side paging.",
    figures: [
      ["Latest run per outcome", "The most recent run that wrote state, skipped (lease held), or failed."],
      ["Age vs interval", "On schedule within two timer intervals, late within six, stale after that."],
      ["Ingestion delay", "The longest delay between a request and its log becoming queryable during the run."],
      ["Unattributed / unpriced", "Requests the reconciler couldn't charge to a person or price; budgets are then lower bounds."],
    ],
    permissions: ["Log Analytics Reader on ADMIN_WORKSPACE_ID; reconciler logs routed there (ADMIN_RECONCILER_RESOURCE_ID or ADMIN_LOG_RESOURCE_IDS)."],
    troubleshooting: [["No runs appear", "Check the reconciler's diagnostic settings send FunctionAppLogs (or Application Insights traces) to the workspace."]],
  },
  foundry: {
    title: "Foundry",
    summary: "Foundry accounts, APIM backends and model deployments, with the projects that use each backend. A resource marked not_found lists the projects it affects.",
    permissions: ["Reader on the APIM instance and Foundry accounts (ADMIN_RESOURCE_IDS or ADMIN_DISCOVERY_SCOPES)."],
    troubleshooting: [["Inventory is disabled", "Without Reader access you can still type backend IDs by hand in project settings."]],
  },
  health: {
    title: "Health",
    summary: "Separate signals, each with its own observation time: endpoint probes, the reconciler's freshness, telemetry freshness and which integrations are configured.",
    figures: [["Endpoint responding", "An HTTP response only; it doesn't prove model inference, billing or timer freshness."]],
    permissions: ["Probes: ADMIN_HEALTH_TARGETS and a private network path."],
  },
  audit: {
    title: "Audit",
    summary: "Every change and refusal made through the admin API, searchable by project, actor, operation, outcome and date, with before → after values.",
    permissions: ["Log Analytics Reader on the admin app's own workspace (ADMIN_AUDIT_WORKSPACE_ID when it differs from ADMIN_WORKSPACE_ID)."],
    troubleshooting: [["My change isn't listed yet", "Log ingestion takes a few minutes."]],
  },
  "cost-definitions": {
    title: "Cost definitions",
    summary: "The versioned rate card that prices usage for chargeback, budgets and the budget assistant. Load a card from a JSON file or reprice entries here, review the change, then save.",
    figures: [
      ["USD and CCU", "Rates are stored in USD per million tokens; switch the unit to view or edit them in CCU (100 CCU = USD 1, exact)."],
      ["Effective dates", "UTC. Recorded prices are never edited: a new price closes the old entry and starts a new one from a future date."],
      ["Geo multipliers", "For example US data zone at 1.1×; a geography not listed is reported unpriced."],
      ["Cache categories", "Cache read, 5-minute and 1-hour cache writes, each with its own rate."],
    ],
    permissions: ["Saving needs CCOF.Projects.Write and ADMIN_CONFIG_CONTAINER with a scoped Cosmos data role."],
    troubleshooting: [
      ["'Version must change'", "Give the edited card a new version string."],
      ["Reconciler still uses the old prices", "Catalog edits drive the console (chargeback, budget assistant). Export the approved card and deploy it to the reconciler."],
    ],
  },
  help: {
    title: "Help",
    summary: "All help topics, the permissions each feature needs, settings, and runbooks.",
  },
};
