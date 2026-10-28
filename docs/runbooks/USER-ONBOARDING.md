# 3. User onboarding: self-service and Microsoft Intune

Applies to the client files exported by Admin **3.2.0 and later** (current: 3.3.0).
Who: the service desk or packaging team, and developers setting up their own machine.
The platform deployment and project setup are covered by the
[deployment](DEPLOYMENT-RUNBOOK.md) and [admin](ADMIN-OPERATIONS.md) guides.

Two files have different purposes:

| File | Consumer | Purpose |
| --- | --- | --- |
| `config.json` | CCOF token helper and client setup scripts | Actual sign-in, gateway, deployment names and project-selection configuration |
| `<project>-<classification>-onboarding.json` | Developer, service desk, endpoint packaging team | Readable handoff: group, project, allowed models, installation paths and steps |

`onboarding.json` is **not** the helper configuration, an installer, a credential or an access grant.
The helper does not automatically import it. Both downloads belong to the same project/classification.
Source: [`admin/src/client-config.ts`](../../admin/src/client-config.ts).

## 1. Before either onboarding route

| Requirement | Owner / check |
| --- | --- |
| Actual entitlement | Group owner adds the user directly to the exported Entra security group; sync has succeeded afterwards |
| Project/model | Active project, correct backend, exact deployed model name admitted by the classification |
| Budget state | Where enabled, fresh reconciler state exists and budget is not exhausted |
| Client identity | Correct tenant, **gateway/developer** app client ID and `access_as_user` scope; never admin/resolver app IDs |
| Network | User reaches gateway HTTPS and Entra sign-in endpoints; managed devices follow approved proxy/DNS/Conditional Access |
| Software | Approved Node 22+, PowerShell 7 and supported Claude Code/VS Code extension and/or Desktop installed |
| Helper release | Approved `client` and `scripts\client` from the same source commit, locked dependencies and release hash |
| User context | Setup/sign-in runs as the intended user, not LocalSystem, a shared admin account or a service principal |

The setup scripts configure installed clients; they do not install or upgrade Claude applications.
Sign-in remains interactive once per user. Refresh/acquisition from a configured client is silent.

## 2. Export and validate the files

Admin console path: **Projects > project > Onboarding > Classification**.
The ready banner means the required client settings were present, not that the developer already
has group membership or can make a model call.

![Onboarding tab and both downloads; Fabrikam lab, pseudonymous identifiers](../images/staged/console-light-project-onboarding.png)

### `onboarding.json` field map

| Field | Example / meaning | Who fills it |
| --- | --- | --- |
| `schemaVersion`, `kind` | `1`, `ccof.project-onboarding` | Server |
| `generatedAt` | UTC export timestamp, not an expiry/access token | Server |
| `complete`, `missingAdminSettings` | `true`, `[]`; anything else is not ready for distribution | Derived from admin settings |
| `project.id`, `.displayName`, `.status` | Stable project ID and label; status must be active before rollout | Project registry |
| `project.backendId` | APIM backend identifier, not a URL chosen by the user | Platform/admin |
| `classification` | Such as `STD`; determines group and model policy | Admin selection |
| `entraGroup.objectId`, `.displayName` | Exact direct-membership group; display names alone are not unique | Entra owner / registry |
| `access` | Explanation that membership and sync grant access, not this file | Server |
| `models` | Model deployments grouped by family | Project family policy |
| `gateway.url`, `.projectHeader`, `.projectId` | Gateway base and selection hint, normally `/anthropic` and `x-ccof-project` | Admin settings and registry |
| `clientConfig.fileName`, `.installPath` | `config.json` and platform-specific default locations | Server |
| `clientConfig.overrideEnvironmentVariable` | `CCOF_CONFIG_FILE`; an override must be an absolute path | Server |
| `steps`, `note` | Human instructions; no installation code is executed from these strings | Server |

Files contain identifiers and internal routing details but no tokens, keys or user lists.
Distribution still follows the organization's internal-data policy.

### `config.json` field map

| Field | Required value / behavior |
| --- | --- |
| `schemaVersion` | `1`; unknown fields are refused |
| `tenantId` | Actual gateway tenant GUID, not `common` |
| `clientId` | Combined gateway/developer registration GUID, not Microsoft Azure CLI |
| `scope` | Normally `api://<clientId>/access_as_user`; combined-app helper converts the self-resource request to GUID form |
| `gatewayUrl` | HTTPS base, normally `https://<gateway>/anthropic`, **without** `/v1` or `/v1/messages` |
| `helperTtlSeconds` | Export default 300 |
| `minimumTokenLifetimeSeconds` | Export default 360; greater than helper TTL |
| `loginTimeoutSeconds`, `tokenTimeoutSeconds` | Export defaults 120 and 30 |
| `disableNonessentialTraffic` | Export default `true`; also affects client auto-updates, not a firewall rule |
| `models.default`, `.opus`, `.sonnet`, `.haiku` | Explicit admitted deployment names. A missing family alias can fall back to an admitted deployment; it does not grant that missing family. |
| `models.available` | Client picker list; gateway policy remains authoritative |
| `desktop.profileId`, `.profileName` | Stable per tenant/project/classification; reruns update the same profile |
| `project.id`, `.selectorHeader` | Intended project and matching gateway selector header |

Configuration is not a place for usernames, passwords, client secrets, API keys or access tokens.
The exported model list can include a deployment that the installed client version does not yet
support; endpoint packaging tests the chosen model/client combination.

## 3. Self-service onboarding on Windows

The approved release is extracted to a durable, user-accessible folder, for example
`C:\Users\<user>\CCOF-client`. It retains the repository layout:

```text
CCOF-client\
  client\bin\
  client\src\
  client\package.json
  client\package-lock.json
  scripts\client\
```

The setup-generated helpers pin this folder and the Node executable. A temporary Downloads/Intune
cache path cannot remain the helper installation path.

### A. Install the helper dependencies and validate configuration

From PowerShell 7 in the approved release folder:

```powershell
$ErrorActionPreference = 'Stop'
$release = 'C:\Users\REPLACE\CCOF-client'
Set-Location $release
npm ci --prefix .\client --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { throw 'Helper dependencies failed.' }
$config = Join-Path $env:LOCALAPPDATA 'ClaudeGateway\config.json'
node .\client\bin\validate-config.mjs $config | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'The exported config.json is missing or invalid.' }
pwsh -NoProfile -File .\scripts\client\Test-InstalledClients.ps1
```

Before validation, `config.json` is saved at the path shown above. An existing configuration is
retained privately before replacement. The script does not copy the onboarding handout as config.
Locked dependencies can instead be included by endpoint packaging; client token acquisition
does not run `npm` or Azure CLI.

### B. Sign in as the user

```powershell
$env:CCOF_CONFIG_FILE = $config
node .\client\bin\ccof-token.mjs login
if ($LASTEXITCODE -ne 0) { throw 'User sign-in was not completed.' }
node .\client\bin\ccof-token.mjs status
```

Windows attempts WAM first; supported browser/PKCE loopback is the fallback. Device code is an
explicit approved choice, not an automatic bypass of Conditional Access. With `browserSignIn: false`
in the client file (the gateway app has no `http://localhost` redirect), the fallback is device code
instead of the browser: `ccof-token login` prints a code and the address to enter it. `status` is local
state, not a live inference test.

The command `ccof-token token` prints a credential for helper consumers. It is not a diagnostic
command to run in a transcript, screenshot, ticket or terminal recording.

### C. Configure installed client surfaces

```powershell
pwsh -NoProfile -File .\scripts\client\Set-ClaudeCodeGateway.ps1 -ConfigPath $config -Confirmed
if ($LASTEXITCODE -ne 0) { throw 'Claude Code/VS Code setup failed.' }
```

This merges `apiKeyHelper`, the gateway base, deployment aliases, allowed picker names,
project header and provider settings into the user's Claude settings. For an installed VS Code
Claude extension it also merges the non-secret environment and disables the hosted login prompt.
Reload the VS Code window afterwards.

For an approved supported Desktop build:

```powershell
pwsh -NoProfile -File .\scripts\client\Set-ClaudeDesktopGateway.ps1 -ConfigPath $config -Confirmed
if ($LASTEXITCODE -ne 0) { throw 'Desktop setup failed.' }
```

The setup inspects the installed Desktop schema. Supported builds use native external-IdP or
helper-script credentials as appropriate. A managed inference policy or unrecognized schema
causes refusal; setup does not remove organizational policy. Fully quit/reopen Desktop and select
the exported profile in **Settings > Connection** (or the build's Third-Party Inference screen).
Credentials are access tokens, not OIDC ID tokens.

#### Azure CLI token route (no Node.js or `ccof-token` on the laptop)

When the gateway app preauthorizes the Azure CLI and APIM lists it as an allowed client (staged
`entra.allowAzureCliClient: true`), both setup scripts accept `-TokenSource AzureCli`:

```powershell
pwsh -NoProfile -File .\scripts\client\Set-ClaudeCodeGateway.ps1 -ConfigPath $config -TokenSource AzureCli -Confirmed
pwsh -NoProfile -File .\scripts\client\Set-ClaudeDesktopGateway.ps1 -ConfigPath $config -TokenSource AzureCli -Confirmed
```

The helper they write is `az-gateway-token.cmd`
([`docs/examples/az-gateway-token-auto-login.cmd`](../examples/az-gateway-token-auto-login.cmd) with the
tenant and gateway scope from `config.json`). It returns a cached or refreshed Azure CLI token for
the gateway scope; when none is available it starts one Azure CLI sign-in (`az login --tenant ... --scope ...`),
which on Windows uses the Web Account Manager broker. Claude Code and the VS Code extension call it
through `apiKeyHelper`; Desktop runs it as its helper-script credential, with a 300-second timeout so the
sign-in can finish. The laptop needs the Azure CLI on `PATH` and PowerShell 7 for this one-time setup;
Node.js is used only to inspect the Desktop bundle when it is present (otherwise the documented
helper-script keys are written and a warning asks the user to check the profile in Desktop).

Lab check, 2026-10-28: the generated helper returned a gateway token through the Azure CLI, and Claude
Code 2.1.272 answered through APIM with it. Claude Desktop with this helper and the first interactive
sign-in on a user laptop were not run in the lab.

### D. Acceptance

```powershell
pwsh -NoProfile -File .\scripts\client\Test-ClientGatewayAccess.ps1 -ConfigPath $config -Confirmed
if ($LASTEXITCODE -ne 0) { throw 'Gateway/client acceptance failed.' }
```

This check can send a small paid model request; run only with authorization. A CLI/model response
through the gateway and a real Desktop conversation are separate acceptance cases.
Missing software, a failed sign-in or a profile file alone is not successful onboarding.

## 4. Intune deployment

This section is a **packaging recipe using the existing per-user setup scripts**, not a claim
that a dedicated Intune installer or tenant rollout already exists. The repository has no
published `.intunewin` package. The endpoint team builds, signs, tests and approves one before
broad assignment. Intune tenant enrollment, Company Portal assignment and device rollout have
not been live-verified in the lab.

### Deployment design

| Intune choice | Value / reason |
| --- | --- |
| Package type | Windows app (Win32), prepared with Microsoft's Win32 Content Prep Tool |
| Install behavior | **User**: helper settings, DPAPI cache, Desktop profiles and VS Code settings belong to the signed-in user |
| Dependencies | Machine-managed Node 22+, PowerShell 7; separately approved Claude clients/extension |
| Assignment | Approved user group, scoped to exactly one intended active Code project profile at a time |
| Credential delivery | None. No cached account, token or shared user sign-in is packaged. |
| First sign-in | User runs the installed helper's `login` after installation |
| Package version | Approved source commit plus profile revision, not just `schemaVersion: 1` |
| Detection | Configuration/profile and helper files, not a token, marker alone or successful model call |
| Upgrade | Versioned durable payload; setup rerun from the new payload; old payload kept until rollback is no longer needed |

A SYSTEM-context installation would configure the SYSTEM account rather than the developer.
Multiple conflicting Code profile assignments overwrite one per-user active configuration;
membership in two projects is not resolved by Intune install order.

### A. Build the payload on an approved Windows packaging machine

The source checkout has `client` dependencies restored for the intended Windows architecture.
Native secure-cache dependencies are not copied from a Linux Cloud Shell build.
Only these paths enter the payload; no `.env` inputs, repository history, caches or backups:

```text
package\
  Apply-Profile.ps1             # packaging entry point, described below
  payload\
    config.json                # validated export
    onboarding.json            # matching handout
    client\                    # bin, src, manifests, production node_modules
    scripts\client\            # setup, restore and their helper files
```

`npm ci --prefix .\client --omit=dev --no-audit --no-fund` prepares production dependencies on
that packaging machine. It is not part of the endpoint install command.

The package entry point named `Apply-Profile.ps1` contains the following **Code/VS Code example**.
`ReleaseId` is a packaging-team identifier such as `ccof-3.2.0-r1-project01-std`.
Desktop has its own per-user deployment below.

```powershell
#Requires -Version 7.0
param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$ReleaseId)
$ErrorActionPreference = 'Stop'
if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
    throw 'This package requires the intended user context.'
}
$source = Join-Path $PSScriptRoot 'payload'
$base = Join-Path $env:LOCALAPPDATA 'ClaudeGateway'
$root = Join-Path $base "releases\$ReleaseId"
$node = (Get-Command node -ErrorAction Stop).Source
& $node (Join-Path $source 'client\bin\validate-config.mjs') (Join-Path $source 'config.json') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Package configuration is invalid.' }
. (Join-Path $source 'scripts\client\ClientInventory.ps1')
$inventory = Get-CcofClientInventory
if (-not $inventory.CliVersion -and -not $inventory.VSCodeVersion) {
    throw 'No supported Claude Code CLI or VS Code extension was detected.'
}
if (Test-Path -LiteralPath $root) {
    throw 'Release payload already exists; review the previous installation before retrying.'
}
New-Item -ItemType Directory -Force -Path $root | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'client') -Destination $root -Recurse
New-Item -ItemType Directory -Force -Path (Join-Path $root 'scripts') | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'scripts\client') -Destination (Join-Path $root 'scripts') -Recurse
Copy-Item -LiteralPath (Join-Path $source 'onboarding.json') -Destination $root
$config = Join-Path $base 'config.json'
if (Test-Path -LiteralPath $config) {
    Copy-Item -LiteralPath $config -Destination (Join-Path $root 'previous-config.json')
}
Copy-Item -LiteralPath (Join-Path $source 'config.json') -Destination $config
& (Join-Path $root 'scripts\client\Set-ClaudeCodeGateway.ps1') -ConfigPath $config -Confirmed
'Configuration installed; user sign-in is still required.'
```

The example refuses an already-existing release directory instead of deleting/overwriting an
unverified partial installation. A packaging retry first reviews the printed error and existing
payload; it uses a newly approved revision if necessary. The setup's normal backups remain
under `ClaudeGateway\backups`; previous token caches are never copied into the package.

### B. Intune admin center

1. Content Prep Tool packages the directory using `Apply-Profile.ps1` as setup file.
   The reviewed/signature-verified files and package hash form the release record.
2. **Intune admin center > Apps > Windows > Add > Windows app (Win32)** uploads `.intunewin`.
3. **Program > Install command**, using the actual approved PowerShell 7 install path:

   ```text
   "C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -File .\Apply-Profile.ps1 -ReleaseId ccof-3_2_0-r1-project01-std
   ```

4. Install behavior is **User**, OS/architecture requirements match the dependency build, and
   Node/PowerShell/Claude client dependencies are assigned first.
5. **Detection rules > Use a custom detection script** runs the package-specific check below.
   Microsoft requires exit 0 **and stdout text** for detected. No token is requested.
6. **Assignments** starts with a pilot user group / Company Portal availability, then Required
   only after managed-device acceptance. The entitlement group's membership/sync remains a
   separate access requirement.

### C. Detection example for this Code/VS Code package

The endpoint team fills the three constants from the approved package. `$expectedHash` is the
SHA-256 of the **exported config.json bytes**, obtained before packaging.
This Windows PowerShell-compatible script inspects actual settings/shim targets; it does not
declare success based only on an install marker. A malformed/missing file returns not detected.

```powershell
$releaseId = 'ccof-3_2_0-r1-project01-std'
$expectedHash = 'REPLACE-CONFIG-SHA256'
$expectedProject = 'PROJECT01'
$ErrorActionPreference = 'Stop'
try {
    $base = Join-Path $env:LOCALAPPDATA 'ClaudeGateway'
    $root = Join-Path $base "releases\$releaseId"
    $cfgPath = Join-Path $base 'config.json'
    if ((Get-FileHash -LiteralPath $cfgPath -Algorithm SHA256).Hash -ine $expectedHash) { exit 1 }
    $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    if ($cfg.project.id -cne $expectedProject) { exit 1 }
    $entry = Join-Path $root 'client\bin\ccof-token.mjs'
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { exit 1 }
    $settingsPath = Join-Path $HOME '.claude\settings.json'
    $s = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $shim = Join-Path $HOME '.claude\ccof-token.cmd'
    if ($s.apiKeyHelper -cne "`"$shim`" token") { exit 1 }
    if ($s.env.ANTHROPIC_BASE_URL -cne $cfg.gatewayUrl) { exit 1 }
    if ($s.env.CCOF_CONFIG_FILE -cne $cfgPath) { exit 1 }
    $selector = '{0}: {1}' -f $cfg.project.selectorHeader, $expectedProject
    if (@($s.env.ANTHROPIC_CUSTOM_HEADERS -split "`r?`n") -cnotcontains $selector) { exit 1 }
    if ($s.model -cne $cfg.models.default) { exit 1 }
    $shimText = Get-Content -LiteralPath $shim -Raw
    if (-not $shimText.Contains($entry) -or -not $shimText.Contains($cfgPath)) { exit 1 }
    'CCOF profile and helper detected; sign-in is not evaluated.'
    exit 0
} catch {
    exit 1
}
```

This detector covers the common Code settings and helper. An extension-specific package also
checks `%APPDATA%\Code\User\settings.json`: `claudeCode.disableLoginPrompt=true` and matching
`claudeCode.environmentVariables` gateway/config/project values. Missing extension policy
cannot be treated as "VS Code configured" merely because Code's shared settings exist.

### D. Desktop through Intune

Desktop remains a **separate user-context app/profile assignment**, with the same stable
payload layout and exported `config.json`. The packaging entry point uses
`Set-ClaudeDesktopGateway.ps1` instead of the Code setup, and requires an actual detected,
approved Desktop build before applying. Managed Desktop inference policy takes precedence;
the local-profile deployment refuses when that policy is present.

Desktop detection inspects `%LOCALAPPDATA%\Claude-3p\configLibrary\<profileId>.json` and
`_meta.json`, including the applied profile ID, `inferenceProvider=gateway`,
`inferenceGatewayBaseUrl`, model names and project header. For helper-script profiles it also
checks the durable helper target; for supported native IdP profiles it checks tenant/client/
scope and access-token mode. The Code detector above is **not** a Desktop detector.

The actual client schema varies by Desktop build. Its schema-aware setup is already implemented,
but a universal Intune detection/signing/rollback package is not supplied by this release.
That Desktop package needs endpoint-team qualification on the chosen build before Required
assignment; self-service Desktop setup above is the existing supported route.

### E. First user sign-in and managed-device acceptance

After the package is detected, the user runs:

```powershell
$config = Join-Path $env:LOCALAPPDATA 'ClaudeGateway\config.json'
$env:CCOF_CONFIG_FILE = $config
$entry = Join-Path $env:LOCALAPPDATA 'ClaudeGateway\releases\ccof-3_2_0-r1-project01-std\client\bin\ccof-token.mjs'
node $entry login
if ($LASTEXITCODE -ne 0) { throw 'Sign-in failed.' }
```

The endpoint team confirms installation and sign-in are reported separately. Pilot acceptance
uses one authorized prompt, one denied project/model and a silent subsequent acquisition;
no token is printed. Deployment/rotation of a profile does not require collecting users' caches.

## 5. Rollback, offboarding and troubleshooting

Each existing setup returns a `changeId`. Rollback uses the matching backup rather than deleting
the whole Claude settings directory:

```powershell
pwsh -NoProfile -File .\scripts\client\Restore-ClaudeCodeGateway.ps1 -BackupPath 'C:\REPLACE\backups\CHANGE-ID' -Confirmed
if ($LASTEXITCODE -ne 0) { throw 'Restore failed; inspect concurrent edits.' }
```

Desktop uses `Restore-ClaudeDesktopGateway.ps1` with its own change ID. A managed endpoint
package's Uninstall command is the packaging team's signed user-context wrapper around these
restore operations and the approved configuration backup. There is deliberately no generic
"delete settings" uninstall command. Shared payloads remain while any profile/helper references
them. Backups can contain older credentials and remain private.

Access offboarding is Entra membership removal followed by successful sync, or approved project
retirement. Uninstall alone does not revoke server entitlement, cached Entra sessions or tokens.
`ccof-token logout` removes this helper's account selection/cache, not the Windows/browser session.

| Symptom | Meaning / action |
| --- | --- |
| Incomplete export / validation refuses | Correct admin client settings and regenerate both files; no guessed IDs |
| 401 | Sign-in expired/wrong audience/client/scope; gateway access token required |
| 403 | Membership/sync, model policy, budget or quota; not fixed by a different token audience |
| 429 | Rate limit; honor Retry-After |
| `project_selection_required` | Multiple project memberships; matching project selector configuration required |
| VS Code hosted login | Reload, inspect managed/project overrides and Claude extension environment; no hosted subscription required |
| Desktop policy/schema refusal | Endpoint administrator reviews policy/client version; no registry-policy removal |
| Intune detected but no model response | Detection proves files/settings, not sign-in, network, membership or inference |
| Intune install targets SYSTEM | Wrong execution context; user setup is not performed under SYSTEM |
| Partial install | Inspect actual durable payload and setup backups; retry is not a recursive cleanup operation |

## References and evidence limits

- [Client contract, sign-in flows and restores](../CLIENTS.md).
- [Export implementation](../../admin/src/client-config.ts).
- [Code setup](../../scripts/client/Set-ClaudeCodeGateway.ps1),
  [Desktop setup](../../scripts/client/Set-ClaudeDesktopGateway.ps1),
  [client tests](../../client/test).
- [Microsoft: Win32 app program, requirements and detection](https://learn.microsoft.com/intune/app-management/deployment/add-win32).
- [Microsoft: Win32 Content Prep Tool](https://learn.microsoft.com/intune/intune-service/apps/apps-win32-prepare).
- [Microsoft: Intune Management Extension](https://learn.microsoft.com/intune/intune-service/apps/intune-management-extension).

Existing helper/setup tests and earlier gateway sign-in checks are not an Intune tenant rollout
or universal Desktop compatibility proof. Local packaging examples need signed managed-device
qualification before they are presented as a production Intune release.
