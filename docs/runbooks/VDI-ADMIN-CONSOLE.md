# Admin console from a Windows VDI

The console is reached from the approved corporate network or VDI path. The platform
team supplies the actual admin hostname; the route is:

```text
https://REPLACE-APPROVED-ADMIN-HOST/api/console-v3
```

This is the admin route, not the `/anthropic` inference base URL. Access also
requires assignment to the admin enterprise application. `CCOF.Projects.Read`
permits reads; `CCOF.Projects.Write` permits reviewed changes. An Entra group owner
manages membership separately. The console editor role does not create Foundry
deployments or grant Azure network permissions.

## 1. Open and check the console

1. Open the approved URL in the VDI browser and sign in with the assigned work account.
2. On **Health**, check the configured resource scopes and integration status.
3. On **Projects**, select the intended project. Reader accounts have no save or
   retire controls.

An unavailable or permission-required integration is not proof that the underlying
resource is absent. A sign-in failure goes to the identity team with the error code
and correlation ID, not a token. Reference: [admin operations](ADMIN-OPERATIONS.md).

## 2. Add a project and its users

1. The group owner supplies a distinct security-group object ID for each classification
   and adds the approved direct members. The group IDs are deployment-specific.
2. A console editor opens **Projects > New project**, enters a stable project ID and
   selects an existing backend and its designated subscription.
3. **Access groups** maps each classification to its approved group.
4. **Models & limits** uses actual deployed model names and the approved token and
   budget limits. A client-side alias does not create a deployment or grant access.
5. The editor reviews the proposed project and saves it.
6. The platform team confirms a successful entitlement sync. In delegated-snapshot
   mode, the approved snapshot workflow is needed; adding a group member alone does
   not update the projection. For budget-enabled access, the relevant reconciler
   state also needs to be ready.

See [project onboarding and budgets](ADMIN-OPERATIONS.md#3-onboard-a-project-and-its-people).

## 3. Distribute client values

In **Project > Onboarding**, select the user's classification. The ready state and
completed values identify a usable download. Share `config.json` or the individual
values through an approved private channel.

The export can contain an API Management address. The platform team confirms whether
the approved VDI address is a Front Door host or another endpoint and supplies the
correct `/anthropic` base URL. A private endpoint is not assumed to be reachable from
every VDI or from Cloud Shell. The download contains identifiers and routing values,
not a reason to share credentials. Developer steps are in
[VDI developer onboarding](VDI-DEVELOPER.md).

## 4. Common operations

| Page | Use |
| --- | --- |
| **Projects > Models & limits** | Review allowed deployments and token limits. |
| **Projects > Budgets** | Review person and group budget settings. |
| **Projects > Activity** and **Audit** | Review recorded changes and relevant attempts. |
| **Chargeback** | Review usage, coverage and cost estimates; missing or unpriced usage is not zero. |
| **Reconciler / Budgets** | Review budget state and reconciler freshness. |
| **Foundry** | Read inventory and project-to-backend visibility. |
| **Health** | Review available health signals; email notifications are a separate add-on. |

Project edits use a review and save. An `etag_mismatch` indicates a concurrent
change; refresh and review before trying again. Removing a member is an Entra group
operation followed by successful sync. Project retirement is a separate, one-way
operation. Details: [admin operations](ADMIN-OPERATIONS.md).
