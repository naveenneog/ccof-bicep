#Requires -Version 7.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'infra\quickstart\Deploy-Quickstart.ps1') -DotSourceOnly
$work=Join-Path $PSScriptRoot ".env.qs-client-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory $work | Out-Null
$pass=0
function Check($name,$ok) {if(-not $ok){throw "FAIL: $name"};$script:pass++;Write-Host "PASS: $name"}
function Limit {@{tokensPerMinute=$null;tokenQuota=$null;tokenQuotaPeriod=$null}}
function New-TestGroup($project,$backend,$classification,$models) {
    $families=@{}
    foreach($family in $models.Keys) {$families[$family]=@{models=@($models[$family]);person=(Limit);group=(Limit)}}
    @{projectId=$project;backendId=$backend;classification=$classification;groupId=[guid]::NewGuid().ToString()
      familyPolicy=@{aggregateLimits=@{person=(Limit);group=(Limit)};families=$families}
      personBudget=@{amount=25000;currency='CCU';period='monthly'};aggregateBudget=$null;aggregateMode='notify';onboardingMode='warn'}
}
$app='11111111-1111-1111-1111-111111111111'
$p=@{
    tenantId='22222222-2222-2222-2222-222222222222'
    registrations=@{gatewayApi=@{appId=$app;scope='access_as_user'};developerSignIn=@{appId=$app};resolverApi=@{appId='33333333-3333-3333-3333-333333333333'}}
    gateway=@{projectHeaderName='x-ccof-project'}
    groups=@((New-TestGroup 'PROJECT1' 'first' 'STD' @{haiku='first-haiku'}),(New-TestGroup 'PROJECT2' 'chosen' 'PRM' @{haiku='chosen-haiku';sonnet='chosen-sonnet';opus='chosen-opus'}))
    backends=@(@{id='first';subscriptionId=$app;resource='https://cognitiveservices.azure.com';deploymentInferenceGeo=@{'first-haiku'='global'}},
        @{id='chosen';subscriptionId='44444444-4444-4444-4444-444444444444';resource='https://cognitiveservices.azure.com';deploymentInferenceGeo=@{'chosen-haiku'='global';'chosen-sonnet'='global';'chosen-opus'='global';'unadmitted-deployment'='global'}})
    client=@{projectId='PROJECT2';classification='PRM';models=@{default='chosen-sonnet';haiku='chosen-haiku';sonnet='chosen-sonnet';opus='chosen-opus'}}
}
$ctx=@{P=$p;GeneratedDir=$work;State=@{completed=@{'1'=@{outputs=@{gatewayIdentifierUri="api://$app"}};'3'=@{outputs=@{gatewayUrl='https://gateway.example.test/anthropic'}}}}}
try {
    $out=Invoke-QsClient $ctx
    $config=Get-Content $out.clientConfig -Raw | ConvertFrom-Json -AsHashtable
    Check 'selected project not first group' ($config.project.id -ceq 'PROJECT2')
    Check 'aliases come from explicit project input' ($config.models.default -ceq 'chosen-sonnet' -and $config.models.opus -ceq 'chosen-opus')
    Check 'picker contains only selected backend exact admitted IDs' ((($config.models.available|Sort-Object)-join ',') -ceq 'chosen-haiku,chosen-opus,chosen-sonnet')
    Check 'single-app identity and original scope preserved' ($config.clientId -ceq $app -and $config.scope -ceq "api://$app/access_as_user")
    Check 'onboarding.json preserves existing client-config compatibility' ((Split-Path $out.onboardingJson -Leaf) -ceq 'onboarding.json' -and (Get-Content $out.onboardingJson -Raw) -ceq (Get-Content $out.clientConfig -Raw))
    $null=& node (Join-Path $root 'client\bin\validate-config.mjs') $out.onboardingJson
    Check 'export passes workstation strict client schema' ($LASTEXITCODE -eq 0)
    Check 'no policy, price, token or secret data exported' ((Get-Content $out.onboardingJson -Raw) -notmatch '"(?:familyPolicy|aggregateLimits|tokenQuota|price|secret|accessToken|classification)"')
    Check 'browserSignIn is not written by default' (-not $config.ContainsKey('browserSignIn'))
    $noBrowser=$p|ConvertTo-Json -Depth 40|ConvertFrom-Json -AsHashtable; $noBrowser.browserSignIn=$false
    $ctxNo=@{P=$noBrowser;GeneratedDir=(Join-Path $work 'nobrowser');State=$ctx.State}; New-Item -ItemType Directory $ctxNo.GeneratedDir | Out-Null
    $outNo=Invoke-QsClient $ctxNo
    $cfgNo=Get-Content $outNo.clientConfig -Raw | ConvertFrom-Json -AsHashtable
    Check 'browserSignIn false is written to the client file and passes the client schema' ($cfgNo.browserSignIn -eq $false)
    foreach($case in @('unknown-project','wrong-case','unknown-classification','unadmitted-alias','missing-deployment','missing-selection','unknown-client-field','invalid-workstation-schema')) {
        $copy=$p|ConvertTo-Json -Depth 40|ConvertFrom-Json -AsHashtable
        switch($case) {
            'unknown-project' {$copy.client.projectId='absent'}
            'wrong-case' {$copy.client.projectId='project2'}
            'unknown-classification' {$copy.client.classification='CYB'}
            'unadmitted-alias' {$copy.client.models.opus='unadmitted-deployment'}
            'missing-deployment' {$copy.backends[1].deploymentInferenceGeo.Remove('chosen-opus')}
            'missing-selection' {$copy.Remove('client')}
            'unknown-client-field' {$copy.client.secret='not-a-secret'}
            'invalid-workstation-schema' {$copy.tenantId='not-a-guid'}
        }
        $bad=@{}+$ctx;$bad.P=$copy
        $before=Get-Content $out.clientConfig -Raw
        $refused=try {$null=Invoke-QsClient $bad;$false}catch{$true}
        Check "$case refuses without overwriting exports" ($refused -and (Get-Content $out.clientConfig -Raw) -ceq $before)
    }
    Check 'invalid schema candidate is cleaned up' (-not (Test-Path (Join-Path $work '.env.client-config.pending.json')))
    $ctx.State.completed['1'].outputs.gatewayIdentifierUri='https://gateway.example.test/resource'
    $out=Invoke-QsClient $ctx
    $config=Get-Content $out.onboardingJson -Raw|ConvertFrom-Json -AsHashtable
    Check 'combined custom URI exports GUID self-resource scope' ($config.scope -ceq "$app/access_as_user")
    $p.registrations.developerSignIn.appId='55555555-5555-5555-5555-555555555555'
    $out=Invoke-QsClient $ctx
    $config=Get-Content $out.onboardingJson -Raw|ConvertFrom-Json -AsHashtable
    Check 'separate-client custom URI remains unchanged' ($config.scope -ceq 'https://gateway.example.test/resource/access_as_user')
    $p.groups[1].classification='STD'
    $p.groups[1].familyPolicy.families.fable=@{models=@('explicit-test-alias');person=(Limit);group=(Limit)}
    $p.client.classification='STD'
    $refused=try {$null=Invoke-QsClient $ctx;$false}catch{$true}
    Check 'client picker cannot bypass CYB-only family validation' $refused
    Write-Host "$pass passed, 0 failed"
} finally {Remove-Item $work -Recurse -Force}
