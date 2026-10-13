const node = (name, file, from, to, target) => ({ name, file: `client/src/${file}`, changes: [[from, to]], target, suite: 'node' });
const ps = (name, file, from, to, target) => ({ name, file: `scripts/client/${file}`, changes: [[from, to]], target, suite: 'powershell' });
const invalidConfig = 'configuration rejects invalid identity';
const codeSetup = 'Claude Code merges settings';
const oldDesktop = 'Desktop older bundle uses MSAL helper';
const graphInvoker = 'public redirect entrypoint uses its real default invoker';
const cipher = 'native cache configuration is encrypted';
const result = 'invalid or mismatched token results';
const raw = String.raw;

export const mutations = [
  node('unknown-config-key', 'config.mjs', "Object.keys(value).some((key) => !keys.includes(key) && key !== 'project')", 'false', invalidConfig),
  node('required-own-fields', 'config.mjs', 'for (const key of keys) if (!Object.hasOwn(value, key))', 'for (const key of []) if (!Object.hasOwn(value, key))', 'every required setting'),
  node('schema-version', 'config.mjs', 'value.schemaVersion !== 1', 'false', invalidConfig),
  node('tenant-and-client-guid', 'config.mjs', "!guid.test(value.tenantId ?? '') || !guid.test(value.clientId ?? '')", 'false', invalidConfig),
  node('https-gateway', 'config.mjs', "gateway.protocol !== 'https:'", 'false', invalidConfig),
  node('gateway-userinfo', 'config.mjs', 'gateway.username || gateway.password', 'false', invalidConfig),
  node('gateway-query', 'config.mjs', 'gateway.search || gateway.hash', 'false', invalidConfig),
  node('scope-protocol', 'config.mjs', "!['api:', 'https:'].includes(scope.protocol)", 'false', invalidConfig),
  node('positive-integral-timeouts', 'config.mjs', 'Number.isSafeInteger(value) && value > 0', 'true', invalidConfig),
  node('timer-upper-bound', 'config.mjs', 'value[key] * 1000 > 2_147_483_647', 'false', invalidConfig),
  node('cache-ttl-below-token-life', 'config.mjs', 'value.minimumTokenLifetimeSeconds <= value.helperTtlSeconds', 'false', invalidConfig),
  node('explicit-traffic-choice', 'config.mjs', "typeof value.disableNonessentialTraffic !== 'boolean'", 'false', invalidConfig),
  node('unique-deployments', 'config.mjs', 'new Set(models.available).size !== models.available.length', 'false', invalidConfig),
  node('known-model-alias', 'config.mjs', '!models.available.includes(models[alias])', 'false', invalidConfig),
  node('silent-only-api', 'token-service.mjs', 'client.acquireTokenSilent({ scopes, account: saved.account })', 'client.acquireTokenInteractive({ scopes, account: saved.account })', 'silent token uses only the saved identity'),
  node('requested-scope', 'token-service.mjs', 'const scopes = [config.scope];', "const scopes = ['unrequested-scope'];", 'silent token uses only the saved identity'),
  node('selected-method', 'token-service.mjs', "!['broker', 'browser'].includes(saved.mode)", 'false', 'an invalid saved method'),
  node('returned-account', 'token-service.mjs', '(expectedAccount && result.account.homeAccountId !== expectedAccount.homeAccountId)', 'false', result),
  node('returned-tenant', 'token-service.mjs', 'result.account.tenantId !== config.tenantId', 'false', result),
  node('returned-scope', 'token-service.mjs', '!result.scopes?.some((scope) => scope.toLowerCase() === config.scope.toLowerCase())', 'false', result),
  node('no-whitespace-in-token', 'token-service.mjs', raw`/\s/.test(result.accessToken)`, 'false', result),
  node('remaining-lifetime', 'token-service.mjs', 'return result.expiresOn.getTime() - now() > config.minimumTokenLifetimeSeconds * 1000;', 'return true;', 'silent result must outlive both helper caches'),
  node('forced-refresh-once', 'token-service.mjs', 'account: saved.account, forceRefresh: true', 'account: saved.account, forceRefresh: false', 'silent result must outlive both helper caches'),
  node('device-code-opt-in', 'token-service.mjs', '!deviceCode && runtime.brokerAvailable', 'runtime.brokerAvailable', 'device code requires its explicit login flag'),
  node('broker-platform-preference', 'token-service.mjs', '!deviceCode && runtime.brokerAvailable', '!deviceCode', 'without Windows broker login uses the browser'),
  node('cancel-does-not-reprompt', 'token-service.mjs', "['user_cancelled', 'user_canceled', 'authentication_canceled'].includes(error?.errorCode)", 'false', 'cancelled broker sign-in does not open another window'),
  node('logout-selection', 'token-service.mjs', 'await runtime.state.clear();', '/* missing selection clear */', 'logout removes this application account'),
  node('status-does-not-show-username', 'token-service.mjs', 'accountId: saved?.account.homeAccountId ?? null', 'accountId: saved?.account.username ?? null', 'status reports ids and expiry'),
  node('token-stdout-only', 'cli.mjs', "if (command === 'token') stdout(`${await service.token()}\\n`);", "if (command === 'token') stdout(`banner\\n${await service.token()}\\n`);", 'CLI token stdout is exactly the credential'),
  node('errors-only-on-stderr', 'cli.mjs', 'stderr(error instanceof ClientError ?', 'stdout(error instanceof ClientError ?', 'CLI token stdout is exactly the credential'),
  node('command-argument-count', 'cli.mjs', 'args.length > 2', 'args.length > 200', 'CLI refuses unknown commands'),
  node('encrypted-linux-cache', 'msal-runtime.mjs', 'usePlaintextFileOnLinux: false', 'usePlaintextFileOnLinux: true', cipher),
  node('dpapi-current-user', 'msal-runtime.mjs', 'dataProtectionScope: extensions.DataProtectionScope.CurrentUser', "dataProtectionScope: 'machine'", cipher),
  node('no-pii-logging', 'msal-runtime.mjs', 'piiLoggingEnabled: false', 'piiLoggingEnabled: true', cipher),
  node('native-broker-capability', 'msal-runtime.mjs', 'if (!nativeBrokerPlugin.isBrokerAvailable)', 'if (false)', 'unavailable broker refuses'),
  node('native-broker-windows-only', 'msal-runtime.mjs', "if (platform !== 'win32')", 'if (false)', 'unavailable broker refuses'),
  node('supported-os-only', 'msal-runtime.mjs', "if (!['win32', 'darwin', 'linux'].includes(platform))", 'if (false)', 'unavailable broker refuses'),
  node('cache-config-path-isolation', 'msal-runtime.mjs', 'config.gatewayUrl, path.resolve(configPath)', 'config.gatewayUrl', 'separate config paths cannot share'),
  node('cache-scope-isolation', 'msal-runtime.mjs', 'config.clientId, config.scope, config.gatewayUrl', 'config.clientId, config.gatewayUrl', cipher),
  node('cache-tenant-isolation', 'msal-runtime.mjs', 'config.tenantId, config.clientId, config.scope', 'config.clientId, config.scope', cipher),
  node('cache-client-isolation', 'msal-runtime.mjs', 'config.tenantId, config.clientId, config.scope', 'config.tenantId, config.scope', cipher),
  node('metadata-transaction-lock', 'msal-runtime.mjs', 'await plugin.beforeCacheAccess(context);', '/* missing transaction lock */', 'state transactions lock across the whole operation'),
  node('metadata-commit', 'msal-runtime.mjs', 'context.cacheHasChanged = state.dirty;', 'context.cacheHasChanged = false;', 'state transactions lock across the whole operation'),
  node('broker-scoped-signout', 'msal-runtime.mjs', 'removeAccount: (account) => pca.signOut({ account })', 'removeAccount: async () => {}', 'logout adapter uses the public-client signOut API'),
  node('browser-authority-host', 'msal-runtime.mjs', "authority.hostname !== 'login.microsoftonline.com'", 'false', 'system-browser launcher never uses a shell'),
  node('browser-no-shell', 'msal-runtime.mjs', 'shell: false', 'shell: true', 'system-browser launcher never uses a shell'),
  node('desktop-required-schema', 'desktop-schema.mjs', 'if (!keys.includes(key)) throw unknownSchema();', 'if (false) throw unknownSchema();', 'unrecognized or incomplete Desktop schema'),
  node('desktop-no-incidental-kind', 'desktop-schema.mjs', 'return { keys: keys.sort(), credentialKinds };', "return { keys: keys.sort(), credentialKinds: [...credentialKinds, 'external-idp'] };", 'Desktop support comes from flatKey schema'),
  ps('explicit-confirmation', 'ClientGateway.Common.ps1', 'if (-not $Confirmed)', 'if ($false)', 'setup refuses without confirmation'),
  ps('backup-before-overwrite', 'ClientGateway.Common.ps1', 'if ($exists) { Copy-Item', 'if ($false) { Copy-Item', codeSetup),
  ps('backup-integrity', 'ClientGateway.Common.ps1', 'if ($record.existed -and -not [string]::Equals(', 'if ($false -and -not [string]::Equals(', 'corrupted backup bytes fail integrity'),
  ps('restore-later-edit-conflict', 'ClientGateway.Common.ps1', 'if (-not $AllowChangedFiles -and (', 'if ($false -and (', 'restore detects later edits'),
  ps('restore-new-files', 'ClientGateway.Common.ps1', 'elseif (Test-Path -LiteralPath $record.path)', 'elseif ($false)', 'explicit restore recovers byte-exact originals'),
  ps('installed-clients-only', 'ClaudeCodeGateway.ps1', 'if (-not $Inventory.CliVersion -and -not $Inventory.VSCodeVersion)', 'if ($false)', 'missing clients are reported'),
  ps('code-gateway-base', 'ClaudeCodeGateway.ps1', 'ANTHROPIC_BASE_URL = $Config.gatewayUrl', "ANTHROPIC_BASE_URL = 'https://wrong.example.test'", codeSetup),
  ps('code-model-mapping', 'ClaudeCodeGateway.ps1', '$envs[$prefix] = $Config.models[$alias]', "$envs[$prefix] = 'wrong-deployment'", codeSetup),
  ps('code-ttl-units', 'ClaudeCodeGateway.ps1', '$Config.helperTtlSeconds * 1000', '$Config.helperTtlSeconds', codeSetup),
  ps('code-old-provider-off', 'ClaudeCodeGateway.ps1', "CLAUDE_CODE_USE_FOUNDRY = '0'", "CLAUDE_CODE_USE_FOUNDRY = '1'", codeSetup),
  ps('code-helper-silent-command', 'ClaudeCodeGateway.ps1', '$settings.apiKeyHelper = "`"$helper`" token"', '$settings.apiKeyHelper = "`"$helper`" login"', codeSetup),
  ps('code-preserve-environment', 'ClaudeCodeGateway.ps1', 'if (-not $settings.env) { $settings.env = @{} }', '$settings.env = @{}', codeSetup),
  ps('vscode-external-auth', 'ClaudeCodeGateway.ps1', "$vscode['claudeCode.disableLoginPrompt'] = $true", "$vscode['claudeCode.disableLoginPrompt'] = $false", 'VS Code receives the common environment'),
  ps('vscode-preserve-environment', 'ClaudeCodeGateway.ps1', '$merged = @($entries | Where-Object {', '$merged = @(@() | Where-Object {', 'VS Code receives the common environment'),
  ps('desktop-helper-kind', 'ClaudeDesktopGateway.ps1', "$profile.inferenceCredentialKind = 'helper-script'", "$profile.inferenceCredentialKind = 'static'", oldDesktop),
  ps('desktop-access-token-not-id-token', 'ClaudeDesktopGateway.ps1', "bearerTokenType = 'access_token'", "bearerTokenType = 'id_token'", 'Desktop modern schema uses broker access-token'),
  ps('desktop-preserve-profile', 'ClaudeDesktopGateway.ps1', '$existing = Read-ClientJson $profilePath', '$existing = @{}', 'Desktop reconfiguration preserves unrelated profile keys'),
  ps('desktop-supported-output-keys', 'ClaudeDesktopGateway.ps1', 'if ($Schema.keys -cnotcontains $key) { throw "The installed Desktop schema does not support required key', 'if ($false) { throw "The installed Desktop schema does not support required key', 'missing Desktop keys refuse before writing'),
  ps('desktop-applied-profile', 'ClaudeDesktopGateway.ps1', '$meta.appliedId = $id', '$meta.appliedId = $null', oldDesktop),
  ps('desktop-ttl-below-life', 'ClaudeDesktopGateway.ps1', '$profile.inferenceCredentialHelperTtlSec = $Config.helperTtlSeconds', '$profile.inferenceCredentialHelperTtlSec = $Config.minimumTokenLifetimeSeconds + 1', oldDesktop),
  ps('desktop-bootstrap-precedence', 'ClaudeDesktopGateway.ps1', 'if ($meta.hybridPointer)', 'if ($false)', 'Desktop refuses a hybrid bootstrap pointer'),
  ps('graph-app-identity', 'DeveloperSignInRedirects.ps1', "if (-not $app -or -not [string]::Equals($app.appId, $Config.clientId, 'Ordinal'))", 'if ($false)', 'a foreign Graph application is rejected'),
  ps('graph-complete-read', 'DeveloperSignInRedirects.ps1', 'if ($app.publicClient -isnot [Collections.IDictionary] -or $app.publicClient.redirectUris -isnot [array])', 'if ($false)', 'malformed Graph application data'),
  ps('graph-tenant-binding', 'DeveloperSignInRedirects.ps1', "-not [string]::Equals($credential.tenant, $TenantId, 'Ordinal')", '$false', graphInvoker),
  ps('graph-subscription-binding', 'DeveloperSignInRedirects.ps1', "-not [string]::Equals($credential.subscription, $SubscriptionId, 'Ordinal')", '$false', graphInvoker),
  ps('graph-default-function-scope', 'DeveloperSignInRedirects.ps1', '& $invoke $Method $Uri $Body $TenantId $SubscriptionId', 'Invoke-CcofGraph $Method $Uri $Body $TenantId $SubscriptionId', graphInvoker),
  ps('graph-redirect-backup', 'DeveloperSignInRedirects.ps1', "Write-ClientJson (Join-Path $directory 'redirects.json') $backup", '# missing redirect backup', 'redirect setup backs up before PATCH'),
  ps('graph-idempotence', 'DeveloperSignInRedirects.ps1', 'if (Test-CcofRedirectsEqual $app.publicClient.redirectUris $desired)', 'if ($false)', 'redirect setup is idempotent'),
  ps('graph-readback', 'DeveloperSignInRedirects.ps1', 'if (-not (Test-CcofRedirectsEqual $verified.publicClient.redirectUris $desired))', 'if ($false)', 'redirect PATCH is not success until readback'),
  ps('graph-restore-conflict', 'DeveloperSignInRedirects.ps1', 'if (-not (Test-CcofRedirectsEqual $app.publicClient.redirectUris $backup.after))', 'if ($false)', 'redirect restore refuses another administrator change'),
  ps('child-stdin-closed', 'ClientProcess.ps1', '$process.StandardInput.Close()', '# stdin left open', 'child-process verification closes stdin'),
];

mutations.push(ps('desktop-configured-default', 'ClaudeDesktopGateway.ps1',
  "$models = @($Config.models.default) + @($Config.models.available | Where-Object {\n        -not [string]::Equals($_, $Config.models.default, 'Ordinal')\n    })",
  '$models = @($Config.models.available)', 'Desktop puts the configured default deployment first'));
mutations.push(ps('cmd-native-quoting', 'ClientProcess.ps1',
  `$start.Arguments = '/d /s /c "' + (($all | ForEach-Object { '"' + $_ + '"' }) -join ' ') + '"'`,
  `$start.ArgumentList.Add('/d'); $start.ArgumentList.Add('/s'); $start.ArgumentList.Add('/c'); $start.ArgumentList.Add('"' + (($all | ForEach-Object { '"' + $_ + '"' }) -join ' ') + '"')`,
  'CMD child launch uses native shell quoting'));
mutations.find((mutation) => mutation.name === 'graph-default-function-scope').changes.unshift(
  ['$invoke = ${function:Invoke-CcofGraph}', '# function capture removed']);
const projectConfig = 'optional project profiles accept an explicit selector';
const projectProfiles = 'project profiles share SSO';
const headerGuards = 'project header merging rejects malformed values';
mutations.push(
  node('project-id-grammar', 'config.mjs', raw`!/^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/.test(project.id)`, 'false', projectConfig),
  node('project-header-name', 'config.mjs', raw`!/^[A-Za-z][A-Za-z0-9-]{0,63}$/.test(project.selectorHeader)`, 'false', projectConfig),
  node('project-not-credential-header', 'config.mjs', 'reserved.includes(project.selectorHeader.toLowerCase())', 'false', projectConfig),
  node('project-unknown-keys', 'config.mjs', "Object.keys(project).some((key) => !['id', 'selectorHeader'].includes(key))", 'false', projectConfig),
  ps('desktop-project-selector', 'ClaudeDesktopGateway.ps1', '$profile.inferenceCustomHeaders = Merge-CcofProjectHeaders -Sources @($existing.inferenceCustomHeaders) -Project $config.project', '$profile.inferenceCustomHeaders = @{}', projectProfiles),
  ps('project-clear-selector', 'ClientProjectHeaders.ps1', "if ([string]::Equals($pair.Name, $Project.selectorHeader, 'OrdinalIgnoreCase'))", 'if ($false)', projectProfiles),
  ps('project-preserve-headers', 'ClientProjectHeaders.ps1', '$headers[$pair.Name] = $pair.Value', '# unrelated header dropped', projectProfiles),
  ps('project-refuse-credential-headers', 'ClientProjectHeaders.ps1', "if ($pair.Name.ToLowerInvariant() -in @('authorization', 'proxy-authorization', 'x-api-key', 'api-key', 'cookie', 'set-cookie'))", 'if ($false)', headerGuards),
  ps('project-header-conflict', 'ClientProjectHeaders.ps1', "if ($headers.Contains($pair.Name) -and -not [string]::Equals($headers[$pair.Name], $pair.Value, 'Ordinal'))", 'if ($false)', headerGuards),
);
mutations.push({ name: 'client-no-role-grants', suite: 'node', file: 'client/permissions.json',
  changes: [['"assignments": []', '"assignments": [{"unexpectedGrant":true}]']],
  target: 'the C-9 client contribution requests no Azure' });
