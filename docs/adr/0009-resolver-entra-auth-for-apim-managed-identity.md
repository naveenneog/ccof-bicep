# ADR-0009: Only APIM's managed identity can call the resolver — App Service Authentication replaces the function key

- **Status:** Accepted (autopilot, pending owner review)
- **Date:** 2026-10-11
- **Packets:** WP-RES (`docs/ROADMAP.md` M1.6); constrains WP-GW (the APIM call) and wave 2 (private
  endpoint)
- **Deciders:** the WP-RES agent; pending owner review
- **Supersedes:** `authLevel: "function"` on the `resolve` function, and the function-key check in
  `docs/STATUS.md` ("Session resume check", 2026-10-11)
- **Reference (read-only):** `naveenneog/claude-code-foundry-gateway` ADR-0028
  (`docs/adr/0028-basic-v2-projection-resolver.md`), `infra/resolver.bicep` (the `authsettingsV2`
  resource) and `resolver/src/index.mjs`, read 2026-10-11.
- **Detail:** commands, rollback and live evidence in `docs/status/WP-RES.md`; script
  `infra/poc/resolver-auth.ps1`.

## Context

- `sample-pilot-resolver-func` (Flex Consumption, Node 22, East US 2) accepts traffic from the internet
  (`publicNetworkAccess: Enabled`). At `e8832fd` its only control was a function key
  (`authLevel: "function"`). App Service Authentication was off: `authsettingsV2` returned
  `{"platform": {"enabled": false}}` (read 2026-10-11).
- The resolver trusts `personId` in the request body. It is meant to be the `oid` of the developer
  token that APIM validated. Anyone who can call the resolver can therefore ask about any person.
- Microsoft Learn, "Work with access keys in Azure Functions" (ms.date 2026-09-15, retrieved
  2026-10-11, <https://learn.microsoft.com/azure/azure-functions/function-keys-how-to>): access keys "act
  as shared secrets", and "While access keys provide some protection against unwanted access, consider
  other options to secure HTTP endpoints in production", naming App Service Authentication and API
  Management.
- Microsoft Learn, "Configure Microsoft Entra authentication" (ms.date 2026-04-27, retrieved 2026-10-11,
  <https://learn.microsoft.com/azure/app-service/configure-authentication-provider-aad>):
  - `allowedApplications` checks the token's `appid` or `azp` claim; `allowedPrincipals.identities`
    checks `oid`. When both are configured, a request must satisfy both.
  - "Requests that fail these built-in checks get an HTTP `403 Forbidden` response."
  - Unauthenticated requests can be answered with `401`, "recommended for APIs".
  - The issuer URL takes the form `https://login.microsoftonline.com/<tenant-id>/v2.0`.
  - The property names are those of `Microsoft.Web/sites/config` `authsettingsV2`
    (<https://learn.microsoft.com/azure/templates/microsoft.web/sites/config-authsettingsv2>, retrieved
    2026-10-11).
- Microsoft Learn, "Work with user identities in AuthN/AuthZ" (ms.date 2025-07-02, retrieved
  2026-10-11, <https://learn.microsoft.com/azure/app-service/configure-authentication-user-identities>):
  App Service injects `X-MS-CLIENT-PRINCIPAL*` headers for "authenticated end users or client
  applications", and "External requests aren't allowed to set these headers, so they're present only if
  App Service sets them."
- Microsoft Learn, "Environment variables and app settings in Azure App Service" (ms.date 2026-02-26,
  retrieved 2026-10-11, <https://learn.microsoft.com/azure/app-service/reference-app-settings>):
  `WEBSITE_AUTH_ENABLED` is "Read-only. Injected into a Windows or Linux app to indicate whether App
  Service authentication is enabled."
- Microsoft Learn, "Access tokens in the Microsoft identity platform" (ms.date 2025-05-14, retrieved
  2026-10-11, <https://learn.microsoft.com/entra/identity-platform/access-tokens>): with
  `requestedAccessTokenVersion` 2, "a client calling the v1.0 endpoint to get a token for that resource
  receives a v2.0 access token".
- Microsoft Learn, "Authenticate with managed identity" policy (ms.date 2026-05-05, retrieved
  2026-10-11,
  <https://learn.microsoft.com/azure/api-management/authentication-managed-identity-policy>): `resource`
  is "The application ID of the target web API"; "API Management caches the token until it expires";
  users who can edit policies "may be able to exfiltrate the authentication token".
- Reference ADR-0028 uses the same shape on a public resolver: App Service Authentication, 401 for
  unauthenticated requests, audience and tenant pinned, only the gateway's managed identity (application
  id and object id) allowed, and an anonymous function. Its `index.mjs` keeps authentication out of the
  code: "Doing it in both places would mean two answers to the question of who may call, and eventually
  they would differ."
- Owner requirement, 2026-10-11: the authentication change must not cost availability.

## Options considered

| Option | Outcome |
|---|---|
| A. Keep the function key only | One shared secret is the only control, and whoever holds it can query any person |
| B. App Service Authentication plus the function key | Two controls. APIM must store and send the key; a key rotated or lost without an overlapping key fails every resolver call, and so every developer. The key protects only when App Service Authentication is off |
| C. Validate the token in function code | A second implementation of who may call, and a signing-key fetch the code must manage |
| **D. App Service Authentication only, an anonymous function, and a code guard that refuses when the platform's authentication is off or did not run** | One answer to who may call, no shared secret, fails closed if authentication is switched off |

## Decision

Option D.

1. **App registration `ccof-resolver-api`.** Single tenant; Application ID URI `api://<appId>`;
   `requestedAccessTokenVersion` 2, so every token for it, managed-identity tokens included, is a v2
   token; no secret, no redirect URI, no delegated scope; a service principal; tag `ccof-wp=res`.
2. **`authsettingsV2` on `sample-pilot-resolver-func`:**
   - `platform.enabled` true; `globalValidation.requireAuthentication` true;
     `unauthenticatedClientAction` `Return401`; `httpSettings.requireHttps` true;
   - `identityProviders.azureActiveDirectory`: `registration.openIdIssuer`
     `https://login.microsoftonline.com/<tenant-id>/v2.0`; `registration.clientId` the resolver app id;
     `validation.allowedAudiences` `api://<appId>` and `<appId>`;
     `defaultAuthorizationPolicy.allowedApplications` APIM's managed-identity application id;
     `allowedPrincipals.identities` APIM's managed-identity object id;
   - `login.tokenStore.enabled` false.
3. **The function key is dropped** (`authLevel: "anonymous"` on `resolve` and `health`). Option B's key
   would add a shared secret to store in APIM and a failure mode that stops every developer, to cover
   only the case the guard below covers.
4. **Code guard.** The function code refuses:
   - with 503 and internal reason `platform_authentication_disabled` (and reports itself unhealthy)
     unless `WEBSITE_AUTH_ENABLED` is `true`;
   - with 401 and internal reason `request_not_authenticated` unless the request carries App Service's
     principal header.

   The guard does not decide who may call. The allowed identities live only in `authsettingsV2`.
5. **Trust boundary.** `input.personId` is trusted only because only APIM's managed identity can call
   the resolver, and APIM sets it from the `oid` of the developer token it validated. The comments in
   `src/resolver/decide.ts` and `src/resolver/http-handler.ts` say so.
6. **The APIM call (WP-GW):** `<authentication-managed-identity resource="<resolver app id>" />`, with no
   function key.
7. **Not decided here:** the resolver's private endpoint (wave 2) and the APIM policy (WP-GW).

## Consequences

+ Only a token issued to APIM's system-assigned identity for this audience reaches the function. There
  is no shared secret to store or rotate.
+ Hosting is unchanged: always-ready and scale settings are not touched.
− **Trust extends to APIM policy editors.** Anyone who can edit APIM policies can obtain the managed
  identity's token for this audience and query the resolver directly.
− **APIM's system-assigned identity is a single point of failure.** If it is removed and added again
  (for example by `az apim update` without `--enable-managed-identity true`), its object and application
  ids change and every resolver call gets 403 until `authsettingsV2` is updated. A user-assigned
  identity would survive that; the choice belongs to WP-GW and the availability design.
− **Authentication switched off means an outage, not an open endpoint.** The guard then refuses every
  request. Restoring `authsettingsV2` is one recorded command.
− **Other principals can still obtain tokens for the audience.** No app-role assignment is required,
  so any user or application in the tenant that is granted a token is refused with 403 by App Service.
  Requiring assignment, with an app role granted to APIM's identity, would refuse them at token
  issuance. It is left to WP-GW or WP-SEC, because APIM's token request can be verified only once APIM
  calls the resolver.
− The endpoint stays public until wave 2 adds the private endpoint.

## How we would know this was wrong

- A request without a token, or with another audience, reaches the function code: the log shows
  `request_not_authenticated`.
- APIM's calls get 401 or 403 once WP-GW wires them: the audience, issuer or allowed ids are wrong.
- The guard refuses APIM's calls: on Flex Consumption the platform does not set `WEBSITE_AUTH_ENABLED`
  or the principal header for managed-identity (app-only) tokens.
