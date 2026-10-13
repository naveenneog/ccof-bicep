# Microsoft Entra prerequisites for the quick-start

Complete these before Bicep. Deployment only **reads** app registrations and security groups;
it never creates an Entra object, grants delegated consent or changes authentication settings.
The Entra administrator and Azure deployer may be different people.

## Registration count and roles

**Two mandatory app registrations** (ADR-0026):

| Registration | Purpose | Parameter roles |
|---|---|---|
| Combined developer/gateway app | Developer public-client sign-in and the gateway's delegated API audience | `registrations.gatewayApi` **and** `registrations.developerSignIn` with the **same** `appId` |
| Resolver API | Internal API callable only by APIM's managed identity (ADR-0009) | `registrations.resolverApi`, with a **different** `appId` |

A backend registration is **optional**, only for the cross-tenant client-credentials path
(ADR-0007). Same-tenant Foundry, even across subscriptions, uses APIM's managed identity instead.
The quick-start implements that managed-identity backend; use the staged path for cross-tenant
credentials. The resolver is **not** the cross-tenant backend app.

Existing separate gateway/developer apps remain supported: three mandatory registrations in that
legacy layout, plus the optional cross-tenant backend. No migration or consent change is automatic.

| Work | Who |
|---|---|
| Create/configure applications | Application owner; Cloud Application Administrator or Application Administrator; eligible member while “Users can register applications” is enabled |
| Delegated consent, where required | Tenant administrator permitted by the tenant's consent policy |
| Create security groups / assign owners | Groups Administrator or eligible self-service group creator |
| Deploy Azure resources and role assignments | Azure Owner, or Contributor plus Role Based Access Control Administrator / User Access Administrator at the required scopes |
| Grant sync's Graph application permissions **after** deployment | Active Privileged Role Administrator or Global Administrator (not simply Azure Owner) |

## 1. Configure the combined developer/gateway application

In Microsoft Entra admin center → App registrations, create or locate a **single-tenant** app.
Display names are not unique: identify an existing registration by its application ID rather than
creating a duplicate.

1. **Expose an API**: set Application ID URI `api://<combinedAppId>`.
2. Add the enabled delegated scope `access_as_user`. Set its consent description to access the
   Claude enterprise gateway on the signed-in user's behalf. Select consent type according to
   customer policy, not a blanket user-consent exception.
3. **Manifest**: explicitly set `api.requestedAccessTokenVersion` to **2**.
4. **Authentication → Mobile and desktop applications**: public-client redirects:
   - `http://localhost` (MSAL's browser/PKCE loopback listener);
   - `https://login.microsoftonline.com/common/oauth2/nativeclient`;
   - `ms-appx-web://Microsoft.AAD.BrokerPlugin/<combinedAppId>` for Windows WAM.
5. Turn **Allow public client flows** on if optional `ccof-token login --device-code` is allowed.
   It is not required for the browser/PKCE flow. Conditional Access can still refuse device code.
6. Do **not** create a client secret for developer sign-in or enable implicit grants.
   Keep API settings and public-client settings on this **same** application.

Fill both role IDs:

```bicep
var developerGatewayAppId = 'REPLACE-combined-developer-gateway-app-id'
param registrations = {
  gatewayApi: { appId: developerGatewayAppId, scope: 'access_as_user', accessTokenVersion: 2 }
  developerSignIn: { appId: developerGatewayAppId }
  resolverApi: { appId: 'REPLACE-separate-resolver-api-app-id' }
}
```

This example contains no customer identity. Keep filled parameters in the git-ignored
`.env.customer.bicepparam` file, never in a public export.

### Consent and token-to-self: verify before rollout

[Microsoft Learn's token-to-self description][self] explicitly allows the same resource and client
application requesting its own exposed delegated permission. Its no-consent statement also says
“the application has no registered web API”. Do **not** extrapolate that statement into a promise
that this gateway scope bypasses your tenant's consent restrictions.

[AADSTS90009][errors] explicitly says token-to-self is supported only when the requested resource
uses the **GUID-based application ID**. For the combined app the helper translates
`api://<combinedAppId>/access_as_user` to `<combinedAppId>/access_as_user` on every MSAL login and
silent refresh. The stored config and API identifier URI are unchanged. Desktop's native OIDC
profile uses the same GUID request resource. Neither client ever requests the resolver audience.
For a combined app with a custom identifier URI, step 8 exports the GUID resource scope directly
instead of guessing whether that URI is a separate resource. The API's identifier URI is unchanged.

The admin must verify applicable consent/preauthorization on the **gateway** scope and tenant
Conditional Access. The [Expose an API guide][expose] documents authorized client applications;
authorize only the intended client and scope. For legacy separate apps, add the gateway's
delegated scope to the developer app's API permissions and obtain consent under tenant policy.
Application permissions, client secrets and `/.default` are not substitutes for developer
delegated access.

**Evidence status:** offline request/refresh tests and official documentation support the
GUID self-resource request. This change has **not** acquired a live token for a newly combined
app. Before rolling it out:

1. Give one test developer the generated non-secret client configuration and group entitlement.
2. Run `ccof-token login` through the approved browser/WAM flow; optional device code only when
   allowed. Do not capture that screen in a transcript.
3. Let the configured Claude client make one authorized gateway request. Gateway validation must
   see the expected tenant, gateway audience, `scp: access_as_user`, intended `azp`/`appid`, and
   signed-in user's `oid`; no app-only developer token is accepted.
4. Verify a silent helper refresh without a new prompt. Do not print, paste, log or commit tokens.
5. Record only success/failure codes. A consent failure stops rollout; never substitute an Azure CLI
   token, relax the audience/client check or add the developer to the resolver's allowed identities.

## 2. Configure the separate resolver API

Create or locate **another single-tenant registration**:

- Application ID URI `api://<resolverAppId>`;
- `api.requestedAccessTokenVersion: 2`;
- enterprise application (service principal) exists;
- **no client secret, public-client redirects or delegated scope**;
- application ID differs from **both** gateway/developer role IDs, also in the legacy layout.

Put only this ID in `registrations.resolverApi.appId`. During deployment the resolver's
`authsettingsV2` pins this audience, the tenant issuer, APIM's managed-identity application ID
**and** object ID. Both application and principal restrictions must match. A developer gateway
token cannot call the resolver: its audience is different and its identity is not APIM's.
Do not configure browser login, self-preauthorization, a developer scope or a developer identity
on the resolver.

## 3. Existing groups and Azure prerequisites

Provide existing **security groups**, their object IDs and their project/classification mapping.
No nested groups are needed. Give each group accountable owners; adding/removing members affects
entitlement through the sync and resolver, not by granting resolver API access.

An existing APIM must have its system-assigned managed identity **On**. The quick-start reads its
principal and application IDs; never replace it with the developer app. Confirm the Azure
deployer's resource-group/backend role scopes independently of their Entra directory role.
See [QUICKSTART.md](QUICKSTART.md) for network prerequisites, backend routing and deployment order.

## 4. Read-only checks and post-deployment permissions

`Deploy-Quickstart.ps1` step 1 reads the application settings from Graph and checks both roles on
the combined app. It rejects missing identifier URI, enabled scope, answered token version or
public-client redirects. It warns when optional device-code public-client flows are off. It
rejects a shared resolver ID **before cloud calls**, and refuses resolver public-client redirects
or delegated scopes. Checks do **not** prove successful live consent, token issuance or private
network reachability.

After deployment, the privileged administrator runs `Grant-SyncGraphPermissions.ps1` for the
sync identity's documented Graph application grants. These grants do not belong on either of
the developer-facing app roles. Enable the sync timer only after read-back verification; follow
the quick-start's `-Only 3` instructions rather than reseeding the registry.

## Sources (retrieved 2026-10-13)

- [Understanding delegated access: Token to self][self].
- [Microsoft identity platform error codes: AADSTS90009][errors].
- [Configure an application to expose a web API][expose].
- [Configure a desktop app](https://learn.microsoft.com/entra/identity-platform/scenario-desktop-app-registration).
- [MSAL Node broker](https://learn.microsoft.com/entra/msal/javascript/node/brokering).
- [Configure Microsoft Entra authentication](https://learn.microsoft.com/azure/app-service/configure-authentication-provider-aad)
  (`allowedApplications` and `allowedPrincipals.identities`, as pinned by ADR-0009).
- ADR-0007, ADR-0009, ADR-0019 and ADR-0026 in `docs/adr/`.

[self]: https://learn.microsoft.com/entra/identity-platform/delegated-access-primer#token-to-self
[errors]: https://learn.microsoft.com/entra/identity-platform/reference-error-codes
[expose]: https://learn.microsoft.com/entra/identity-platform/quickstart-configure-app-expose-web-apis
