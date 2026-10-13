#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the rendered claude-messages policy as a NEW, NON-CURRENT API revision, and makes a
    revision current as a separate, confirmed step (docs/GATEWAY.md, ADR-0017).

.DESCRIPTION
    Every Azure call is ARM REST through Invoke-RestMethod with a token from
    `az account get-access-token --subscription <id>`: az.cmd re-parses arguments through cmd.exe
    and would mangle the policy XML. The ARM endpoint is the Azure CLI's configured cloud.

    Confirmation is explicit: an answers file that pins the API, the current revision and the
    rendered policy's SHA-256 (or the revision and release note for -MakeCurrent), or an
    interactive prompt that asks the operator to type the digest prefix or revision shown. A
    non-interactive run without an answers file refuses before any write. Each step writes one
    JSON audit line (ids, digests and reason codes only) to the console and to audit.jsonl.

    Rollback is Invoke-GatewayMakeCurrent for the previous revision; the make-current step prints it.
#>

$script:ApiVersion = '2024-05-01'
$script:AuditSchema = 'ccof.gateway.deploy.v1'
$script:Guid = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$script:Name = '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$'
$script:RevisionPattern = '^[1-9][0-9]{0,5}$'

function Write-GatewayAudit {
    param([Parameter(Mandatory)] [string]$Event, [Parameter(Mandatory)] [hashtable]$Data, [string]$AuditPath)
    $line = ([ordered]@{ schema = $script:AuditSchema; event = $Event; atUtc = [datetime]::UtcNow.ToString('o') } + $Data) | ConvertTo-Json -Compress -Depth 4
    Write-Host $line
    if ($AuditPath) { Add-Content -LiteralPath $AuditPath -Value $line -Encoding utf8NoBOM }
    $line
}

function Read-GatewayTarget {
    <# The apim block of a gateway configuration, checked enough to build ARM paths safely. #>
    param([Parameter(Mandatory)] [string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Configuration not found: $ConfigPath. Nothing was changed." }
    try { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Configuration $ConfigPath is not valid JSON. Nothing was changed." }
    $apim = $config.apim
    $checks = @(
        @('apim.subscriptionId', $apim.subscriptionId, $script:Guid), @('apim.resourceGroup', $apim.resourceGroup, '^[A-Za-z0-9._()-]{1,90}$'),
        @('apim.serviceName', $apim.serviceName, '^[A-Za-z][A-Za-z0-9-]{0,49}$'), @('apim.apiId', $apim.apiId, $script:Name),
        @('apim.apiPath', $apim.apiPath, '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$'), @('apim.gatewayBaseUrl', $apim.gatewayBaseUrl, '^https://[a-z0-9-]+(\.[a-z0-9-]+)+$'),
        @('configurationId', $config.configurationId, $script:Name))
    foreach ($check in $checks) {
        if (-not ($check[1] -is [string] -and $check[1] -cmatch $check[2])) { throw "Configuration ${ConfigPath}: $($check[0]) is missing or invalid. Nothing was changed." }
    }
    $serviceId = "/subscriptions/$($apim.subscriptionId)/resourceGroups/$($apim.resourceGroup)/providers/Microsoft.ApiManagement/service/$($apim.serviceName)"
    [pscustomobject]@{
        ConfigurationId = $config.configurationId; SubscriptionId = $apim.subscriptionId; ApiId = $apim.apiId; ApiPath = $apim.apiPath
        GatewayBaseUrl = $apim.gatewayBaseUrl; ServiceId = $serviceId; ApiResourceId = "$serviceId/apis/$($apim.apiId)"
    }
}

function New-ArmInvoker {
    <# Returns { param($Method, $Path, $Body) } -> { Status, Body } against the Azure CLI's cloud, with a token for SubscriptionId. #>
    param([Parameter(Mandatory)] [string]$SubscriptionId)
    $endpoint = "$(az cloud show --query endpoints.resourceManager -o tsv)".TrimEnd('/')
    if ($LASTEXITCODE -ne 0 -or $endpoint -notmatch '^https://') { throw 'Could not read the Azure CLI cloud endpoint. Nothing was changed.' }
    $raw = az account get-access-token --subscription $SubscriptionId --resource "$endpoint/" --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw "Could not get an ARM token for subscription $SubscriptionId from the Azure CLI. Sign in first. Nothing was changed." }
    $token = ConvertTo-SecureString $raw -AsPlainText -Force
    $actor = try { ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((($raw.Split('.')[1]).Replace('-', '+').Replace('_', '/')).PadRight([Math]::Ceiling($raw.Split('.')[1].Length / 4) * 4, '='))) | ConvertFrom-Json).oid } catch { '' }
    $raw = $null
    $invoke = {
        param([string]$Method, [string]$Path, $Body, [hashtable]$Headers)
        $request = @{ Method = $Method; Uri = "$endpoint$Path"; Authentication = 'Bearer'; Token = $token; SkipHttpErrorCheck = $true; StatusCodeVariable = 'status' }
        if ($Headers) { $request.Headers = $Headers }
        if ($null -ne $Body) { $request.Body = ($Body | ConvertTo-Json -Depth 20 -Compress); $request.ContentType = 'application/json' }
        $response = Invoke-RestMethod @request
        [pscustomobject]@{ Status = [int]$status; Body = $response }
    }.GetNewClosure()
    [pscustomobject]@{ Invoke = $invoke; ActorObjectId = "$actor" }
}

function Invoke-Arm {
    param([scriptblock]$Arm, [string]$Method, [string]$Path, $Body, [int[]]$Expect = @(200), [hashtable]$Headers)
    $response = & $Arm $Method $Path $Body $Headers
    if ($Expect -notcontains $response.Status) {
        $detail = "$($response.Body.error.code): $($response.Body.error.message)"
        $nested = @($response.Body.error.details | ForEach-Object { "$($_.message)" }) -join ' | '
        throw "ARM $Method $Path returned HTTP $($response.Status). $detail $nested".Trim()
    }
    $response.Body
}

function Get-RevisionState {
    param([scriptblock]$Arm, $Target)
    $api = Invoke-Arm $Arm GET "$($Target.ApiResourceId)?api-version=$script:ApiVersion"
    if (-not [string]::Equals("$($api.properties.path)", $Target.ApiPath, 'Ordinal')) {
        throw "API $($Target.ApiId) has path '$($api.properties.path)', not the configured '$($Target.ApiPath)'. Nothing was changed."
    }
    $revisions = @((Invoke-Arm $Arm GET "$($Target.ApiResourceId)/revisions?api-version=$script:ApiVersion").value)
    $current = @($revisions | Where-Object { $_.isCurrent })
    if ($current.Count -ne 1) { throw "API $($Target.ApiId) has $($current.Count) current revisions; expected one. Nothing was changed." }
    [pscustomobject]@{
        Current = [string]$current[0].apiRevision
        Max = [int](($revisions | ForEach-Object { [int]$_.apiRevision } | Measure-Object -Maximum).Maximum)
        Revisions = @($revisions | ForEach-Object { [string]$_.apiRevision })
        Offline = @($revisions | Where-Object { $_.isOnline -eq $false } | ForEach-Object { [string]$_.apiRevision })
    }
}

function Set-RevisionOnline {
    <# Puts a non-current revision online or offline and checks the result. An offline revision answers 404 at ;rev=N. #>
    param([scriptblock]$Arm, $Target, [string]$Revision, [bool]$Online)
    $path = "$($Target.ApiResourceId);rev=$Revision`?api-version=$script:ApiVersion"
    $null = Invoke-Arm $Arm PATCH $path @{ properties = @{ isOnline = $Online } } -Expect 200, 204 -Headers @{ 'If-Match' = '*' }
    $check = Invoke-Arm $Arm GET $path
    if ($check.properties.isOnline -ne $Online) { throw "Revision $Revision of $($Target.ApiId) did not become $(if ($Online) { 'online' } else { 'offline' })." }
}

function Read-GatewayAnswers {
    <# An answers file for one action. Every field is required; there are no defaults. #>
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [ValidateSet('createRevision', 'makeCurrent', 'takeOffline')] [string]$Action)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Answers file not found: $Path. Nothing was changed." }
    try { $answers = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Answers file $Path is not valid JSON. Nothing was changed." }
    $required = @{
        createRevision = [ordered]@{ action = '^createRevision$'; apiId = $script:Name; configurationId = $script:Name; expectedCurrentRevision = $script:RevisionPattern; policySha256 = '^[0-9a-f]{64}$'; approvedBy = $script:Guid }
        makeCurrent = [ordered]@{ action = '^makeCurrent$'; apiId = $script:Name; revision = $script:RevisionPattern; expectedCurrentRevision = $script:RevisionPattern; releaseNote = '^[^\x00-\x1f]{10,1000}$'; approvedBy = $script:Guid }
        takeOffline = [ordered]@{ action = '^takeOffline$'; apiId = $script:Name; revision = $script:RevisionPattern; expectedCurrentRevision = $script:RevisionPattern; approvedBy = $script:Guid }
    }[$Action]
    foreach ($key in $required.Keys) {
        $value = $answers.$key
        if (-not ($value -is [string] -and $value -cmatch $required[$key])) { throw "Answers file ${Path}: '$key' is missing or invalid for action $Action. Nothing was changed." }
    }
    $answers
}

function Test-InteractiveSession {
    -not [Console]::IsInputRedirected -and [Environment]::UserInteractive
}

function Format-PolicyForCompare {
    param([string]$Text)
    (($Text -replace "`r`n", "`n").Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) -join "`n"
}

function Write-PolicyDiff {
    <# Writes both policies and a whitespace-insensitive unified diff to OutDir; returns the diff lines. #>
    param([string]$CurrentPolicy, [string]$RenderedPolicy, [string]$CurrentRevision, [string]$OutDir)
    $currentPath = Join-Path $OutDir "current-rev$CurrentRevision.policy.xml"
    $renderedPath = Join-Path $OutDir 'rendered.policy.xml'
    Set-Content -LiteralPath $currentPath -Value $CurrentPolicy -Encoding utf8NoBOM -NoNewline
    Set-Content -LiteralPath $renderedPath -Value $RenderedPolicy -Encoding utf8NoBOM -NoNewline
    $lines = if (Get-Command git -ErrorAction SilentlyContinue) {
        @(git diff --no-index --no-color -w --stat=200 -U2 -- $currentPath $renderedPath 2>&1 | ForEach-Object { "$_" })
    } else {
        @(Compare-Object (Get-Content $currentPath) (Get-Content $renderedPath) | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" })
    }
    Set-Content -LiteralPath (Join-Path $OutDir "diff-vs-rev$CurrentRevision.txt") -Value $lines -Encoding utf8NoBOM
    $lines
}

function Invoke-GatewayRevisionDeployment {
    <# Renders, shows the diff, confirms, creates revision N+1 (non-current) and saves the policy to it. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ConfigPath,
        [Parameter(Mandatory)] [string]$OutDir,
        [string]$AnswersPath,
        [switch]$NonInteractive,
        [scriptblock]$Render = { param($Config, $Out) Invoke-GatewayRender -ConfigPath $Config -OutDir $Out },
        $ArmSession,
        [scriptblock]$Prompt = { param($Message) Read-Host $Message },
        [scriptblock]$IsInteractive = { Test-InteractiveSession }
    )
    $target = Read-GatewayTarget -ConfigPath $ConfigPath
    $answers = if ($AnswersPath) { Read-GatewayAnswers -Path $AnswersPath -Action createRevision } else { $null }
    if (-not $answers -and ($NonInteractive -or -not (& $IsInteractive))) {
        throw 'Refused: this run is not interactive and no -AnswersPath was given, so nothing can confirm the deployment. Nothing was changed.'
    }
    $rendered = & $Render $ConfigPath $OutDir
    $auditPath = Join-Path $OutDir 'audit.jsonl'
    $session = if ($ArmSession) { $ArmSession } else { New-ArmInvoker -SubscriptionId $target.SubscriptionId }
    $arm = $session.Invoke
    $state = Get-RevisionState -Arm $arm -Target $target
    $current = Invoke-Arm $arm GET "$($target.ApiResourceId)/policies/policy?api-version=$script:ApiVersion&format=rawxml" -Expect 200
    $diff = Write-PolicyDiff -CurrentPolicy "$($current.properties.value)" -RenderedPolicy $rendered.PolicyXml -CurrentRevision $state.Current -OutDir $OutDir
    Write-Host "Changes from the current revision ($($state.Current)) of $($target.ApiId), whitespace ignored:"
    $diff | ForEach-Object { Write-Host $_ }
    $next = [string]($state.Max + 1)
    $digest12 = $rendered.PolicySha256.Substring(0, 12)
    $approvedBy = if ($answers) {
        $mismatch = @(
            if (-not [string]::Equals($answers.apiId, $target.ApiId, 'Ordinal')) { "apiId is $($answers.apiId), not $($target.ApiId)" }
            if (-not [string]::Equals($answers.configurationId, $rendered.ConfigurationId, 'Ordinal')) { "configurationId is $($answers.configurationId), not $($rendered.ConfigurationId)" }
            if (-not [string]::Equals($answers.expectedCurrentRevision, $state.Current, 'Ordinal')) { "expectedCurrentRevision is $($answers.expectedCurrentRevision), but revision $($state.Current) is current" }
            if (-not [string]::Equals($answers.policySha256, $rendered.PolicySha256, 'Ordinal')) { "policySha256 does not match the rendered policy ($($rendered.PolicySha256))" }
        )
        if ($mismatch.Count -gt 0) {
            $null = Write-GatewayAudit -Event 'create_refused' -AuditPath $auditPath -Data @{ apiId = $target.ApiId; reason = 'answers_mismatch'; policySha256 = $rendered.PolicySha256 }
            throw "Refused: the answers file does not approve this deployment: $($mismatch -join '; '). Nothing was changed."
        }
        $answers.approvedBy
    } else {
        $typed = & $Prompt "Create revision $next of $($target.ApiId) (NOT current) with policy $digest12? Type the 12 characters $digest12 to confirm"
        if (-not [string]::Equals("$typed".Trim(), $digest12, 'Ordinal')) {
            $null = Write-GatewayAudit -Event 'create_refused' -AuditPath $auditPath -Data @{ apiId = $target.ApiId; reason = 'not_confirmed'; policySha256 = $rendered.PolicySha256 }
            throw 'Refused: the confirmation did not match the policy digest. Nothing was changed.'
        }
        $session.ActorObjectId
    }
    $common = @{ apiId = $target.ApiId; revision = $next; currentRevision = $state.Current; configurationId = $rendered.ConfigurationId; policySha256 = $rendered.PolicySha256; configSha256 = $rendered.ConfigSha256; templateSha256 = $rendered.TemplateSha256; actorObjectId = $session.ActorObjectId; approvedBy = $approvedBy }
    $revisionPath = "$($target.ApiResourceId);rev=$next"
    $created = Invoke-Arm $arm PUT "$revisionPath`?api-version=$script:ApiVersion" @{ properties = @{ sourceApiId = "$($target.ApiResourceId);rev=$($state.Current)"; apiRevisionDescription = "Gateway policy $digest12 from configuration $($rendered.ConfigurationId)" } } -Expect 200, 201
    if ($created.properties.isCurrent -eq $true) { throw "Revision $next was created as the current revision; make revision $($state.Current) current again at once (Invoke-GatewayMakeCurrent)." }
    $null = Write-GatewayAudit -Event 'revision_created' -AuditPath $auditPath -Data $common
    try {
        $null = Invoke-Arm $arm PUT "$revisionPath/policies/policy?api-version=$script:ApiVersion" @{ properties = @{ format = 'rawxml'; value = $rendered.PolicyXml } } -Expect 200, 201
    } catch {
        $null = Write-GatewayAudit -Event 'policy_refused' -AuditPath $auditPath -Data ($common + @{ reason = 'apim_validation' })
        throw "APIM refused the policy for revision $next, which is left non-current with a copy of revision $($state.Current)'s policy. $($_.Exception.Message)"
    }
    $check = Invoke-Arm $arm GET "$revisionPath`?api-version=$script:ApiVersion"
    if ($check.properties.isCurrent -eq $true) { throw "Revision $next is current after the policy was saved; make revision $($state.Current) current again at once." }
    $stored = Invoke-Arm $arm GET "$revisionPath/policies/policy?api-version=$script:ApiVersion&format=rawxml"
    $matches = [string]::Equals((Format-PolicyForCompare "$($stored.properties.value)"), (Format-PolicyForCompare $rendered.PolicyXml), 'Ordinal')
    $url = "$($target.GatewayBaseUrl)/$($target.ApiPath);rev=$next"
    $null = Write-GatewayAudit -Event 'policy_saved' -AuditPath $auditPath -Data ($common + @{ storedMatchesRendered = $matches })
    $result = [pscustomobject]@{ Action = 'createRevision'; ApiId = $target.ApiId; Revision = $next; CurrentRevision = $state.Current; RevisionUrl = $url; PolicySha256 = $rendered.PolicySha256; StoredMatchesRendered = $matches; ConfigurationId = $rendered.ConfigurationId }
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutDir 'deployment.json') -Encoding utf8NoBOM
    $result
}

function Invoke-GatewayMakeCurrent {
    <# Makes one existing revision current with a release note. Rollback is this, for the previous revision. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ConfigPath,
        [Parameter(Mandatory)] [ValidatePattern('^[1-9][0-9]{0,5}$')] [string]$Revision,
        [Parameter(Mandatory)] [string]$OutDir,
        [string]$ReleaseNote,
        [string]$AnswersPath,
        [switch]$NonInteractive,
        $ArmSession,
        [scriptblock]$Prompt = { param($Message) Read-Host $Message },
        [scriptblock]$UtcNow = { [datetime]::UtcNow },
        [scriptblock]$IsInteractive = { Test-InteractiveSession }
    )
    $target = Read-GatewayTarget -ConfigPath $ConfigPath
    $answers = if ($AnswersPath) { Read-GatewayAnswers -Path $AnswersPath -Action makeCurrent } else { $null }
    if (-not $answers -and ($NonInteractive -or -not (& $IsInteractive))) {
        throw 'Refused: this run is not interactive and no -AnswersPath was given, so nothing can confirm the release. Nothing was changed.'
    }
    $note = if ($answers) { $answers.releaseNote } else { $ReleaseNote }
    if (-not ($note -is [string] -and $note -cmatch '^[^\x00-\x1f]{10,1000}$')) { throw 'Refused: a release note of 10 to 1000 characters is required (-ReleaseNote or the answers file). Nothing was changed.' }
    if ($answers -and -not [string]::Equals($answers.revision, $Revision, 'Ordinal')) { throw "Refused: the answers file approves revision $($answers.revision), not $Revision. Nothing was changed." }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $auditPath = Join-Path $OutDir 'audit.jsonl'
    $session = if ($ArmSession) { $ArmSession } else { New-ArmInvoker -SubscriptionId $target.SubscriptionId }
    $arm = $session.Invoke
    $state = Get-RevisionState -Arm $arm -Target $target
    if ($state.Revisions -notcontains $Revision) { throw "Revision $Revision of $($target.ApiId) does not exist. Nothing was changed." }
    if ([string]::Equals($state.Current, $Revision, 'Ordinal')) { throw "Revision $Revision is already current. Nothing was changed." }
    $approvedBy = if ($answers) {
        if (-not [string]::Equals($answers.apiId, $target.ApiId, 'Ordinal') -or -not [string]::Equals($answers.expectedCurrentRevision, $state.Current, 'Ordinal')) {
            throw "Refused: the answers file expects $($answers.apiId) with revision $($answers.expectedCurrentRevision) current; revision $($state.Current) of $($target.ApiId) is current. Nothing was changed."
        }
        $answers.approvedBy
    } else {
        $expected = "$($target.ApiId);rev=$Revision"
        $typed = & $Prompt "Make $expected CURRENT (replacing revision $($state.Current)) for every caller? Type $expected to confirm"
        if (-not [string]::Equals("$typed".Trim(), $expected, 'Ordinal')) { throw 'Refused: the confirmation did not match. Nothing was changed.' }
        $session.ActorObjectId
    }
    $releaseId = "ccof-$((& $UtcNow).ToString('yyyyMMddHHmmss'))-rev$Revision"
    $data = @{ apiId = $target.ApiId; revision = $Revision; previousCurrentRevision = $state.Current; releaseId = $releaseId; actorObjectId = $session.ActorObjectId; approvedBy = $approvedBy }
    if ($state.Offline -contains $Revision) {
        Set-RevisionOnline -Arm $arm -Target $target -Revision $Revision -Online $true
        $null = Write-GatewayAudit -Event 'revision_online' -AuditPath $auditPath -Data @{ apiId = $target.ApiId; revision = $Revision; currentRevision = $state.Current; actorObjectId = $session.ActorObjectId; approvedBy = $approvedBy }
    }
    $null = Invoke-Arm $arm PUT "$($target.ApiResourceId)/releases/$releaseId`?api-version=$script:ApiVersion" @{ properties = @{ apiId = "$($target.ApiResourceId);rev=$Revision"; notes = $note } } -Expect 200, 201
    $after = Get-RevisionState -Arm $arm -Target $target
    $ok = [string]::Equals($after.Current, $Revision, 'Ordinal')
    $null = Write-GatewayAudit -Event ($(if ($ok) { 'revision_made_current' } else { 'make_current_unverified' })) -AuditPath $auditPath -Data $data
    Write-Host "Rollback: Deploy-GatewayRevision.ps1 -ConfigPath <config> -MakeCurrent -Revision $($state.Current) -ReleaseNote '<why>'"
    if (-not $ok) { throw "The release was created but revision $($after.Current) is current, not $Revision. Check the API's releases." }
    # The replaced revision would still answer at ;rev=N with its older policy; rollback brings it back online.
    Set-RevisionOnline -Arm $arm -Target $target -Revision $state.Current -Online $false
    $null = Write-GatewayAudit -Event 'revision_offline' -AuditPath $auditPath -Data @{ apiId = $target.ApiId; revision = $state.Current; currentRevision = $Revision; actorObjectId = $session.ActorObjectId; approvedBy = $approvedBy }
    [pscustomobject]@{ Action = 'makeCurrent'; ApiId = $target.ApiId; Revision = $Revision; PreviousCurrentRevision = $state.Current; PreviousRevisionOffline = $true; ReleaseId = $releaseId; RollbackRevision = $state.Current }
}

function Invoke-GatewayTakeOffline {
    <# Takes a superseded, non-current revision offline, so it can no longer be called at ;rev=N. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ConfigPath,
        [Parameter(Mandatory)] [ValidatePattern('^[1-9][0-9]{0,5}$')] [string]$Revision,
        [Parameter(Mandatory)] [string]$OutDir,
        [string]$AnswersPath,
        [switch]$NonInteractive,
        $ArmSession,
        [scriptblock]$Prompt = { param($Message) Read-Host $Message },
        [scriptblock]$IsInteractive = { Test-InteractiveSession }
    )
    $target = Read-GatewayTarget -ConfigPath $ConfigPath
    $answers = if ($AnswersPath) { Read-GatewayAnswers -Path $AnswersPath -Action takeOffline } else { $null }
    if (-not $answers -and ($NonInteractive -or -not (& $IsInteractive))) {
        throw 'Refused: this run is not interactive and no -AnswersPath was given, so nothing can confirm taking the revision offline. Nothing was changed.'
    }
    if ($answers -and -not [string]::Equals($answers.revision, $Revision, 'Ordinal')) { throw "Refused: the answers file names revision $($answers.revision), not $Revision. Nothing was changed." }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $auditPath = Join-Path $OutDir 'audit.jsonl'
    $session = if ($ArmSession) { $ArmSession } else { New-ArmInvoker -SubscriptionId $target.SubscriptionId }
    $arm = $session.Invoke
    $state = Get-RevisionState -Arm $arm -Target $target
    if ($state.Revisions -notcontains $Revision) { throw "Revision $Revision of $($target.ApiId) does not exist. Nothing was changed." }
    if ([string]::Equals($state.Current, $Revision, 'Ordinal')) { throw "Revision $Revision is the current revision and cannot be taken offline. Nothing was changed." }
    $approvedBy = if ($answers) {
        if (-not [string]::Equals($answers.apiId, $target.ApiId, 'Ordinal') -or -not [string]::Equals($answers.expectedCurrentRevision, $state.Current, 'Ordinal')) {
            throw "Refused: the answers file expects $($answers.apiId) with revision $($answers.expectedCurrentRevision) current; revision $($state.Current) of $($target.ApiId) is current. Nothing was changed."
        }
        $answers.approvedBy
    } else {
        $expected = "$($target.ApiId);rev=$Revision"
        $typed = & $Prompt "Take $expected OFFLINE (it will answer 404)? Type $expected to confirm"
        if (-not [string]::Equals("$typed".Trim(), $expected, 'Ordinal')) { throw 'Refused: the confirmation did not match. Nothing was changed.' }
        $session.ActorObjectId
    }
    Set-RevisionOnline -Arm $arm -Target $target -Revision $Revision -Online $false
    $null = Write-GatewayAudit -Event 'revision_offline' -AuditPath $auditPath -Data @{ apiId = $target.ApiId; revision = $Revision; currentRevision = $state.Current; actorObjectId = $session.ActorObjectId; approvedBy = $approvedBy }
    [pscustomobject]@{ Action = 'takeOffline'; ApiId = $target.ApiId; Revision = $Revision; CurrentRevision = $state.Current }
}

function Invoke-GatewayRender {
    <# Renders with infra/gateway/render.ts; the renderer validates the configuration first. #>
    param([Parameter(Mandatory)] [string]$ConfigPath, [Parameter(Mandatory)] [string]$OutDir)
    $renderer = Join-Path $PSScriptRoot 'render.ts'
    $output = node $renderer --config $ConfigPath --out $OutDir 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Rendering refused, nothing was changed:`n$($output -join "`n")" }
    $summary = ($output | Select-Object -Last 1) | ConvertFrom-Json
    [pscustomobject]@{
        ConfigurationId = $summary.configurationId; ApiId = $summary.apiId; PolicySha256 = $summary.policySha256
        ConfigSha256 = $summary.configSha256; TemplateSha256 = $summary.templateSha256; PolicyXml = (Get-Content -LiteralPath $summary.policyPath -Raw)
    }
}

Export-ModuleMember -Function Invoke-GatewayRevisionDeployment, Invoke-GatewayMakeCurrent, Invoke-GatewayTakeOffline, Invoke-GatewayRender, Read-GatewayAnswers, Read-GatewayTarget, New-ArmInvoker, Write-GatewayAudit
