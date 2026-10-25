# ADR 0032: Admin-only current directory user labels

Status: accepted, 2026-10-22.

The ledger identifies people by Entra object ID. Operators need readable names without changing
historical chargeback or the gateway, sync and reconciler services.

V3 offers an authenticated POST lookup of at most 100 user GUIDs. The Admin Function App uses its
managed identity to call Graph `/users/{id}?$select=id,displayName,userPrincipalName`, using Graph
JSON batches of at most 20. `ADMIN_USER_NAMES_ENABLED=true` enables the integration;
`User.Read.All` application permission with admin consent is required on that identity.

Names appear beside full IDs. Filters, exports and accounting continue to use the original IDs.
Names are current, not snapshots of the identity when a request occurred. Missing users and
permission/provider failures remain visible. No names are written to Cosmos or logs. Server and
browser caches are bounded, memory-only and expire within five minutes; HTTP responses use
`Cache-Control: no-store`. V2 is unchanged.

The server returns each label's expiry and a server observation timestamp. The browser converts
remaining freshness to its local clock and deducts the round-trip time; it does not restart the
server TTL. Visible labels recheck at expiry. The server deadline includes token acquisition and
Graph (15 s); the browser settles stalled batches after 20 s and aborts fetch. On any server exit,
in-flight sibling requests are aborted before the timer is cleared.

Sources: [Get user](https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0);
[Graph JSON batching](https://learn.microsoft.com/en-us/graph/json-batching).
