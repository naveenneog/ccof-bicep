# Admin app: quick, modular customer deployment

> **Historical.** The current deployment, including the admin app, is the [staged deployment](runbooks/STAGED-DEPLOYMENT-V2.md) described in the [deployment runbook](runbooks/DEPLOYMENT-RUNBOOK.md).

Use this only if the customer now permits an approved administrator to clone the repository.
The no-clone, Portal-first option remains the [Public Access Workbook, Modules 18-24](runbooks/PUBLIC-ACCESS-WORKBOOK.md#admin-hand-configuration).
This is an optional faster path, not a replacement for that in-progress workbook.

## Boundaries

- The resources stage creates **only** a new admin Function App, Flex plan, storage/container,
  Log Analytics and Application Insights, settings and two IAM assignments on those new resources.
- No VNet, private endpoint, APIM policy, existing Function code/settings, native Cosmos role,
  or Entra registration is changed by that template.
- Native Cosmos grants **can** be automated with Bicep, but are deliberately kept as a separate
  privileged operation here; Entra setup is separate too. This is a permission boundary, not a
  claim that Cosmos RBAC cannot be deployed with Bicep.
- Blank ADMIN_* authentication settings leave all registry operations failing closed. The UI
  can be deployed before authentication/data access is complete, but it cannot manage projects yet.
- These resources have ongoing charges. Names, region, subscription and changes require approval.

Use **Cloud Shell PowerShell 7**. At each stage stop on nonzero exit and inspect state before rerun.
Do not run the resources template over names belonging to an existing inference deployment.

## Stage 0 - Clone the feature branch and pin the reviewed source

```powershell
git clone --branch feat/project-admin-api --single-branch https://github.com/naveenneog/ccof-bicep.git
if ($LASTEXITCODE -ne 0) { throw 'Clone failed.' }
Set-Location ccof-bicep
git rev-parse HEAD
```

Record/approve the printed commit before building/deploying. If already cloned, back up local
changes and use `git switch feat/project-admin-api`; don't discard changes or reset the branch.

## Stage 1 - Set the customer's resource values

```powershell
$sub = 'REPLACE-customer-subscription-guid'
$rg = 'REPLACE-new-admin-resource-group'
$loc = 'REPLACE-approved-flex-region'
$app = 'REPLACE-unique-new-admin-function'
$storage = 'REPLACE-unique-new-adminstorage'
$cosmosEndpoint = 'https://REPLACE-existing-cosmos.documents.azure.com:443/'
$db = 'REPLACE-actual-existing-database'
if (@($sub,$rg,$loc,$app,$storage,$cosmosEndpoint,$db) -match 'REPLACE-') { throw 'Fill the approved customer values first.' }
az account show --subscription $sub --query '{id:id,tenant:tenantId,name:name}' -o json
if ($LASTEXITCODE -ne 0) { throw 'Subscription read failed.' }
```

The exact database might be `registry` or another customer-chosen name; don't copy the lab's
`ccof`. Check `az functionapp list-flexconsumption-locations` if the chosen region is uncertain.

## Stage 2 - Create the new admin resource group (once)

```powershell
az group create --subscription $sub -n $rg -l $loc --output none
if ($LASTEXITCODE -ne 0) { throw 'Admin resource-group create failed.' }
```

If it already exists, verify its identity/location and skip create.

## Stage 3 - Create the admin resources with ONE deployment command

```powershell
az deployment group create --subscription $sub -g $rg -n ccof-admin-resources `
  --template-file infra/admin/admin-resources.bicep `
  --parameters "location=$loc" "functionAppName=$app" "storageAccountName=$storage" `
               "cosmosEndpoint=$cosmosEndpoint" "cosmosDatabase=$db" `
  --query properties.outputs -o json
if ($LASTEXITCODE -ne 0) { throw 'Admin resources not verified; inspect deployment operations before rerun.' }
```

This creates the app first with no VNet integration and no configured user authentication;
the API refuses requests until Stage 4. Keep the output resource IDs/principal/hostname privately.
The template targets only the approved new names; no old CCOF app is redeployed.

### Network gate - can publishing proceed now?

Read the effective new storage setting (policy can override the requested setting):

```powershell
az storage account show --subscription $sub -g $rg -n $storage --query '{publicNetworkAccess:publicNetworkAccess,allowSharedKeyAccess:allowSharedKeyAccess}' -o json
if ($LASTEXITCODE -ne 0) { throw 'Storage configuration read failed.' }
```

- **If storage public network access is permitted and deployment storage is reachable:**
  the package can be published without first adding an admin VNet.
- **If storage is forced private by tenant policy:** its private endpoint, DNS and Function
  VNet integration must be configured **before publishing**. Staging networks later cannot
  bypass that dependency. Use workbook 18.4-18.6 and 19.3-19.7, or the separately approved
  `infra/admin/admin-network.bicep` template. Do not weaken the policy or enable account keys.
- **For Cosmos:** public network access Enabled alone is not sufficient: IP/VNet firewalls
  must permit this Function App too. Preserve the customer's current exposure settings. If
  Cosmos is private or firewalled, its approved network path is required before registry tests.
  A console page can still load while the registry is unavailable.

If using the network template, it creates a separate admin VNet, blob zone/link/endpoint only.
It does not connect Cosmos. Pass its `integrationSubnetId` output into a reviewed redeployment
of **the new admin resources only**, with `storagePublicNetworkAccess=Disabled` and all intended
ADMIN_* parameters preserved. Do not blindly redeploy after configuring authentication, because
empty template defaults can overwrite the new admin app's settings.

## Stage 4 - Create the admin Entra app, its roles and permissions, then settings

Run as an **Application Administrator** (or the app's owner). This creates a NEW registration
only; the existing gateway/developer registrations are not touched. No Graph API permissions
are requested for the app. Each block reads first and skips what already exists.

### 4a - Hostname of the new app (for the redirect URI)

```powershell
$hostName = az functionapp show --subscription $sub -g $rg -n $app --query 'properties.defaultHostName || defaultHostName' -o tsv
if ($LASTEXITCODE -ne 0 -or -not $hostName) { throw 'Admin hostname read failed; complete Stage 3 first.' }
$redirect = "https://$hostName/api/console"
$tenant = az account show --subscription $sub --query tenantId -o tsv
$displayName = 'CCOF Admin'
```

### 4b - Create (or reuse) the app registration

```powershell
$existing = @(az ad app list --display-name $displayName --query '[].{appId:appId,id:id}' -o json | ConvertFrom-Json)
if ($existing.Count -gt 1) { throw "More than one '$displayName' exists; choose one and set `$client/`$objectId manually." }
if ($existing.Count -eq 1) { $client = $existing[0].appId; $objectId = $existing[0].id }
else {
  $reg = az ad app create --display-name $displayName --sign-in-audience AzureADMyOrg -o json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw 'App registration create failed.' }
  $client = $reg.appId; $objectId = $reg.id
}
"Admin client ID: $client"
```

### 4c - Expose the API: URI, v2 tokens and the Projects.Manage scope

```powershell
$current = az ad app show --id $client -o json | ConvertFrom-Json
$scope = @($current.api.oauth2PermissionScopes | Where-Object value -CEQ 'Projects.Manage') | Select-Object -First 1
$scopeId = if ($scope) { $scope.id } else { [guid]::NewGuid().ToString() }
$others = @($current.api.oauth2PermissionScopes | Where-Object value -CNE 'Projects.Manage')
$body = @{
  identifierUris = @("api://$client")
  api = @{
    requestedAccessTokenVersion = 2
    oauth2PermissionScopes = $others + @(@{
      id = $scopeId; value = 'Projects.Manage'; type = 'Admin'; isEnabled = $true
      adminConsentDisplayName = 'Manage CCOF projects'
      adminConsentDescription = 'Read and change CCOF project models and token limits as the signed-in administrator.'
    })
  }
}
$f = New-TemporaryFile; $body | ConvertTo-Json -Depth 10 | Set-Content $f -Encoding utf8NoBOM
az rest --method patch --url "https://graph.microsoft.com/v1.0/applications/$objectId" --headers 'Content-Type=application/json' --body "@$f" --output none
$code = $LASTEXITCODE; Remove-Item $f
if ($code -ne 0) { throw 'Scope/URI update failed.' }
```

### 4d - App roles: CCOF.Projects.Read and CCOF.Projects.Write

```powershell
$current = az ad app show --id $client -o json | ConvertFrom-Json
$roles = @($current.appRoles)
foreach ($r in @(
  @{ value = 'CCOF.Projects.Read';  name = 'CCOF project reader'; desc = 'View CCOF projects, models and token limits.' },
  @{ value = 'CCOF.Projects.Write'; name = 'CCOF project editor'; desc = 'Create CCOF projects and change models and token limits.' })) {
  if (-not ($roles | Where-Object value -CEQ $r.value)) {
    $roles += @{ id = [guid]::NewGuid().ToString(); value = $r.value; displayName = $r.name; description = $r.desc
                 allowedMemberTypes = @('User'); isEnabled = $true }
  }
}
$f = New-TemporaryFile; @{ appRoles = $roles } | ConvertTo-Json -Depth 10 | Set-Content $f -Encoding utf8NoBOM
az rest --method patch --url "https://graph.microsoft.com/v1.0/applications/$objectId" --headers 'Content-Type=application/json' --body "@$f" --output none
$code = $LASTEXITCODE; Remove-Item $f
if ($code -ne 0) { throw 'App role update failed.' }
```

### 4e - SPA redirect and self-preauthorization (no consent prompt)

```powershell
$current = az ad app show --id $client -o json | ConvertFrom-Json
$redirects = @(@($current.spa.redirectUris) + $redirect | Where-Object { $_ } | Sort-Object -Unique)
$pre = @(@($current.api.preAuthorizedApplications) | Where-Object { $_ -and $_.appId -ne $client }) +
       @(@{ appId = $client; delegatedPermissionIds = @($scopeId) })
$f = New-TemporaryFile
@{ spa = @{ redirectUris = $redirects }; api = @{ preAuthorizedApplications = $pre } } | ConvertTo-Json -Depth 10 | Set-Content $f -Encoding utf8NoBOM
az rest --method patch --url "https://graph.microsoft.com/v1.0/applications/$objectId" --headers 'Content-Type=application/json' --body "@$f" --output none
$code = $LASTEXITCODE; Remove-Item $f
if ($code -ne 0) { throw 'Redirect/preauthorization update failed.' }
```

### 4f - Enterprise app, Assignment required, and role assignments

```powershell
$spId = az ad sp list --filter "appId eq '$client'" --query '[0].id' -o tsv
if (-not $spId) { $spId = az ad sp create --id $client --query id -o tsv }
if ($LASTEXITCODE -ne 0 -or -not $spId) { throw 'Enterprise app create/read failed.' }
$f = New-TemporaryFile; '{"appRoleAssignmentRequired":true}' | Set-Content $f -Encoding utf8NoBOM
az rest --method patch --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId" --headers 'Content-Type=application/json' --body "@$f" --output none
$code = $LASTEXITCODE; Remove-Item $f
if ($code -ne 0) { throw 'Assignment-required update failed.' }

# One approved person per call. Use 'CCOF.Projects.Write' for editors, 'CCOF.Projects.Read' for readers.
function Grant-CcofAdminRole([string]$UserObjectId, [string]$RoleValue) {
  $roleId = az ad app show --id $client --query "appRoles[?value=='$RoleValue'].id | [0]" -o tsv
  if (-not $roleId) { throw "Role $RoleValue not found." }
  $already = az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" --query "value[?principalId=='$UserObjectId' && appRoleId=='$roleId'] | length(@)" -o tsv
  if ($already -ne '0') { "Already assigned: $RoleValue"; return }
  $f = New-TemporaryFile
  @{ principalId = $UserObjectId; resourceId = $spId; appRoleId = $roleId } | ConvertTo-Json | Set-Content $f -Encoding utf8NoBOM
  az rest --method post --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" --headers 'Content-Type=application/json' --body "@$f" --output none
  $code = $LASTEXITCODE; Remove-Item $f
  if ($code -ne 0) { throw "Role assignment failed for $UserObjectId." }
  "Assigned $RoleValue"
}
Grant-CcofAdminRole -UserObjectId 'REPLACE-approved-editor-user-object-id' -RoleValue 'CCOF.Projects.Write'
# Grant-CcofAdminRole -UserObjectId 'REPLACE-reviewer-user-object-id' -RoleValue 'CCOF.Projects.Read'
```

User object IDs: Entra ID > Users > the person > **Object ID**. Group assignment works the same
way (pass the group's Object ID) where the tenant's licence allows group app-role assignment.

### 4g - Merge sign-in settings on the NEW admin app only

```powershell
az functionapp config appsettings set --subscription $sub -g $rg -n $app --settings `
  "ADMIN_TENANT_ID=$tenant" "ADMIN_AUDIENCE=$client" 'ADMIN_SCOPE=Projects.Manage' `
  "ADMIN_ALLOWED_CLIENT_IDS=$client" "ADMIN_UI_CLIENT_ID=$client" `
  "ADMIN_UI_SCOPE=api://$client/Projects.Manage" --output none
if ($LASTEXITCODE -ne 0) { throw 'New admin settings merge failed.' }
```

**Check:** Entra > App registrations > CCOF Admin shows the `Projects.Manage` scope, both app
roles, the SPA redirect `https://<host>/api/console` and itself under Authorized client
applications; Enterprise apps > CCOF Admin shows **Assignment required = Yes** and the editor.
This is the console registration, not the existing inference gateway registration.

### 4h - Azure IAM grants (already created by Stage 3)

The resources template grants the admin app's managed identity **Storage Blob Data Owner** on
its own storage and **Monitoring Metrics Publisher** on its own Application Insights. Verify:

```powershell
$principal = az functionapp identity show --subscription $sub -g $rg -n $app --query principalId -o tsv
az role assignment list --assignee $principal --all --query '[].{role:roleDefinitionName,scope:scope}' -o table
if ($LASTEXITCODE -ne 0) { throw 'Role assignment read failed.' }
```

Expect exactly those two roles, each scoped to the new admin resources. Don't add Owner or
Contributor. Optional: give the admins **Log Analytics Reader** on the new workspace to read
the audit log.

## Stage 5 - Build ONLY the admin code, or use the reviewed prebuilt ZIP

On an approved build machine with npm access, PowerShell 7 and Node.js 22.18+ (or a later
supported Node version):

```powershell
pwsh -NoProfile -File admin/Build-AdminPackage.ps1
if ($LASTEXITCODE -ne 0) { throw 'Admin build/tests failed.' }
$zip = Join-Path (Get-Location) 'admin/admin.zip'
Get-FileHash $zip -Algorithm SHA256
```

No root application build or inference code deployment occurs. If Cloud Shell has an unsuitable
Node version or npm is blocked, an approved operator can build elsewhere. Alternatively upload
an already reviewed ready-to-run ZIP and set `$zip` to its uploaded absolute path; compare its
SHA256 with the release manifest before publishing. No dependency install is needed for that path.

## Stage 6 - Publish ONLY the admin app

```powershell
az functionapp deployment source config-zip --subscription $sub -g $rg -n $app --src $zip
if ($LASTEXITCODE -ne 0) { throw 'Admin package publishing failed. Do not infer success from an old running UI.' }
```

**Use this exact command for the Flex app.** It detects Flex and uses its managed publishing
endpoint (`/api/publish`). The generic preview `az functionapp deploy --type zip` failed with
415 on CLI 2.91.0 in the lab. Don't use direct Kudu ZIP deploy, a blob upload alone, or
`WEBSITE_RUN_FROM_PACKAGE`; none is a replacement for the Flex-aware command.

[Microsoft's Flex CLI deployment instructions](https://learn.microsoft.com/azure/azure-functions/deployment-zip-push#deploy-by-using-azure-cli).

## Stage 7 - Verify the new host; grant data access separately

```powershell
az functionapp function list --subscription $sub -g $rg -n $app --query '[].name' -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Handler read failed.' }
az functionapp show --subscription $sub -g $rg -n $app --query 'properties.defaultHostName || defaultHostName' -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Hostname read failed.' }
```

Wait for trigger synchronization; require `projects`, `project`, `classificationPolicy`,
`adminUi`, and `adminHealth`. Open `https://<actual-host>/api/console`; verify the UI is the
reviewed version, then sign in. A working old page is not proof of a successful package upload.

## Stage 7b - Cosmos data role for the admin identity (projects container only)

Run as someone with Cosmos `sqlRoleDefinitions/write` and `sqlRoleAssignments/write` (for
example the Cosmos account owner). Ordinary Azure IAM roles do not grant item access.

```powershell
$cosmosRg = 'REPLACE-cosmos-resource-group'
$cosmosAccount = 'REPLACE-existing-cosmos-account'
if (@($cosmosRg, $cosmosAccount) -match 'REPLACE-') { throw 'Fill the Cosmos names.' }
$principal = az functionapp identity show --subscription $sub -g $rg -n $app --query principalId -o tsv
$cosmosId = az cosmosdb show --subscription $sub -g $cosmosRg -n $cosmosAccount --query id -o tsv
az cosmosdb sql container show --subscription $sub -g $cosmosRg -a $cosmosAccount -d $db -n projects --query id -o tsv
if ($LASTEXITCODE -ne 0 -or -not $principal -or -not $cosmosId) { throw 'Identity, account or projects container not found.' }

$roleName = "ccof-admin-project-editor-$app"
$roleId = az cosmosdb sql role definition list --subscription $sub -g $cosmosRg -a $cosmosAccount --query "[?roleName=='$roleName'].name | [0]" -o tsv
if (-not $roleId) {
  $roleId = [guid]::NewGuid().ToString()
  $f = New-TemporaryFile
  @{
    Id = $roleId; RoleName = $roleName; Type = 'CustomRole'; AssignableScopes = @($cosmosId)
    Permissions = @(@{ DataActions = @(
      'Microsoft.DocumentDB/databaseAccounts/readMetadata'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/readChangeFeed'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace'
    ) })
  } | ConvertTo-Json -Depth 6 | Set-Content $f -Encoding utf8NoBOM
  az cosmosdb sql role definition create --subscription $sub -g $cosmosRg -a $cosmosAccount --body "@$f" --output none
  $code = $LASTEXITCODE; Remove-Item $f
  if ($code -ne 0) { throw 'Cosmos role definition failed.' }
}
$scope = "/dbs/$db/colls/projects"
$has = az cosmosdb sql role assignment list --subscription $sub -g $cosmosRg -a $cosmosAccount --query "[?principalId=='$principal' && ends_with(roleDefinitionId,'$roleId')] | length(@)" -o tsv
if ($has -eq '0') {
  az cosmosdb sql role assignment create --subscription $sub -g $cosmosRg -a $cosmosAccount `
    --role-definition-id $roleId --principal-id $principal --scope $scope --output none
  if ($LASTEXITCODE -ne 0) { throw 'Cosmos role assignment failed.' }
}
az cosmosdb sql role assignment list --subscription $sub -g $cosmosRg -a $cosmosAccount --query "[?principalId=='$principal'].{scope:scope,role:roleDefinitionId}" -o table
```

**Check:** one assignment for the admin app's principal, scope ending `/dbs/<db>/colls/projects`.
No delete or upsert; nothing on `entitlement`, `backends` or budget containers. Existing
assignments are untouched. Allow a few minutes for propagation.

### Health check after the grant

```powershell
$key = az functionapp keys list --subscription $sub -g $rg -n $app --query functionKeys.default -o tsv
try {
  $h = Invoke-WebRequest "https://$hostName/api/health" -Headers @{ 'x-functions-key' = $key } -SkipHttpErrorCheck -TimeoutSec 90
  "HTTP $($h.StatusCode) $($h.Content)"
} finally { $key = $null }
```

Expect `"cosmos":"ok"`. `forbidden_data_role`: wait and retry, then recheck the scope/principal.
`blocked_by_network`: the Cosmos firewall or private access needs the approved path (workbook 23).

**Private access:** workbook **23.1-23.8** when required. Inbound console restrictions are
**24.8-24.13**. Do not open Cosmos/storage to the internet to make the console load.

**Final acceptance:** console sign-in, actual project list, an approved test-project create/update,
ETag conflict/reader refusal, admin audit, and separately verified entitlement sync. A ready health
probe is only a point read, and neither preauthorizes the tests nor proves developer enforcement.

## Validation boundary

With Azure CLI **2.91.0**, the documented `deployment source config-zip` command was
retested on the existing lab Flex admin app: the deployment succeeded, all five handlers
registered, the console returned HTTP 200, and the served JavaScript SHA256 matched the
reviewed ZIP entry. The generic `functionapp deploy --type zip` preview command failed
with 415 and is not recommended by these instructions. This is lab evidence only, not
proof of a fresh customer resource deployment, customer networking or customer data access.
