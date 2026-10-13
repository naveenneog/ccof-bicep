#Requires -Version 7.0
<#
.SYNOPSIS
    Tests quick-start step 5, the seed (ADR-0024; infra/quickstart/Deploy-Quickstart.ps1,
    infra/quickstart/runner/seed-cosmos.py):
    - the runner script against a fake instance metadata service and Cosmos DB REST endpoint
      (tests/quickstart_seed_fake.py): Entra authorization string, create only (no upsert),
      partition key, read-back, a rerun finds every document present, a differing document is
      reported by name and left unchanged, a 403 while a role assignment applies is retried, and a
      lasting 403 fails;
    - the documents: the projects documents pass onboarding Stage 3's own schema, one classification
      per group; one backends document per backend in the resolver's shape;
    - the Run Command script: what it carries, and the inputs it refuses;
    - the step with the runner (runner.enabled true): created and present pass; differs, failed and
      a missing result fail with the names;
    - the step without the runner (the default), with fakes for az and the Application Insights
      query API: the settings that start the sync app's registrySeed function, the poll for its
      ccof.seed.result line, the cleanup after success, timeout and failure, and the named reasons;
    - a relative -ParametersPath resolves against the PowerShell location, not the process directory.
#>

$ErrorActionPreference = 'Continue'
$script:Pass = 0
$script:Fail = 0
trap { Write-Host "FAIL: unexpected error: $_" -ForegroundColor Red; $script:Fail++; continue }
$root = Split-Path $PSScriptRoot -Parent

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green; $script:Pass++ }
    else { Write-Host "FAIL: $Name $Detail" -ForegroundColor Red; $script:Fail++ }
}

$seedPy = Join-Path $root 'infra' 'quickstart' 'runner' 'seed-cosmos.py'
$work = Join-Path $PSScriptRoot ".env.qs-seed-test-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $work | Out-Null

# --- 1. The runner script against a fake IMDS and Cosmos DB ---
Assert-True 'infra/quickstart/runner/seed-cosmos.py exists' (Test-Path $seedPy)
$python = @('python3', 'python' | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue })[0]
Assert-True 'a Python 3 interpreter is available for the runner script test' ([bool]$python)
if ((Test-Path $seedPy) -and $python) {
    $raw = & $python (Join-Path $PSScriptRoot 'quickstart_seed_fake.py') $seedPy $work 2>&1
    $fake = try { (@($raw) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 50 } catch { $null }
    Assert-True 'the fake run produced a result' ($null -ne $fake) "output: $(@($raw) -join ' ')"
    if ($fake) {
        function Get-SeedLines($Run) { @($Run.stdout | Where-Object { $_.StartsWith('CCOF_SEED ') } | ForEach-Object { $_.Substring(10) | ConvertFrom-Json -AsHashtable }) }
        function Get-SeedDone($Run) { $d = @($Run.stdout | Where-Object { $_.StartsWith('CCOF_SEED_DONE ') })[-1]; if ($d) { $d.Substring(15) | ConvertFrom-Json -AsHashtable } }
        $first = $fake.first
        $lines = @(Get-SeedLines $first)
        Assert-True 'first run: both documents created, exit 0' ($first.exit -eq 0 -and (@($lines | Where-Object outcome -eq 'created').Count -eq 2)) "exit=$($first.exit) lines=$($first.stdout -join ' | ') stderr=$($first.stderr)"
        Assert-True 'first run: the last line is CCOF_SEED_DONE ok' ((Get-SeedDone $first).ok -eq $true -and $first.stdout[-1].StartsWith('CCOF_SEED_DONE '))
        $cosmosCalls = @($first.requests | Where-Object { $_.path -like '/dbs/*' })
        Assert-True 'every Cosmos call carries type=aad&ver=1.0&sig=<token>, x-ms-version and x-ms-date' (@($cosmosCalls | Where-Object { $_.authorization -cne 'type=aad&ver=1.0&sig=fake-token-123' -or -not $_.version -or -not $_.date }).Count -eq 0 -and $cosmosCalls.Count -gt 0)
        Assert-True 'no call asks for an upsert (the runner role has items/create only)' (@($fake.first.requests + $fake.rerun.requests + $fake.differs.requests | Where-Object { $_.upsert }).Count -eq 0)
        $posts = @($first.requests | Where-Object method -eq 'POST')
        Assert-True 'documents are created with POST .../docs and their partition key' ($posts.Count -eq 2 -and @($posts | Where-Object { $_.path -eq '/dbs/ccof/colls/projects/docs' -and $_.partitionKey -eq '["P1"]' }).Count -eq 1 -and @($posts | Where-Object { $_.path -eq '/dbs/ccof/colls/backends/docs' -and $_.partitionKey -eq '["b-1"]' }).Count -eq 1)
        $imds = @($first.requests | Where-Object path -eq '/metadata/identity/oauth2/token')
        Assert-True 'the token comes from IMDS with Metadata: true, for the account origin' ($imds.Count -ge 1 -and $imds[0].metadata -eq 'true' -and $imds[0].query -match 'resource=https%3A%2F%2F127\.0\.0\.1(&|$)')
        Assert-True 'each created document is read back (GET after POST)' (@($first.requests | Where-Object { $_.method -eq 'GET' -and $_.path -eq '/dbs/ccof/colls/projects/docs/P1' }).Count -ge 2)
        $rerun = @(Get-SeedLines $fake.rerun)
        Assert-True 'a rerun finds both present and writes nothing' ($fake.rerun.exit -eq 0 -and @($rerun | Where-Object outcome -eq 'present').Count -eq 2 -and @($fake.rerun.requests | Where-Object method -eq 'POST').Count -eq 0)
        $differs = @(Get-SeedLines $fake.differs)
        Assert-True 'a differing document is reported by container, id and field, exit 1' ($fake.differs.exit -eq 1 -and $differs.Count -eq 1 -and $differs[0].outcome -eq 'differs' -and $differs[0].container -eq 'projects' -and $differs[0].id -eq 'P1' -and (@($differs[0].fields) -join ',') -eq 'classifications')
        Assert-True 'a differing document is never overwritten' ($fake.storedAfterDiffers.classifications.STD.groupId -eq 'g' -and @($fake.differs.requests | Where-Object method -ne 'GET').Count -eq 0)
        Assert-True 'the differing value is not printed' (-not (@($fake.differs.stdout) -join ' ').Contains('other'))
        $retried = @(Get-SeedLines $fake.forbiddenThenAllowed)
        Assert-True 'a 403 while the role assignment applies is retried, then created' ($fake.forbiddenThenAllowed.exit -eq 0 -and $retried[0].outcome -eq 'created')
        $denied = @(Get-SeedLines $fake.forbidden)
        Assert-True 'a lasting 403 fails the document with its step and status' ($fake.forbidden.exit -eq 1 -and $denied[0].outcome -eq 'failed' -and $denied[0].status -eq 403 -and $denied[0].step -eq 'read')
    }
}

# --- The wrapper's step 5 ---
$wrapper = Join-Path $root 'infra' 'quickstart' 'Deploy-Quickstart.ps1'
. $wrapper -DotSourceOnly
$built = az bicep build-params --file (Join-Path $root 'infra' 'quickstart' 'main.bicepparam') --stdout 2>$null | ConvertFrom-Json -AsHashtable
$P = @{}; $parameters = ($built.parametersJson | ConvertFrom-Json -AsHashtable -Depth 100).parameters; foreach ($k in $parameters.Keys) { $P[$k] = $parameters[$k].value }

# --- 2. The documents ---
$docs = New-QsSeedDocuments -P $P
Import-Module (Join-Path $root 'scripts' 'Onboarding.Projects.psm1') -Force -DisableNameChecking
$projectIds = @($P.groups | ForEach-Object projectId | Select-Object -Unique)
Assert-True 'one projects document per projectId' (@($docs.projects).Count -eq $projectIds.Count) "got $(@($docs.projects).Count)"
foreach ($project in @($docs.projects)) {
    $valid = try { $null = ConvertTo-OnboardingProjectDocument -Project ($project | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable); $true } catch { Write-Host "  schema: $($_.Exception.Message)"; $false }
    Assert-True "projects document $($project.id) passes onboarding Stage 3's schema" $valid
}
$registered = @($docs.projects | ForEach-Object { foreach ($c in $_.classifications.Keys) { "$($_.projectId)/$c/$($_.classifications[$c].groupId)" } } | Sort-Object)
$wanted = @($P.groups | ForEach-Object { "$($_.projectId)/$($_.classification)/$($_.groupId)" } | Sort-Object)
Assert-True 'every group is one classification of its project, with its group id' (($registered -join ',') -ceq ($wanted -join ',')) "got $($registered -join ',')"
$g = $P.groups[0]; $c = @($docs.projects | Where-Object projectId -eq $g.projectId)[0].classifications[$g.classification]
Assert-True 'a classification carries the group''s exact family policy, budgets and modes' (($c.familyPolicy | ConvertTo-Json -Depth 30 -Compress) -eq ($g.familyPolicy | ConvertTo-Json -Depth 30 -Compress) -and $c.aggregateMode -eq $g.aggregateMode -and $c.onboardingMode -eq $g.onboardingMode)
$b = $P.backends[0]
$bd = @($docs.backends)[0]
Assert-True 'one backends document per backend, in the resolver''s shape (src/resolver/backend.ts)' (@($docs.backends).Count -eq @($P.backends).Count -and $bd.id -eq $b.id -and $bd.backendId -eq $b.id -and $bd.status -eq 'active' -and $bd.apiFormat -eq 'anthropic-messages' -and $bd.auth.mode -eq 'managed-identity' -and $bd.auth.resource -eq $b.resource -and @($bd.Keys).Count -eq 5)
$entries = @(New-QsSeedEntries -Documents $docs)
Assert-True 'seed entries name the container and partition key of each document' ($entries.Count -eq (@($docs.projects).Count + @($docs.backends).Count) -and @($entries | Where-Object { ($_.container -eq 'projects' -and $_.partitionKey -ceq $_.document.projectId) -or ($_.container -eq 'backends' -and $_.partitionKey -ceq $_.document.backendId) }).Count -eq $entries.Count)

# --- 3. The Run Command script ---
$endpoint = 'https://example-sampleqs-cosmos.documents.azure.com:443/'
$script = New-QsSeedScript -Entries $entries -Endpoint $endpoint -Database 'ccof'
Assert-True 'the script is bash with LF line endings only' ($script.StartsWith("#!/bin/bash`n") -and -not $script.Contains("`r"))
Assert-True 'the script runs the runner script with python3, the endpoint and the database' ($script -match "python3 seed-cosmos\.py 'https://sampleqs-cosmos\.documents\.azure\.com:443/' 'ccof' documents\.json")
$blocks = [regex]::Matches($script, "<<'CCOF_B64'\n(?<b>[A-Za-z0-9+/=\n]+?)\nCCOF_B64")
$decoded = @($blocks | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($_.Groups['b'].Value -replace '\n', ''))) })
Assert-True 'the script carries the runner script unchanged (LF line endings)' ($decoded.Count -eq 2 -and $decoded[0] -ceq (Get-Content $seedPy -Raw).Replace("`r`n", "`n"))
$carried = if ($decoded.Count -eq 2) { $decoded[1] | ConvertFrom-Json -AsHashtable -Depth 50 } else { $null }
Assert-True 'the script carries the seed entries' ($carried -and @($carried).Count -eq $entries.Count -and $carried[0].document.id -eq $entries[0].document.id)
Assert-True 'the script stops when python3 is missing' ($script -match 'command -v python3')
foreach ($bad in @('http://example-sampleqs-cosmos.documents.azure.com/', "https://x'; rm -rf /; '.documents.azure.com/", 'https://evil.example.com/')) {
    $refused = try { $null = New-QsSeedScript -Entries $entries -Endpoint $bad -Database 'ccof'; $false } catch { $_.Exception.Message -match '^seed_endpoint_invalid' }
    Assert-True "the script refuses endpoint $bad" $refused
}
$refused = try { $null = New-QsSeedScript -Entries $entries -Endpoint $endpoint -Database "ccof' x"; $false } catch { $_.Exception.Message -match '^seed_database_invalid' }
Assert-True 'the script refuses a database name with a quote' $refused

# --- 4. The step ---
# The Run Command path runs only with the runner VM (runner.enabled true; ccof-bicep da86afb).
$P.runner = @{ enabled = $true; vmSize = 'Standard_D2as_v7'; adminUsername = 'ccofadmin'; sshPublicKey = 'ssh-rsa AAAAB3NzaC1yc2E example' }
function New-SeedContext([string[]]$Lines) {
    $message = "Enable succeeded: `n[stdout]`n$($Lines -join "`n")`n`n[stderr]`n"
    $ctx = @{ P = $P; GeneratedDir = $work; State = @{ completed = @{ '3' = @{ outputs = @{ cosmosEndpoint = $endpoint } } } } }
    $calls = $script:seedCalls
    $ctx.RunCommand = { param($P, $Script, $Name, $GeneratedDir) $calls.Add(@{ Name = $Name; Script = $Script }); $message }.GetNewClosure()
    $ctx
}
$script:seedCalls = [System.Collections.Generic.List[object]]::new()
$okLines = @($entries | ForEach-Object { 'CCOF_SEED ' + (@{ container = $_.container; id = $_.document.id; outcome = 'created'; status = 201 } | ConvertTo-Json -Compress) }) + 'CCOF_SEED_DONE {"ok":true,"created":3,"present":0,"differs":0,"failed":0}'
$out = $null; $out = Invoke-QsSeed (New-SeedContext $okLines)
Assert-True 'step 5 sends one Run Command script named seed' ($script:seedCalls.Count -eq 1 -and $script:seedCalls[0].Name -eq 'seed' -and $script:seedCalls[0].Script -match 'seed-cosmos\.py')
Assert-True 'step 5 passes when every document is created, and records them' ($entries.Count -gt 0 -and @($out.documents).Count -eq $entries.Count -and @($out.documents | Where-Object { $_ -match ': created$' }).Count -eq $entries.Count)
$presentLines = $okLines.Replace('"created"', '"present"')
$out = $null; $out = Invoke-QsSeed (New-SeedContext $presentLines)
Assert-True 'step 5 passes when every document is already present (rerun)' ($entries.Count -gt 0 -and @($out.documents | Where-Object { $_ -match ': present$' }).Count -eq $entries.Count)
$differs = @('CCOF_SEED {"container":"projects","id":"sampleqs01","outcome":"differs","fields":["classifications"],"status":200}', 'CCOF_SEED_DONE {"ok":false,"created":0,"present":0,"differs":1,"failed":0}')
$message = try { $null = Invoke-QsSeed (New-SeedContext $differs); '' } catch { $_.Exception.Message }
Assert-True 'step 5 fails on a differing document and names it' ($message -match '^seed_documents_differ' -and $message -match 'projects/sampleqs01' -and $message -match 'classifications')
$failed = @('CCOF_SEED {"container":"backends","id":"foundry-x","outcome":"failed","step":"create","status":403}', 'CCOF_SEED_DONE {"ok":false,"created":0,"present":0,"differs":0,"failed":1}')
$message = try { $null = Invoke-QsSeed (New-SeedContext $failed); '' } catch { $_.Exception.Message }
Assert-True 'step 5 fails on a failed document with its step and status' ($message -match '^seed_failed' -and $message -match 'backends/foundry-x' -and $message -match 'create' -and $message -match '403')
$message = try { $null = Invoke-QsSeed (New-SeedContext @('something else')); '' } catch { $_.Exception.Message }
Assert-True 'step 5 fails when the runner printed no result line' ($message -match '^seed_no_result')
$missing = @($okLines[0], 'CCOF_SEED_DONE {"ok":true,"created":1,"present":0,"differs":0,"failed":0}')
$message = try { $null = Invoke-QsSeed (New-SeedContext $missing); '' } catch { $_.Exception.Message }
Assert-True 'step 5 fails when a document has no result line' ($message -match '^seed_incomplete')

# --- 5. Without the runner (the default): the sync app's registrySeed function, through app settings ---
$P.runner = @{ enabled = $false }
$syncApp = $P.names.apps.sync.functionApp
$aiAppId = '00000000-0000-4000-8000-000001110011'
$script:Az = [System.Collections.Generic.List[string]]::new()
$script:Queries = [System.Collections.Generic.List[object]]::new()
$script:Payload = $null
$script:FailCleanup = $false
$script:AppInsightsAppId = $aiAppId
$script:SeedUnlistedReads = 0
$script:FunctionReads = 0
function Invoke-QsAz {
    param([string[]]$Arguments)
    $joined = $Arguments -join ' '
    $script:Az.Add($joined)
    if ($joined -match '^rest --method get --url https://management\.azure\.com/.+/providers/Microsoft\.Insights/components/') { return @{ properties = @{ AppId = $script:AppInsightsAppId } } }
    if ($joined -match '^account get-access-token ') { return @{ accessToken = 'fake-ai-token'; tokenType = 'Bearer' } }
    if ($joined -match '^rest --method get --url https://management\.azure\.com/.+/providers/Microsoft\.Web/sites/[^/]+/functions\?') {
        # The sync app's function list: registrySeed is absent for the first $script:SeedUnlistedReads reads.
        $script:FunctionReads++
        $names = if ($script:FunctionReads -le $script:SeedUnlistedReads) { @('syncEntitlement') } else { @('registrySeed', 'syncEntitlement') }
        return @{ value = @($names | ForEach-Object { @{ name = "$syncApp/$_" } }) }
    }
    if ($joined -match '^functionapp config appsettings set ' -and $joined -match ' CCOF_SEED_DOCUMENTS=(\S+)') {
        $script:Payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])) | ConvertFrom-Json -AsHashtable -Depth 50
    }
    if ($script:FailCleanup -and $joined -match '^functionapp config appsettings (set .*registrySeed\.Disabled=true|delete )') { throw "az functionapp config failed: fake" }
    return ''
}
function New-SeedLine {
    param([string]$Outcome, [object[]]$Documents, [string]$Reason)
    $line = [ordered]@{ schema = 'ccof.seed.result.v1'; seedId = $script:Payload.seedId; outcome = $Outcome; counts = @{}; documents = @($Documents); startedAt = '2026-10-13T13:00:00.000Z'; durationMs = 900 }
    if ($Reason) { $line.reason = $Reason }
    return ($line | ConvertTo-Json -Depth 10 -Compress)
}
function New-SeedDocumentResults([string]$Outcome) { @(@($entries | ForEach-Object { [ordered]@{ container = $_.container; id = $_.document.id; outcome = $Outcome } })) }
function New-AiResponse([string[]]$Messages) {
    # The query API's JSON (tables, columns, rows), parsed as Invoke-RestMethod parses it.
    $i = 0
    $rows = @($Messages | Where-Object { $_ } | ForEach-Object { $i++; , @("2026-10-13T13:0$($i):00Z", $_) })
    return (@{ tables = @(@{ name = 'PrimaryResult'; columns = @(@{ name = 'timestamp'; type = 'datetime' }, @{ name = 'message'; type = 'string' }); rows = $rows }) } | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
}
function New-FunctionSeedContext {
    # $Answers: one script block per poll (the last one repeats); each returns the result lines
    # visible by then, or throws as the query API would.
    param([scriptblock[]]$Answers)
    $script:Az.Clear(); $script:Queries.Clear(); $script:Payload = $null; $script:Answers = $Answers; $script:FunctionReads = 0
    $ctx = @{ P = $P; GeneratedDir = $work; PollSeconds = 0; SeedPollAttempts = 4; State = @{ completed = @{ '3' = @{ outputs = @{ cosmosEndpoint = $endpoint } } } } }
    $ctx.InvokeRest = {
        param($Uri, $Body, $Token)
        $script:Queries.Add(@{ Uri = $Uri; Body = $Body; Token = $Token; AzCallsBefore = $script:Az.Count })
        $answer = $script:Answers[[Math]::Min($script:Queries.Count, $script:Answers.Count) - 1]
        New-AiResponse @(& $answer)
    }
    return $ctx
}
function Get-AzIndex([string]$Pattern) { for ($i = 0; $i -lt $script:Az.Count; $i++) { if ($script:Az[$i] -match $Pattern) { return $i } }; return -1 }
$setSeed = "^functionapp config appsettings set --subscription $([regex]::Escape($P.names.subscriptionId)) --resource-group $([regex]::Escape($P.names.resourceGroup)) --name $([regex]::Escape($syncApp)) --settings CCOF_SEED_DOCUMENTS=[A-Za-z0-9+/]+=* AzureWebJobs\.registrySeed\.Disabled=false( |$)"
$setOff = "^functionapp config appsettings set --subscription $([regex]::Escape($P.names.subscriptionId)) --resource-group $([regex]::Escape($P.names.resourceGroup)) --name $([regex]::Escape($syncApp)) --settings AzureWebJobs\.registrySeed\.Disabled=true( |$)"
$deleteSeed = "^functionapp config appsettings delete --subscription $([regex]::Escape($P.names.subscriptionId)) --resource-group $([regex]::Escape($P.names.resourceGroup)) --name $([regex]::Escape($syncApp)) --setting-names CCOF_SEED_DOCUMENTS( |$)"
function Test-CleanedUp { $s = Get-AzIndex $setSeed; $o = Get-AzIndex $setOff; $d = Get-AzIndex $deleteSeed; return ($s -ge 0 -and $o -gt $s -and $d -gt $o) }

# Success: the first poll finds nothing yet, the second the function's line.
$ctx = New-FunctionSeedContext @({ @() }, { @(New-SeedLine 'succeeded' (New-SeedDocumentResults 'created')) })
$out = $null; $message = ''; try { $out = Invoke-QsSeed $ctx } catch { $message = $_.Exception.Message }
Assert-True 'without the runner, step 5 seeds through the function and passes when every document is created' ($null -ne $out -and -not $message -and @($out.documents | Where-Object { $_ -match ': created$' }).Count -eq $entries.Count) $message
Assert-True 'step 5 sends no Run Command without the runner' (@($script:Az | Where-Object { $_ -match '^vm run-command' }).Count -eq 0)
Assert-True 'step 5 sets CCOF_SEED_DOCUMENTS and AzureWebJobs.registrySeed.Disabled=false on the sync app in one call' ((Get-AzIndex $setSeed) -ge 0 -and @($script:Az | Where-Object { $_ -match '^functionapp config appsettings set .*CCOF_SEED_DOCUMENTS=' }).Count -eq 1) ($script:Az -join ' | ')
$expected = New-QsSeedDocuments -P $P
Assert-True 'CCOF_SEED_DOCUMENTS is base64 of { seedId, projects, backends }, the documents New-QsSeedDocuments builds' ($script:Payload -and (@($script:Payload.Keys | Sort-Object) -join ',') -ceq 'backends,projects,seedId' -and $script:Payload.seedId -cmatch '^[0-9a-f]{32}$' -and ($script:Payload.projects | ConvertTo-Json -Depth 30 -Compress) -ceq (@($expected.projects) | ConvertTo-Json -Depth 30 -Compress) -and ($script:Payload.backends | ConvertTo-Json -Depth 30 -Compress) -ceq (@($expected.backends) | ConvertTo-Json -Depth 30 -Compress))
Assert-True 'the seedId is new and recorded with the outcome' ($out.seedId -ceq $script:Payload.seedId -and $out.mechanism -ceq 'registrySeed')
$componentUrl = "https://management.azure.com/subscriptions/$($P.names.subscriptionId)/resourceGroups/$($P.names.resourceGroup)/providers/Microsoft.Insights/components/$($P.names.apps.sync.appInsights)?api-version=2020-02-02"
Assert-True 'step 5 reads the sync Application Insights app id through ARM before it changes anything' ((Get-AzIndex "^rest --method get --url $([regex]::Escape($componentUrl))$") -ge 0 -and (Get-AzIndex "^rest --method get --url $([regex]::Escape($componentUrl))$") -lt (Get-AzIndex $setSeed))
Assert-True 'step 5 asks for a trigger sync of the sync app after the settings change' ((Get-AzIndex "^rest --method post --url https://management\.azure\.com/subscriptions/$([regex]::Escape($P.names.subscriptionId))/resourceGroups/$([regex]::Escape($P.names.resourceGroup))/providers/Microsoft\.Web/sites/$([regex]::Escape($syncApp))/syncfunctiontriggers\?api-version=2024-04-01$") -gt (Get-AzIndex $setSeed))
$q = if ($script:Queries.Count) { $script:Queries[0] } else { @{} }
$qBody = if ($q.Body) { $q.Body | ConvertFrom-Json -AsHashtable } else { @{} }
Assert-True 'the poll POSTs the Application Insights query API of the sync app with a bearer token for https://api.applicationinsights.io' ($script:Queries.Count -eq 2 -and $q.Uri -ceq "https://api.applicationinsights.io/v1/apps/$aiAppId/query" -and $q.Token -ceq 'fake-ai-token' -and (Get-AzIndex '^account get-access-token --resource https://api\.applicationinsights\.io$') -ge 0) "queries=$($script:Queries.Count) uri=$($q.Uri)"
Assert-True 'the query looks for the ccof.seed.result line of this seedId in traces' ($qBody.query -match '^traces' -and $qBody.query.Contains($script:Payload.seedId) -and $qBody.query.Contains('ccof.seed.result') -and $qBody.timespan -ceq 'PT1H') "$($qBody.query)"
Assert-True 'after the poll, step 5 sets AzureWebJobs.registrySeed.Disabled=true, then deletes CCOF_SEED_DOCUMENTS' ((Test-CleanedUp) -and (Get-AzIndex $setOff) -ge $script:Queries[-1].AzCallsBefore) ($script:Az -join ' | ')
Assert-True 'no az argument carries a shell metacharacter (Invoke-QsAz refuses them)' (@($script:Az | Where-Object { $_ -match '[()|&<>^"]' }).Count -eq 0)
Assert-True 'no az call names a token, and the token reaches only the query API' (@($script:Az | Where-Object { $_ -match 'fake-ai-token' }).Count -eq 0)

# The live run of 2026-10-13 (-Only 5 a minute after a seed): the instance that started after the
# settings change had no CCOF_SEED_DOCUMENTS yet, so it registered no registrySeed, the trigger sync
# recorded only syncEntitlement, and the app scaled to zero for good (Flex Consumption wakes an app
# for the timers it knows). A poll without the line reads the function list and asks for another
# trigger sync while registrySeed is not listed; a manual trigger sync then listed it within 45 s.
$sync = "^rest --method post --url https://management\.azure\.com/.+/sites/$([regex]::Escape($syncApp))/syncfunctiontriggers\?api-version=2024-04-01$"
$list = "^rest --method get --url https://management\.azure\.com/subscriptions/$([regex]::Escape($P.names.subscriptionId))/resourceGroups/$([regex]::Escape($P.names.resourceGroup))/providers/Microsoft\.Web/sites/$([regex]::Escape($syncApp))/functions\?api-version=2024-04-01$"
$script:SeedUnlistedReads = 2
$ctx = New-FunctionSeedContext @({ @() }, { @() }, { @() }, { @(New-SeedLine 'succeeded' (New-SeedDocumentResults 'created')) })
$out = $null; $message = ''; try { $out = Invoke-QsSeed $ctx } catch { $message = $_.Exception.Message }
$syncs = @($script:Az | Where-Object { $_ -match $sync }).Count
Assert-True 'while registrySeed is not listed, each poll without the line asks for another trigger sync' ($null -ne $out -and $syncs -eq 3 -and @($script:Az | Where-Object { $_ -match $list }).Count -ge 3) "syncs=$syncs lists=$(@($script:Az | Where-Object { $_ -match $list }).Count) $message"
$script:SeedUnlistedReads = 0
$ctx = New-FunctionSeedContext @({ @() }, { @() }, { @(New-SeedLine 'succeeded' (New-SeedDocumentResults 'created')) })
$out = $null; $message = ''; try { $out = Invoke-QsSeed $ctx } catch { $message = $_.Exception.Message }
Assert-True 'once registrySeed is listed, no further trigger sync is asked for' ($null -ne $out -and @($script:Az | Where-Object { $_ -match $sync }).Count -eq 1) "syncs=$(@($script:Az | Where-Object { $_ -match $sync }).Count) $message"
# A run with failed documents is followed by the next timer run (every minute): a later line counts.
$ctx = New-FunctionSeedContext @({ @(New-SeedLine 'failed' (New-SeedDocumentResults 'failed' | ForEach-Object { $_.code = 'create_http_403'; $_ })) }, { @((New-SeedLine 'failed' (New-SeedDocumentResults 'failed' | ForEach-Object { $_.code = 'create_http_403'; $_ })), (New-SeedLine 'succeeded' (New-SeedDocumentResults 'created'))) })
$out = $null; $message = ''; try { $out = Invoke-QsSeed $ctx } catch { $message = $_.Exception.Message }
Assert-True 'a failed run followed by a successful one passes with the later outcome' ($null -ne $out -and -not $message -and @($out.documents | Where-Object { $_ -match ': created$' }).Count -eq $entries.Count) $message

# Timeout: no line within the polls.
$ctx = New-FunctionSeedContext @({ @() })
$message = try { $null = Invoke-QsSeed $ctx; '' } catch { $_.Exception.Message }
Assert-True 'no result line within the polls fails with seed_result_timeout naming the seed' ($message -match '^seed_result_timeout' -and $script:Payload -and $message.Contains($script:Payload.seedId) -and $script:Queries.Count -eq 4) $message
Assert-True 'after a timeout the settings are still reset (Disabled=true, CCOF_SEED_DOCUMENTS deleted)' (Test-CleanedUp) ($script:Az -join ' | ')

# A present document that differs.
$differs = New-SeedDocumentResults 'present-equal'
$differs[0].outcome = 'present-differs'; $differs[0].fields = @('classifications', 'displayName')
$ctx = New-FunctionSeedContext @({ @(New-SeedLine 'differs' $differs) })
$message = try { $null = Invoke-QsSeed $ctx; '' } catch { $_.Exception.Message }
Assert-True 'a present document that differs fails with seed_documents_differ, by container, id and field' ($message -match '^seed_documents_differ' -and $message.Contains("$($differs[0].container)/$($differs[0].id)") -and $message -match 'classifications, displayName') $message
Assert-True 'after differs the settings are reset' (Test-CleanedUp)

# Failed documents in three runs in a row (the line is built when polled, after step 5 chose the seedId).
$failedLine = { New-SeedLine 'failed' (New-SeedDocumentResults 'created' | ForEach-Object -Begin { $first = $true } -Process { if ($first) { $_.outcome = 'failed'; $_.code = 'create_http_403'; $first = $false }; $_ }) }
$ctx = New-FunctionSeedContext @({ @(& $failedLine) }, { @((& $failedLine), (& $failedLine)) }, { @((& $failedLine), (& $failedLine), (& $failedLine)) })
$message = try { $null = Invoke-QsSeed $ctx; '' } catch { $_.Exception.Message }
Assert-True 'a document that fails in three runs fails the step with seed_failed and its code' ($message -match '^seed_failed' -and $message.Contains("$($entries[0].container)/$($entries[0].document.id)") -and $message -match 'create_http_403' -and $script:Queries.Count -eq 3) $message
Assert-True 'after seed_failed the settings are reset' (Test-CleanedUp)

# The function refused the documents; a line without every document.
$ctx = New-FunctionSeedContext @({ @(New-SeedLine 'refused' @() 'seed_documents_invalid') })
$message = try { $null = Invoke-QsSeed $ctx; '' } catch { $_.Exception.Message }
Assert-True 'a refused seed fails with seed_refused and the function''s reason' ($message -match '^seed_refused' -and $message -match 'seed_documents_invalid') $message
$ctx = New-FunctionSeedContext @({ @(New-SeedLine 'succeeded' @((New-SeedDocumentResults 'created')[0])) })
$message = try { $null = Invoke-QsSeed $ctx; '' } catch { $_.Exception.Message }
Assert-True 'a line without every document fails with seed_incomplete' ($message -match '^seed_incomplete') $message
Assert-True 'after seed_incomplete the settings are reset' (Test-CleanedUp)

# The query API refuses (403): no point waiting.
$ctx = New-FunctionSeedContext @({ throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Response status code does not indicate success: 403 (Forbidden).', [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)) })
$message = try { $null = Invoke-QsSeed $ctx; '' } catch { $_.Exception.Message }
Assert-True 'a 403 from the query API fails at once with seed_query_failed and the status' ($message -match '^seed_query_failed' -and $message -match '403' -and $script:Queries.Count -eq 1 -and $message -notmatch 'fake-ai-token') $message
Assert-True 'after seed_query_failed the settings are reset' (Test-CleanedUp)
# A transient query error (no HTTP status) is retried.
$ctx = New-FunctionSeedContext @({ throw 'The SSL connection could not be established' }, { @(New-SeedLine 'succeeded' (New-SeedDocumentResults 'present-equal')) })
$out = $null; $message = ''; try { $out = Invoke-QsSeed $ctx } catch { $message = $_.Exception.Message }
Assert-True 'a transient query error is retried; a rerun finds every document present-equal' ($null -ne $out -and @($out.documents | Where-Object { $_ -match ': present-equal$' }).Count -eq $entries.Count) $message

# The cleanup fails: the step fails and names the commands.
$script:FailCleanup = $true
$ctx = New-FunctionSeedContext @({ @(New-SeedLine 'succeeded' (New-SeedDocumentResults 'created')) })
$message = try { $null = Invoke-QsSeed $ctx; '' } catch { $_.Exception.Message }
Assert-True 'a failed cleanup fails the step with seed_cleanup_failed and the commands to run' ($message -match '^seed_cleanup_failed' -and $message -match 'AzureWebJobs\.registrySeed\.Disabled=true' -and $message -match '--setting-names CCOF_SEED_DOCUMENTS') $message
$ctx = New-FunctionSeedContext @({ @() })
$message = try { $null = Invoke-QsSeed $ctx; '' } catch { $_.Exception.Message }
Assert-True 'a timeout and a failed cleanup are both named' ($message -match '^seed_result_timeout' -and $message -match 'Also seed_cleanup_failed' -and $message -match '--setting-names CCOF_SEED_DOCUMENTS') $message
$script:FailCleanup = $false

# Refusals before any change.
$ctx = New-FunctionSeedContext @({ @() }); $ctx.SeedSettingLimit = 100
$message = try { $null = Invoke-QsSeed $ctx; '' } catch { $_.Exception.Message }
Assert-True 'seed documents longer than the command line allows fail with seed_documents_too_large before any setting changes' ($message -match '^seed_documents_too_large' -and @($script:Az | Where-Object { $_ -match '^functionapp' }).Count -eq 0) $message
$script:AppInsightsAppId = ''
$ctx = New-FunctionSeedContext @({ @() })
$message = try { $null = Invoke-QsSeed $ctx; '' } catch { $_.Exception.Message }
Assert-True 'without the sync Application Insights app id step 5 fails with seed_app_insights_missing before any setting changes' ($message -match '^seed_app_insights_missing' -and @($script:Az | Where-Object { $_ -match '^functionapp' }).Count -eq 0) $message
$script:AppInsightsAppId = $aiAppId
$badP = $P | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
$badP.groups[0].familyPolicy.families.haiku.models = @('claude sonnet')
$ctx = New-FunctionSeedContext @({ @() }); $ctx.P = $badP
$message = try { $null = Invoke-QsSeed $ctx; '' } catch { $_.Exception.Message }
Assert-True 'a projects document that fails onboarding Stage 3''s schema is refused before any az call' ($message -match '^seed_document_invalid' -and $script:Az.Count -eq 0) $message

# The contract: what New-QsSeedPayload sends is what src/sync/registry-seed.ts accepts (run with node).
$contractSeedId = [guid]::NewGuid().ToString('N')
$env:CCOF_SEED_DOCUMENTS = New-QsSeedPayload -Documents (New-QsSeedDocuments -P $P) -SeedId $contractSeedId
try { $contractOut = @(node (Join-Path $PSScriptRoot 'helpers' 'registry-seed-contract.ts') 2>&1 | ForEach-Object { "$_" }) }
finally { Remove-Item Env:\CCOF_SEED_DOCUMENTS -ErrorAction SilentlyContinue }
$contract = @($contractOut | Where-Object { $_.StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable -Depth 20 })
$wantIds = @($entries | ForEach-Object { "$($_.container)/$($_.document.id)" } | Sort-Object)
Assert-True 'the registrySeed function accepts the documents step 5 sends and creates each one' ($contract.Count -eq 2 -and $contract[0].seedId -ceq $contractSeedId -and $contract[0].outcome -ceq 'succeeded' -and ((@($contract[0].documents | Where-Object { $_.outcome -ceq 'created' } | ForEach-Object { "$($_.container)/$($_.id)" } | Sort-Object) -join ',') -ceq ($wantIds -join ','))) ($contractOut -join ' | ')
Assert-True 'a second run of the function finds every document present-equal' ($contract.Count -eq 2 -and @($contract[1].documents | Where-Object { $_.outcome -ceq 'present-equal' }).Count -eq $wantIds.Count)

# --- 6. Azure Cloud Shell and Windows alike ---
$wrapperText = Get-Content -LiteralPath $wrapper -Raw
$resolveDir = Join-Path $work 'cwd'
New-Item -ItemType Directory -Path $resolveDir -Force | Out-Null
Push-Location $resolveDir
try {
    $resolved = Resolve-QsParametersPath 'infra/quickstart/.env.customer.bicepparam'
    $processBased = [System.IO.Path]::GetFullPath('infra/quickstart/.env.customer.bicepparam')
}
finally { Pop-Location }
Assert-True 'a relative -ParametersPath resolves against the PowerShell location ($PWD), not the process directory' ($resolved -and [System.IO.Path]::GetFullPath($resolved) -ceq [System.IO.Path]::GetFullPath((Join-Path $resolveDir 'infra/quickstart/.env.customer.bicepparam')) -and ([System.IO.Path]::GetFullPath($processBased) -cne [System.IO.Path]::GetFullPath($resolved))) "resolved=$resolved process=$processBased"
Assert-True 'an absolute -ParametersPath is kept' ((Resolve-QsParametersPath $seedPy) -ceq $seedPy)
Assert-True 'the wrapper resolves -ParametersPath with Resolve-QsParametersPath, never GetFullPath on the relative path' ($wrapperText -match '\$paramsFull = Resolve-QsParametersPath \$ParametersPath' -and $wrapperText -notmatch 'GetFullPath\(\$ParametersPath\)')
Assert-True 'the wrapper queries Application Insights with Invoke-RestMethod, never KQL through az' ($wrapperText -match 'Invoke-RestMethod -Method Post' -and $wrapperText -notmatch 'app-insights query' -and $wrapperText -notmatch 'monitor log-analytics query')
Assert-True 'the wrapper calls no Windows-only command' ($wrapperText -notmatch '(?m)\b(cmd(\.exe)? /c|powershell\.exe|Get-WmiObject|reg\.exe|\$env:ComSpec)')

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n$script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
exit 0
