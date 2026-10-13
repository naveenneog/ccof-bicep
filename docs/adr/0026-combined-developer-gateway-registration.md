# ADR-0026: Combine developer sign-in and the gateway API by default; keep the resolver separate

- **Status:** Accepted (explicit owner request, 2026-10-13)
- **Date:** 2026-10-13
- **Decider:** owner
- **Amends:** the separate gateway/developer registration convention in PILOT C-6/C-9 and
  ADR-0019's D1 workbook; ADR-0024 prerequisite phase. The staged deployment and role handoffs remain.
- **Does not amend:** ADR-0009's resolver audience and APIM-only application **and** principal checks.

## Decision

1. New deployments use one single-tenant application for both `gatewayApi.appId` and
   `developerSignIn.appId`. Expose the enabled delegated `access_as_user` scope and the identifier
   URI `api://<appId>` on that application; set `api.requestedAccessTokenVersion` to 2. On the
   **same application**, configure public-client redirects `http://localhost`,
   `https://login.microsoftonline.com/common/oauth2/nativeclient`, and, for Windows WAM,
   `ms-appx-web://Microsoft.AAD.BrokerPlugin/<appId>`. Enable public-client flows for the optional
   device-code login. No client secret and no implicit grant are required.
2. Keep the two configuration roles, even when their IDs are equal. Existing deployments with
   separate gateway and developer registrations, identifier URIs and v1 or v2 access tokens remain
   supported; no application or consent is migrated automatically.
3. The resolver is a **second mandatory registration**, not the optional cross-tenant backend.
   Its application ID must differ from both developer/gateway IDs. Keep `api://<resolverAppId>`,
   v2 access tokens, no public-client redirects and no delegated scopes. Its authentication still
   pins both APIM's managed-identity application ID and object ID. Developer tokens must never
   reach the resolver, even if the developer is entitled to a project.
4. Therefore the default count is **two mandatory registrations**: combined developer/gateway and
   resolver. A **third, optional** backend registration exists only for the cross-tenant
   client-credentials backend option (ADR-0007); same-tenant Foundry uses managed identity. A legacy
   separate-client deployment has three mandatory registrations, plus that optional backend.
5. Keep the configured scope's identifier URI in generated profiles and cache namespaces.
   When the helper requests a scope of `api://<its-own-clientId>/<scope>`, use
   `<clientId>/<scope>` on every MSAL login/refresh path. Microsoft explicitly requires a
   GUID-based resource for token-to-self (AADSTS90009). Accept the returned scope in either
   equivalent spelling, never a different resource's scope. Separate-client requests are unchanged.
   A combined app with a custom identifier URI exports `<appId>/<scope>` directly, preserving
   that API setting while avoiding a non-GUID self-resource request.
6. Preflight validates both roles against the same application when IDs match, including the API
   settings and public-client redirects. It rejects a shared resolver ID before any Graph read or
   deployment. It does not create applications, add consent or relax the resolver's restrictions.

## Evidence and limitations

Microsoft Learn, retrieved **2026-10-13**:

- [Understanding delegated access: Token to self](https://learn.microsoft.com/entra/identity-platform/delegated-access-primer#token-to-self)
  explicitly describes the same resource/client application requesting its own exposed delegated
  permission. Its no-consent statement also conditions the scenario on "no registered web API";
  do **not** treat that as a blanket exemption from a customer's consent policy.
- [AADSTS90009](https://learn.microsoft.com/entra/identity-platform/reference-error-codes):
  "The application is requesting a token for itself. This scenario is supported only if the
  resource that's specified is using the GUID-based application ID."
- [Expose a web API](https://learn.microsoft.com/entra/identity-platform/quickstart-configure-app-expose-web-apis):
  enabled scopes, application ID URI and optional preauthorization of trusted client applications.
- [Configure app permissions](https://learn.microsoft.com/entra/identity-platform/quickstart-configure-app-access-web-apis):
  the tutorial uses two registrations; this ADR intentionally changes that convention, not the
  authorization checks.

The self-resource request is supported by the documented GUID restriction. Offline tests verify
the exact request and scope matching; **no live token acquisition for a newly combined registration
has been performed**. The Entra administrator must verify tenant consent/Conditional Access with a
targeted `ccof-token login` before rollout, using the gateway's audience, `scp` and allowed `azp`
checks as the detector. This task neither creates nor modifies live Entra objects.

## Consequences and detectors

- Fewer developer-facing objects without exposing a new audience or trusting a new client.
- App owners now control both API and client settings; changing redirects must preserve API settings.
- An unsupported tenant consent/flow policy is a sign-in failure, never an authorization fallback.
- Tests cover equal and distinct IDs, GUID self-resource requests on broker/browser/device/silent
  paths, missing API/client settings and resolver aliasing. Existing resolver authentication tests
  and Bicep checks must continue to pin both APIM identifiers.

## Verification ownership

The owner's later instruction retains Ironclad review/gates; the earlier restriction forbade full
suite/gates/council. Auth development uses failing-first targeted offline tests and a packet
`--no-run` inspection. Integrated packet gates, five-role review and shared ledgers belong to the
coordinator, not simultaneous worktree writers. Targeted green is not an integrated release claim.
