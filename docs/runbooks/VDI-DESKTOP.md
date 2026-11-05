# Claude Desktop gateway pilot from a Windows VDI

Desktop gateway configuration and successful inference are separate checks. A
successful Claude Code test does not establish that Desktop is compatible or that
Desktop sign-in works in a particular tenant. The installed Desktop version, approved
profile, network path and identity policy need confirmation before a pilot.

## 1. Prerequisites and values

The platform and identity teams provide the approved gateway base URL, tenant ID,
gateway client ID, Desktop scope, project ID and exact allowed model deployment names.
The base ends in `/anthropic`, not `/v1/messages`. The user has approved project
membership and a successful entitlement sync.

For native sign-in, the identity team verifies the existing public-client and gateway
app configuration, the delegated scope, consent and accepted client. A combined
client/API app uses the platform-approved token-to-self scope; it can differ in
spelling from the Azure CLI scope. Browser sign-in requires the approved Desktop
redirect on the app; broker sign-in depends on the tenant and device policy. No
new app or directory permission is implied by this pilot.

## 2. Configure one device

1. Open Claude Desktop. In the application menu, select **Help > Troubleshooting >
   Enable Developer Mode**, then **Developer > Configure Third-Party Inference**.
   If a managed profile makes the page read-only, the Desktop administrator owns
   the configuration.
2. Under **Connection**, select **Gateway**. The credential option is **Interactive
   sign-in** or **External identity provider**, according to the installed build and
   approved profile.
3. Enter the approved gateway base URL, tenant-pinned issuer, client ID and Desktop
   scope. The issuer has this form, with the tenant value replaced:

   ```text
   https://login.microsoftonline.com/REPLACE-TENANT-ID/v2.0
   ```

4. Select bearer authentication and an **access token**, not an ID token. The browser
   redirect port stays unset unless the approved profile specifies one.
5. Add the approved project selector header, normally `x-ccof-project`, with the
   approved project ID. Add the exact allowed model deployment names; explicit models
   can be needed when the gateway does not provide model discovery.
6. Apply the changes and restart when prompted. Sign in with the approved work account
   and complete the organization's authentication requirements.

Some supported builds also offer a credential-helper profile. Its availability and
field names depend on the Desktop build and management policy. The helper from
[developer onboarding](VDI-DEVELOPER.md#2-create-the-azure-cli-token-helper) can
be used only when the platform team has approved that mode. The full helper path,
without running the helper, can be displayed locally with:

```powershell
Join-Path $env:USERPROFILE '.claude\az-gateway-token.cmd'
```

Neither mode requires pasting an access token into the profile. References:
[vendor gateway configuration](https://claude.com/docs/third-party/claude-desktop/gateway),
[vendor in-app configuration](https://claude.com/docs/third-party/claude-desktop/in-app-configuration)
and [CCOF Desktop configuration](../CLIENTS.md#5-configure-claude-desktop).

## 3. Verify and troubleshoot

Start a new chat, select an approved model and send `Reply with exactly: gateway OK`.
The reply is the pilot success criterion. Record the Desktop version, selected model
and UTC time. For a failure, share only a reviewed, redacted error and correlation or
tracking ID; Desktop logs and diagnostic reports can contain sensitive data.

| Result | Next check |
| --- | --- |
| Sign-in error | Identity team checks the approved app, scope, redirect, consent and Conditional Access. |
| 401 | Platform team checks the gateway token audience, scope and accepted client. |
| 403 | Platform team correlates the tracking ID with WAF and APIM logs and checks project/model access. |
| 400 `project_selection_required` | Check the project header and authorized membership. |
| 429 | Check the applicable gateway rate or budget limits. |
| 503 `entitlement_unavailable` | Platform team traces the APIM-to-resolver path; this error alone does not establish a cause. |

Rollback uses the previous approved profile. The Desktop administrator restores a
managed profile; other users' profiles and device policy remain unchanged.
