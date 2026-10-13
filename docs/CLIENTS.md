# Claude clients through the enterprise gateway

This setup uses **Entra single sign-on**, not an Anthropic subscription, an API key,
or the Azure CLI's developer login. The standalone `client/` Node package contains
`ccof-token`. Its dependencies are separate from the gateway's server dependencies.
The PowerShell workstation scripts target Windows; the token helper also supports
macOS and Linux secure storage.

## 1. Check what is installed

From the repository root, in PowerShell 7:

```powershell
pwsh -NoProfile -File .\scripts\client\Test-InstalledClients.ps1
```

The script checks `claude --version`, `code --list-extensions --show-versions`,
and the installed/running Desktop bundles. It never installs or upgrades anything.
Setup reports missing applications and configures only installed clients.
Node 22 or newer and PowerShell 7 must already be available; obtain approval before
installing missing software.

On the pilot workstation, the detected versions are CLI **2.1.272**, extension
**2.1.289**, and Desktop **2.2553.1.0**. The Desktop bundle has 171 configuration
keys but no `external-idp` credential kind or `inferenceIdpOidc` key.

## 2. Prepare the helper and configuration

Install only the helper's locked package dependencies:

```powershell
npm ci --prefix .\client --no-audit --no-fund
```

Have the administrator fill in `client\config.example.json` and place the resulting
JSON at `%LOCALAPPDATA%\ClaudeGateway\config.json`. The example's identity IDs and
hostname are deliberately fictitious. C-6's pilot values are in `docs/PILOT.md`.
Do not put access tokens, refresh tokens, client secrets, usernames or passwords
in this configuration.

The helper takes its configuration path from `CCOF_CONFIG_FILE`, or from:

| Platform | Per-user default |
|---|---|
| Windows | `%LOCALAPPDATA%\ClaudeGateway\config.json` |
| macOS | `~/Library/Application Support/ClaudeGateway/config.json` |
| Linux | `$XDG_CONFIG_HOME/claude-gateway/config.json`, or `~/.config/claude-gateway/config.json` |

An explicit environment path must be absolute. Windows setup scripts also accept
`-ConfigPath`; the generated helpers pin that path, so VS Code and Desktop do not
depend on the terminal environment.

| Configuration | Meaning |
|---|---|
| `schemaVersion` | `1`; unknown top-level or nested keys are refused |
| `tenantId` | Gateway tenant GUID, never `common` or `organizations` |
| `clientId` | Developer public-client app GUID; not the Azure CLI client ID |
| `scope` | One delegated gateway API scope, such as C-6's `api://…/access_as_user` |
| `gatewayUrl` | HTTPS API **base**, without `/v1` or `/v1/messages`, credentials, query or fragment |
| `helperTtlSeconds` | Cached-helper lifetime used by both Claude clients |
| `minimumTokenLifetimeSeconds` | Must exceed helper TTL; refuse a token with less lifetime, after one silent forced-refresh attempt |
| `loginTimeoutSeconds` | Bound for an interactive attempt; also the CLI smoke-check deadline |
| `tokenTimeoutSeconds` | Bound per silent acquisition and cache-lock wait; Desktop helper timeout is three times this, at most 600 seconds |
| `disableNonessentialTraffic` | Explicit Claude Code traffic decision; `true` in the pilot example |
| `models.default`, `opus`, `sonnet`, `haiku` | **Deployment names**, not guessed model IDs; every name must occur in `available` |
| `models.available` | Explicit model picker list; the gateway still enforces actual authorization |
| `models.capabilities` | Optional documented capability string per pinned alias |
| `desktop.profileId`, `profileName` | Stable profile GUID and non-personal display label |
| `project` | Optional C-1 selector: `{id, selectorHeader}`; explicit `id: null` clears that header |

The pilot example uses a five-minute helper TTL and a six-minute minimum remaining
lifetime. These are explicit answers, not a claim that every Entra token lives an
hour. The helper checks MSAL's actual expiry on every acquisition. WAM may ignore
`forceRefresh`; if it returns another short-lived token, the helper refuses instead
of allowing either client to cache an expired credential.

### Administrator only: register the broker redirect

This is the **only** component that uses the owner's Azure CLI. Developers do not
run it or need the CLI installed:

```powershell
pwsh -NoProfile -File .\scripts\client\Set-DeveloperSignInRedirects.ps1 `
  -SubscriptionId '<explicit-subscription-guid>' -Confirmed
```

It obtains a Microsoft Graph token with `az account get-access-token --resource-type
ms-graph --subscription …`, verifies the returned tenant/subscription metadata,
retains it only in memory, reads the configured
application, writes the previous redirects to a timestamped JSON backup, and PATCHes
only `publicClient.redirectUris` through `Invoke-RestMethod`. It then reads back
the result. Rerunning it makes no change if the redirect already exists.
Azure CLI rejects combining `--tenant` with `--subscription`; the explicit
subscription is kept and the tenant is checked before any Graph request.

Added on Windows:
`ms-appx-web://Microsoft.AAD.BrokerPlugin/<clientId>`.

Optional administrator flags, only for the corresponding Desktop-owned flow:

- `-IncludeDesktopBrokerRedirect`: `msauth.com.anthropic.claudefordesktop://auth`
  (the macOS Desktop broker callback).
- `-IncludeDesktopBrowserRedirect`: `http://127.0.0.1/callback`
  (Desktop's own browser flow; different from MSAL Node's `http://localhost`).

The installed pilot Desktop uses the shared helper, so it needs neither extra
callback. No permissions, consent grants, API audiences, or APIM policy are changed.

## 3. Sign in once

For the default configuration path:

```powershell
& .\client\bin\ccof-token.cmd login
```

For an alternate path, set `$env:CCOF_CONFIG_FILE` before that command.
The package's executable entry is also usable directly:
`node .\client\bin\ccof-token.mjs login`.
No global installation or PATH modification is needed.

On Windows, `login` attempts WAM first. If the broker is unavailable or fails,
it creates a separate non-broker MSAL client and opens the system browser with
PKCE and MSAL's own `http://localhost:<ephemeral-port>` loopback listener.
Cancellation is not retried with another sign-in window. `login --device-code`
is the only device-code path; do not capture that interactive screen in logs.

```powershell
& .\client\bin\ccof-token.cmd status
& .\client\bin\ccof-token.cmd logout
```

`status` shows the selected account's opaque ID, method and last-acquired expiry,
not its username or token. It does not contact Entra. `logout` removes this
application's cached account and local selection; it does **not** sign the person
out of Windows or their browser, or revoke the enterprise account globally.

`ccof-token token` is for credential-helper consumers. It prints exactly the
access token on stdout and nothing else. **Do not run it in a transcript, paste
its output into settings, or redirect it into an evidence file.** With no valid
sign-in it exits nonzero, prints no token and names `ccof-token login` on stderr.
It never opens a browser, prompts, invokes device code, or falls back to Azure CLI.

Browser tokens use MSAL's encrypted persistence: DPAPI CurrentUser on Windows,
Keychain on macOS, libsecret/Secret Service on Linux. WAM owns its device-bound
refresh tokens. The selected account metadata is also encrypted. Cache locations
are namespaced by tenant, client, scope, gateway and configuration path beneath the configuration
directory. Metadata transactions and MSAL's token cache use cross-process locks.
Missing/unlocked secure storage fails closed; plaintext fallback is disabled.

## 4. Configure Claude Code and VS Code

```powershell
pwsh -NoProfile -File .\scripts\client\Set-ClaudeCodeGateway.ps1 -Confirmed
```

The script backs up and merges `%USERPROFILE%\.claude\settings.json`:

| Setting | Purpose |
|---|---|
| `apiKeyHelper` | Quoted Windows `.cmd` helper running `ccof-token token` through the already-installed Node executable |
| `env.ANTHROPIC_BASE_URL` | For C-6, `https://ccof-poc-apim.azure-api.net/anthropic`; Claude Code appends `/v1/messages` |
| `env.ANTHROPIC_MODEL`, `model` | Explicit initial deployment |
| `env.ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` | Map aliases and background tasks to deployed names |
| `env.ANTHROPIC_DEFAULT_*_MODEL_SUPPORTED_CAPABILITIES` | Avoid incorrect capability inference for pinned deployments |
| `availableModels`, `enforceAvailableModels` | Keep the picker on recorded deployments; not a substitute for server authorization |
| `env.CLAUDE_CODE_API_KEY_HELPER_TTL_MS` | Configured helper TTL converted to milliseconds |
| `env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | The administrator's explicit choice |
| Related provider/credential variables | Disable old Foundry/Bedrock/Vertex routes and clear static credentials that could supersede the helper |

Unrelated settings and environment entries are retained. The generic Anthropic
gateway route is intentional: using `CLAUDE_CODE_USE_FOUNDRY=1` could activate the
Azure credential chain instead of this gateway helper. The helper's result goes
in both `Authorization: Bearer` and `x-api-key`, as documented by Anthropic.

**VS Code reads the same Claude Code settings files**, but its extension also has
a prelaunch sign-in check. Therefore setup also merges the non-secret environment
into `%APPDATA%\Code\User\settings.json` under `claudeCode.environmentVariables`
and sets `claudeCode.disableLoginPrompt=true` for externally managed authentication.
No token is placed in VS Code settings. These two keys were verified in the
installed extension's `package.json`; Anthropic's settings and gateway-connect
pages explain the shared-settings/prelaunch distinction. Reload the VS Code window
after setup; use the **Claude Code** panel, not a hosted claude.ai login.

The sample maps `opus` to `claude-opus-5` for CLI 2.1.272 and still records
`claude-opus-5-5` in the available list. Anthropic documents CLI 2.1.280+ for Opus
5.5; the installed extension is new enough, the standalone CLI is not.
No software upgrade is performed. Obtain approval before upgrading the CLI or
making Opus 5.5 its default.

**Nonessential traffic decision:** the pilot sets it off. This also disables
automatic updates, so plan an administrator-approved update path. It is not a
network firewall: WebFetch's safety check is separate and tools can access other
sites. Setup does not disable that safety check, modify tool permissions, or
install fleet-managed policy. Higher-priority managed/project settings can still
override per-user configuration; verify the active route in `/status`.

## 5. Configure Claude Desktop

```powershell
pwsh -NoProfile -File .\scripts\client\Set-ClaudeDesktopGateway.ps1 -Confirmed
```

The script reads the installed ASAR's actual `flatKey` definitions and linked
credential-kind enum without executing bundle code. When more than one installed
or running build can read the profile, only their shared supported keys are used.
A recognized managed inference policy causes a refusal rather than writing an
ignored local profile. A local hybrid-bootstrap pointer also causes a refusal;
switch to a local configuration in Desktop before applying the script.

- Newer supported builds: `inferenceProvider=gateway`,
  `inferenceCredentialKind=external-idp`, `inferenceIdpAuthFlow=broker`,
  tenant-pinned issuer, configured client/scope and
  `bearerTokenType=access_token`. Never an ID token with the wrong audience.
- This workstation's build: `inferenceCredentialKind=helper-script`, an absolute
  `.cmd` helper with arguments `["token"]`, bearer authentication, configured TTL,
  bounded timeout and silent refresh.

The flat profile is `%LOCALAPPDATA%\Claude-3p\configLibrary\<profileId>.json`;
`_meta.json` selects it through `appliedId` and an `{id,name}` entry. Setup preserves
prior profiles, unrelated metadata and supported settings, and removes obsolete
credentials. The default is first in `inferenceModels`; written keys are checked against the installed build before backup or write.

**Owner's Desktop test — broker sign-in already completed at about 22:15 IST:**

1. Quit Claude through its tray menu; closing only the window may leave it running.
   Open **Claude** from the Windows Start menu, not the terminal's `claude` command.
2. Open **Settings → Connection**. If unavailable, use **Help → Troubleshooting →
   Enable Developer Mode**, then **Developer → Configure Third-Party Inference**.
3. Select **CCOF pilot gateway**. Confirm **Gateway**, base
   `https://ccof-poc-apim.azure-api.net/anthropic`, **Bearer**, **Helper script**,
   the configured `ccof-token.cmd` helper, and argument `token`. Do not paste a token.
4. Return to **Chat**, start a new conversation, choose **claude-haiku-4-5**, and send
   **Reply with the single word OK**. This build reuses the existing broker sign-in;
   do not enter an Anthropic API key or sign in to a claude.ai subscription.
5. **Success:** the native Desktop conversation replies **OK**, without asking for
   an API key. Tell the coordinator the app version, model and time; never send a token.
6. **Failure:** no reply, hosted-login/wrong-credential UI, `sign_in_required`, or an
   HTTP error is not success. Recheck the selected profile and fully restart.
   Only if sign-in is explicitly required, run `& "$env:USERPROFILE\.claude\ccof-token.cmd" login`.
   For `401`, `403`, `429`, or `400 project_selection_required`, use the remedies below;
   do not change the token audience or bypass the gateway. Desktop success remains unverified until step 5.

## 6. Verify without exposing a token

```powershell
pwsh -NoProfile -File .\scripts\client\Test-ClientGatewayAccess.ps1 -Confirmed
```

This closes the token child's stdin, keeps its credential only in memory, sends a
small Haiku Messages POST, and runs a bounded CLI prompt without tools, MCP or session
persistence. Output contains stage/reason/status fields, never tokens or response bodies.
**Live acceptance, about 22:15 IST, 2026-10-11:** the owner completed broker sign-in;
the coordinator verified silent child acquisition (exit 0, correct C-6 claims),
Messages **200 / OK**, and Claude Code **2.1.272 / OK**. U-39 is resolved by that
real check, not the fake tests. Desktop's conversation check remains pending.
Evidence attribution, claims, backup IDs and CI: [`status/WP-CLIENT.md`](status/WP-CLIENT.md).

### Owner smoke through the gateway

`scripts/Test-OwnerSmoke.ps1` checks the gateway itself, for example before and
after a gateway, sync or onboarding change: without a token it must answer 401;
with the owner's token from `ccof-token` it must answer 200 and the reply "OK".
It replaces the session script `smoke-owner.ps1` cited in
`docs/status/WP-SYNC-SP.md` (R1, R5). The helper must be installed in this
checkout (section 2) and signed in (section 3).

```powershell
pwsh -NoProfile -File .\scripts\Test-OwnerSmoke.ps1 -GatewayConfigPath .\infra\gateway\config\ccof-poc.json
# A non-current revision, with a project selector:
pwsh -NoProfile -File .\scripts\Test-OwnerSmoke.ps1 -GatewayConfigPath .\infra\gateway\config\ccof-poc.json -Revision 8 -ProjectId CCOFPILOT02
```

| Value | Source |
|---|---|
| URL | Gateway configuration `apim.gatewayBaseUrl` and `apim.apiPath`, `;rev=<n>` with `-Revision`, then `/v1/messages` |
| Project header | Gateway configuration `resolver.projectHeaderName`, with `-ProjectId`, else this client configuration's `project.id` |
| `anthropic-version` | Gateway configuration `forwarding.defaultAnthropicVersion`; null sends none |
| Model | `-Model`, else the client configuration's `models.haiku` |
| Token | `client/bin/ccof-token.mjs token` with the client configuration (`-ClientConfigPath`, default as in section 2) |
| Time limits | Client configuration `tokenTimeoutSeconds` per request; three times it, at most 600 seconds, for the helper |

The gateway configuration is checked against
`infra/gateway/gateway-config.schema.json`. The client configuration's
`gatewayUrl` must equal the gateway URL, and a configured
`project.selectorHeader` must equal `resolver.projectHeaderName`; otherwise the
smoke refuses before sending anything. The token stays a SecureString, is sent
only as Bearer authentication with no redirect, and is removed, with any
JWT-shaped string, from every printed value. The output is one JSON report:
status codes, the gateway's `x-ccof-request-id`, error types and messages, the
model and the reply. Any other status fails with a remedy from the table under
"Troubleshooting". Exit codes: 0 pass, 1 fail, 2 refused.

### CCOFPILOT02 and multiple-project profiles (C-1/C-8)

Omit selection for a person with one active project. For multiple memberships,
add this object to the **same shared** `%LOCALAPPDATA%\ClaudeGateway\config.json`:

```json
"project": { "id": "CCOFPILOT02", "selectorHeader": "x-ccof-project" }
```

The header name must match the gateway configuration; `x-ccof-project` is the PoC
value, not a code default. Project IDs match `^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$`.
From the checkout, run `pwsh -NoProfile -File .\scripts\client\Set-ClaudeCodeGateway.ps1 -Confirmed` for a global CLI/VS Code profile:
`ANTHROPIC_CUSTOM_HEADERS` becomes `x-ccof-project: CCOFPILOT02`. For a separate
Desktop profile, set `desktop.profileName` to `CCOFPILOT02` and `desktop.profileId`
to a fresh GUID, then run `pwsh -NoProfile -File .\scripts\client\Set-ClaudeDesktopGateway.ps1 -Confirmed` from the checkout.
Choose that profile in Connection before sending the test message; existing profiles
remain saved. Its `inferenceCustomHeaders` carries the selector; SSO stays shared.
Keep the common config path, tenant, client, scope, gateway and lifetime settings unchanged.
Under C-8, the resolver selects the project's active backend and APIM authenticates
to it. Do not supply a backend URL/id, change the provider, or request a backend token.
Use `id: null` with the same header name to clear a previously selected project;
omitting `project` leaves existing custom headers unmanaged. Unrelated headers are
preserved; conflicts or static credential headers refuse before writes. A selector
is only a hint: the gateway authorizes membership and returns 403 for another
person's project, or 400 when selection is required but absent.

## Restore

Each setup prints a `changeId`. Backups default to
`<configuration-directory>\backups\<changeId>`; `-BackupRoot` can override it.
Fully quit the affected clients before restoring.

```powershell
$backup = "$env:LOCALAPPDATA\ClaudeGateway\backups\<changeId>"
pwsh -NoProfile -File .\scripts\client\Restore-ClaudeCodeGateway.ps1 -BackupPath $backup -Confirmed
# Or use the separate Desktop changeId:
pwsh -NoProfile -File .\scripts\client\Restore-ClaudeDesktopGateway.ps1 -BackupPath $backup -Confirmed
# Administrator only, using the redirect changeId:
pwsh -NoProfile -File .\scripts\client\Restore-DeveloperSignInRedirects.ps1 `
  -BackupPath $backup -SubscriptionId '<explicit-subscription-guid>' -Confirmed
```

Local restore verifies backup hashes, refuses later edits, restores exact original
bytes, and removes only files created by that setup. After inspecting a conflict,
`-AllowChangedFiles` explicitly restores the original snapshot. Remote restore
refuses concurrent redirect changes and never restores to a different application.
Keep backups private: originals may contain credentials from an older setup.

The generated shims pin this checkout and Node location. Keep them available;
before moving/deleting a worktree, rerun setup from the durable checkout.
No Windows account, PATH, registry or global npm package is changed. To remove the
helper entirely, restore both clients, log out, and remove its private configuration/
cache directory after reviewing backups. Do not remove files still used by a client.

## Troubleshooting and failure behavior

| Symptom | Meaning / remedy |
|---|---|
| `401` | Missing, expired or wrong-audience token. Run `ccof-token login`; check tenant, public client and gateway API scope. An ID token, Azure CLI/ARM token or Cognitive Services token is not the gateway access token. |
| `403` | Not entitled, model not allowed, or a token quota exhausted. Check pilot-group membership and selected deployment with the administrator; do not change the token audience or bypass the gateway. |
| `429` | Per-person/group rate limit. Honor `Retry-After`; do not retry in a tight loop. |
| `400 project_selection_required` | Multiple active memberships need a selector. Apply the CCOFPILOT02 profile above; the gateway still checks membership. |
| `404` | Wrong API base or deployment name. Use `/anthropic`, not `/anthropic/v1`; use the recorded deployment names. |
| Helper nonzero / `sign_in_required` | Silent-only by design. Sign in explicitly once; headless consumers never prompt. |
| Secure cache unavailable/corrupt | Unlock the OS credential store, then retry. No plaintext or alternate-identity fallback. Preserve evidence without copying cache contents; restore/reset only this helper's cache if necessary. |
| Cache lock stuck after a killed process | Close the helper/clients, verify the PID recorded in its `.lockfile` is no longer running, then remove only that abandoned lock. Never remove a lock held by a live process. |
| Broker unavailable | `login` tries browser loopback; a saved broker session's `token` fails closed, never silently switches identity/flow. |
| Consent/MFA/Conditional Access refusal | Owner/tenant administrator action; do not disable Conditional Access or use a service-principal token as the person. |
| VS Code still shows hosted login | Reload window; confirm `disableLoginPrompt` and environment variables, then check higher-priority settings. |
| Desktop profile ignored | Fully restart; check managed registry policy and the installed bundle's schema. No unsupported keys are forced. |
| Entra/network outage | An already cached, sufficiently lived token may work; expired/too-short tokens are refused. Local cache failures affect one workstation, not the fleet. Gateway availability is independent. |

After WP-GW promotes its entitlement revision, the **same client configuration**
returns `403` for a person outside the pilot groups. Group propagation is bounded
by the sync interval and gateway cache policy, not by client-side authorization.

## Sources

Retrieved/verified 2026-10-11:

- [Anthropic settings and precedence](https://code.claude.com/docs/en/settings):
  shared settings for terminal and VS Code.
- [Gateway connection](https://code.claude.com/docs/en/llm-gateway-connect):
  Windows system-shell helpers, headers, TTL, extension prelaunch check,
  base URL and nonessential-traffic behavior.
- [Model configuration](https://code.claude.com/docs/en/model-config):
  deployment aliases, capability declarations and minimum versions.
- [VS Code](https://code.claude.com/docs/en/vs-code): bundled CLI and window reload.
- [Desktop configuration](https://claude.com/docs/third-party/claude-desktop/configuration):
  profile library, managed precedence, helper arguments/TTL and supported kinds.
- [Desktop gateway](https://claude.com/docs/third-party/claude-desktop/gateway):
  Messages endpoint, broker/browser redirects and access-token OIDC.
- [MSAL Windows broker](https://learn.microsoft.com/entra/msal/javascript/node/brokering):
  broker redirect, native plugin and `forceRefresh` limitation.
- [MSAL extensions](https://github.com/AzureAD/microsoft-authentication-library-for-js/tree/dev/extensions/msal-node-extensions):
  DPAPI/Keychain/libsecret, `PersistenceCreator`, `PersistenceCachePlugin`.
- Installed package source: MSAL Node 7.0.1 `PublicClientApplication.ts`,
  `LoopbackClient.ts`, `InteractiveRequest.d.ts`; extensions 5.5.2 persistence
  and `NativeBrokerPlugin` APIs. Browser loopback is MSAL-owned; unsupported
  `redirectUri`/`timeout` overrides are not passed.
- Read-only precedents: `claude-code-foundry-gateway` ADR-0027/0031,
  `scripts/ClaudeDesktopSignIn.ps1`, `ClaudeClientSupport.ps1`,
  `Setup-ClaudeWorkstation.ps1`, `get-foundry-token.cmd`; and
  `DailyApps\work\claude-desktop-azure-signin\Set-ClaudeDesktopAzure.ps1`
  (installed-bundle preflight and profile-library approach, not its Azure-CLI auth).

## Offline validation

```powershell
npm test --prefix .\client
pwsh -NoProfile -File .\tests\Test-ClientGateway.ps1
node .\scripts\client\tests\Run-ClientMutations.mjs
```

The ordinary repository gate reaches both client suites through their root test
bridges. MSAL and Graph are injected fakes. Mutation checks copy only owned source/
tests into `client\.test-work`, never mutate the working source or live settings,
and reject a result unless the whole baseline test count remains and the intended
test fails. A deliberately broken module-load control must be classified invalid,
not caught. No token values or failed-test output enter the JSON mutation report.

## Checkpointed deployment integration (C-9)

These are leaf operations, not a single installer. The approved WP-CORE contract
is `docs/DEPLOYMENT-STAGES.md` on `wp/core` (interface at `4c1f15d`):

| Part | Client contribution / checkpoint owner |
|---|---|
| D1 prerequisite registration | `Set-DeveloperSignInRedirects.ps1` is optional automation after the developer public app exists; CORE checks stage/operator preconditions and records `registrations.developerSignIn.{appId,objectId}`, the redirect result and backup `changeId` |
| D2 schema/apps | No server package or app settings supplied by CLIENT; workstation setup remains separate |
| D3 grants | `client/permissions.json`, `kind: ccof.assignments`, has empty role definitions and assignments; no Azure/Cosmos/Graph application grants are made here |
| Workstation | Explicit confirmed, backed-up Code/VS Code and Desktop settings; the shared token helper is a separate Node package |

CORE owns the common `-CheckpointPath` record and input-digest resume rules;
the redirect leaf returns `unchanged` when already configured. Missing config or
decisions refuse before writes. App creation and any required delegated consent
remain the deployment team's responsibility. No roles are embedded in Bicep.
Screenshot handoff to WP-SHOTS: **D1-CLIENT-01** Entra app Authentication/mobile
redirects; **D1-CLIENT-02** API-permissions declaration (read-only); **WS-CLIENT-01**
Code settings; **WS-CLIENT-02** Desktop Connection. Capture live, annotate and
redact; illustrative JSON is never labelled as live verification.
