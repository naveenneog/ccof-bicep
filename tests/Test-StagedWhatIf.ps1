#Requires -Version 7.0
# Offline tests for the what-if Modify classifier (infra/staged/Staged.WhatIf.ps1). The fixture
# tests/fixtures/cicd-drift/whatif-delta/lab-modify.json holds the Modify deltas what-if returned for the
# unchanged infsim lab (stages 2, 5, 6; IDs sanitised, workbook content shortened) and the read-backs
# Azure returned for its write-only properties. Every negative case is a genuine configuration change.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'infra\staged\Staged.WhatIf.ps1')
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
$fxPath = Join-Path $PSScriptRoot 'fixtures\cicd-drift\whatif-delta\lab-modify.json'
function Get-Fx { Get-Content $fxPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 }
$script:fx = Get-Fx
$rb = { param($k, $t) if (-not $script:fx.readBacks.Contains("$k|$t")) { throw "no read-back $k|$t" }; $script:fx.readBacks["$k|$t"] }
function Get-Change([string]$Pattern) { $c = @((Get-Fx).changes | Where-Object { $_.resourceId -match $Pattern }); if ($c.Count -ne 1) { throw "fixture: $($c.Count) changes match $Pattern" }; $c[0] }
function Get-Leaf($Change, [string]$Path) { foreach ($d in $Change.delta) { if ($d.path -ceq $Path) { return $d } }; throw "fixture: no leaf $Path" }
function Verdicts($Change, $ReadBack = $rb) { @(Get-StgModifyVerdicts $Change $ReadBack) }
function Only([object[]]$V, [string]$Verdict) { $V.Count -gt 0 -and @($V | Where-Object verdict -cne $Verdict).Count -eq 0 }
function Has([object[]]$V, [string]$Verdict, [string]$Path) { [bool]@($V | Where-Object { $_.verdict -ceq $Verdict -and $_.path -ceq $Path }).Count }
function Reset-ReadBacks { $script:fx = Get-Fx }

$pe = '/privateEndpoints/[^/]+$'; $dns = '/privateDnsZoneGroups/'; $ctr = '/containers/projects$'; $db = '/sqlDatabases/ccof$'
$api = '/apis/claude-messages$'; $pol = '/apis/claude-messages/policies/policy$'; $frag = '/policyFragments/claude-messages-backend$'
$sync = '-sync/config/appsettings$'; $admin = '-admin/config/appsettings$'; $wb = '/workbooks/'

# The unchanged lab: nothing is drift. The only unmeasured leaf is the admin app settings: the live app has
# ADMIN_READER_IDS/ADMIN_EDITOR_IDS = '' and what-if omits empty template values, so their presence in the
# template cannot be proved from what-if.
$all = @((Get-Fx).changes | ForEach-Object { Verdicts $_ })
$um = @($all | Where-Object verdict -ceq 'unmeasured')
Check 'lab: 11 Modify changes, no drift, only the admin empty settings unmeasured' (@((Get-Fx).changes).Count -eq 11 -and -not @($all | Where-Object verdict -ceq 'drift').Count -and $um.Count -eq 1 -and $um[0].detail -match 'ADMIN_EDITOR_IDS, ADMIN_READER_IDS')
Check 'lab: container defaults are 4 noise' ((Verdicts (Get-Change $ctr)).Count -eq 4 -and (Only (Verdicts (Get-Change $ctr)) 'noise'))
Check 'lab: API defaults are 2 noise' ((Verdicts (Get-Change $api)).Count -eq 2 -and (Only (Verdicts (Get-Change $api)) 'noise'))
Check 'lab: policy and fragment re-serialisation is noise' ((Only (Verdicts (Get-Change $pol)) 'noise') -and (Only (Verdicts (Get-Change $frag)) 'noise'))
Check 'lab: DNS zone group read-only fields are 4 noise' ((Verdicts (Get-Change $dns)).Count -eq 4 -and (Only (Verdicts (Get-Change $dns)) 'noise'))
Check 'lab: PE IPv6 default is noise' (Only (Verdicts (Get-Change $pe)) 'noise')
foreach ($p in $db, $sync, $wb) { Check "lab: write-only read-back matched ($p)" (Only (Verdicts (Get-Change $p)) 'matched') }
Check 'lab: verdicts carry no values' (-not @($all | Where-Object { $_.PSObject.Properties.Name -cin 'before', 'after', 'value' }).Count)
foreach ($p in $db, $sync, $wb) { Check "no read-back: write-only is unmeasured ($p)" (Only (Verdicts (Get-Change $p) $null) 'unmeasured') }

# Genuine changes on paths that have a noise rule are drift.
$c = Get-Change $ctr; (Get-Leaf $c 'properties.resource.indexingPolicy.automatic').before = $false
Check 'neg: indexing automatic=false is drift' (Has (Verdicts $c) 'drift' 'properties.resource.indexingPolicy.automatic')
$c = Get-Change $ctr; (Get-Leaf $c 'properties.resource.indexingPolicy.includedPaths').before = @(@{ path = '/tenant/?' })
Check 'neg: custom includedPaths is drift' (Has (Verdicts $c) 'drift' 'properties.resource.indexingPolicy.includedPaths')
$c = Get-Change $pe; $c.delta[0].before = $true
Check 'neg: IPv6 enabled is drift' (Only (Verdicts $c) 'drift')
$c = Get-Change $pe; $c.delta[0].after = $false
Check 'neg: noise path with a non-null template value is drift' (Only (Verdicts $c) 'drift')
$c = Get-Change $pe; $c.delta[0].propertyChangeType = 'Modify'
Check 'neg: noise path with another change type is drift' (Only (Verdicts $c) 'drift')
$c = Get-Change $api; (Get-Leaf $c 'properties.subscriptionKeyParameterNames.header').before = 'X-Key'
Check 'neg: custom subscription key header is drift' (@(Verdicts $c | Where-Object verdict -eq 'drift').Count -eq 1)
$c = Get-Change $pe; $c.delta += @{ path = 'properties.customNetworkInterfaceName'; propertyChangeType = 'Modify'; before = 'nic-a'; after = 'nic-b' }
Check 'neg: unknown leaf path is drift' (Has (Verdicts $c) 'drift' 'properties.customNetworkInterfaceName')
$c = Get-Change $pe; $c.delta = @()
Check 'neg: Modify without a delta is drift' (Only (Verdicts $c) 'drift')
$c = Get-Change $dns; $c.delta[0].children[0].children += @{ path = 'properties.privateDnsZoneId'; propertyChangeType = 'Delete'; before = '/x'; after = $null }
Check 'neg: DNS zone group zone ID removal is drift (outside read-only fields)' (Has (Verdicts $c) 'drift' 'properties.privateDnsZoneConfigs.0.properties.privateDnsZoneId')

# APIM policies: a real edit is drift; format other than xml->rawxml is drift.
$c = Get-Change $pol; $v = Get-Leaf $c 'properties.value'; $v.before = $v.before -replace 'buffer-response="false"', 'buffer-response="true"'
if ($v.before -notmatch 'buffer-response="true"') { $v.before = $v.before -replace '</policies>', '<!-- manual --></policies>' }
Check 'neg: edited policy text is drift' (Has (Verdicts $c) 'drift' 'properties.value')
$c = Get-Change $pol; (Get-Leaf $c 'properties.format').before = 'xml-link'
Check 'neg: policy format xml-link is drift' (Has (Verdicts $c) 'drift' 'properties.format')
$c = Get-Change $pol; (Get-Leaf $c 'properties.value').after = "[parameters('policy')]"
Check 'unmeasured: unresolved policy expression' (Has (Verdicts $c) 'unmeasured' 'properties.value')

# Policy semantics: whitespace or entity changes inside text, attribute values, expressions and string
# literals are never noise. $stored is APIM's xml form; $sent is the template (rawxml unless -Format).
function PolicyVerdict([string]$Stored, [string]$Sent, [string]$Format = 'rawxml') {
    $ch = @{ resourceId = '/subscriptions/s/resourceGroups/g/providers/Microsoft.ApiManagement/service/a/apis/b/policies/policy'; changeType = 'Modify'; delta = @(
        @{ path = 'properties.value'; propertyChangeType = 'Modify'; before = $Stored; after = $Sent }) }
    if ($Format -ne 'xml') { $ch.delta += @{ path = 'properties.format'; propertyChangeType = 'Modify'; before = 'xml'; after = $Format } }
    @(Get-StgModifyVerdicts $ch $rb | Where-Object path -ceq 'properties.value')[0].verdict
}
$hdr = '<policies><inbound><set-header name="Authorization" exists-action="override"><value>{0}</value></set-header></inbound></policies>'
Check 'policy: identical header value is noise' ((PolicyVerdict ($hdr -f 'Bearer A') ($hdr -f 'Bearer A')) -ceq 'noise')
Check 'policy neg: <value> Bearer A -> Bearer  A is drift' ((PolicyVerdict ($hdr -f 'Bearer A') ($hdr -f 'Bearer  A')) -ceq 'drift')
Check 'policy neg: trailing space in <value> is drift' ((PolicyVerdict ($hdr -f 'Bearer A') ($hdr -f 'Bearer A ')) -ceq 'drift')
Check 'policy neg: whitespace-only <value> vs empty is drift' ((PolicyVerdict ($hdr -f ' ') ($hdr -f '')) -ceq 'drift')
Check 'policy neg: newline added inside <value> text is drift' ((PolicyVerdict ($hdr -f 'Bearer A') ($hdr -f "Bearer`nA")) -ceq 'drift')
Check 'policy neg: string literal in expression "Bearer " -> "Bearer  " is drift' ((PolicyVerdict ($hdr -f '@(&quot;Bearer &quot; + context.Variables[&quot;t&quot;])') ($hdr -f '@("Bearer  " + context.Variables["t"])')) -ceq 'drift')
Check 'policy: same expression with entities vs rawxml is noise' ((PolicyVerdict ($hdr -f '@(&quot;Bearer &quot; + context.Variables[&quot;t&quot;])') ($hdr -f '@("Bearer " + context.Variables["t"])')) -ceq 'noise')
$cond = '<policies><inbound><choose><when condition="{0}"><base /></when></choose></inbound></policies>'
Check 'policy neg: space added in attribute expression is drift' ((PolicyVerdict ($cond -f '@(context.Request.Headers.GetValueOrDefault(&quot;x&quot;, &quot;&quot;) == &quot;a b&quot;)') ($cond -f '@(context.Request.Headers.GetValueOrDefault("x", "") == "a  b")')) -ceq 'drift')
Check 'policy neg: whitespace outside literals in attribute expression is drift' ((PolicyVerdict ($cond -f '@(1 &lt; 2)') ($cond -f '@(1  < 2)')) -ceq 'drift')
Check 'policy: escaped attribute expression vs rawxml is noise' ((PolicyVerdict ($cond -f '@(1 &lt; 2 &amp;&amp; true)') ($cond -f '@(1 < 2 && true)')) -ceq 'noise')
Check 'policy: &#xA; in stored attribute equals newline in rawxml' ((PolicyVerdict ($cond -f '@(1 &lt; 2&#xA;)') ($cond -f "@(1 < 2`n)")) -ceq 'noise')
$attr = '<policies><inbound><rate-limit-by-key calls="10" renewal-period="60" counter-key="{0}" /></inbound></policies>'
Check 'policy neg: space added in a plain attribute value is drift' ((PolicyVerdict ($attr -f 'ip') ($attr -f 'ip ')) -ceq 'drift')
Check 'policy neg: attribute value changed is drift' ((PolicyVerdict ($attr -f 'ip') ($attr -f 'IP')) -ceq 'drift')
Check 'policy: attribute order and tag whitespace are noise' ((PolicyVerdict "<policies>`r`n`t<inbound>`r`n`t`t<rate-limit-by-key renewal-period=`"60`" calls=`"10`" counter-key=`"ip`"/>`r`n`t</inbound>`r`n</policies>" ($attr -f 'ip')) -ceq 'noise')
Check 'policy neg: added attribute is drift' ((PolicyVerdict ($attr -f 'ip') ($attr.Replace('calls="10"', 'calls="10" retry-after-header-name="x"') -f 'ip')) -ceq 'drift')
Check 'policy neg: whitespace after CDATA is content (drift)' ((PolicyVerdict '<policies><set-body><![CDATA[abc]]>  </set-body></policies>' '<policies><set-body><![CDATA[abc]]></set-body></policies>' 'xml') -ceq 'drift')
Check 'policy neg: whitespace after text and a comment is content (drift)' ((PolicyVerdict '<policies><set-body>abc<!--x-->  </set-body></policies>' '<policies><set-body>abc<!--x--></set-body></policies>' 'xml') -ceq 'drift')
Check 'policy: CDATA equals the same escaped text' ((PolicyVerdict '<policies><set-body>a&lt;b</set-body></policies>' '<policies><set-body><![CDATA[a<b]]></set-body></policies>' 'xml') -ceq 'noise')
Check 'policy neg: whitespace beside a comment as sole content is drift' ((PolicyVerdict '<policies><set-body><!-- c --></set-body></policies>' '<policies><set-body><!-- c -->  </set-body></policies>') -ceq 'drift')
Check 'policy neg: indented comment as sole content is drift' ((PolicyVerdict '<policies><set-body><!-- c --></set-body></policies>' "<policies><set-body>`n  <!-- c -->`n</set-body></policies>") -ceq 'drift')
Check 'unmeasured: literal newline in a plain rawxml attribute' ((PolicyVerdict '<policies><set-header name="a&#10;b" /></policies>' "<policies><set-header name=`"a`nb`" /></policies>") -ceq 'unmeasured')
Check 'unmeasured: literal tab in a plain rawxml attribute' ((PolicyVerdict '<policies><set-header name="a&#9;b" /></policies>' "<policies><set-header name=`"a`tb`" /></policies>") -ceq 'unmeasured')
Check 'policy neg: &#0; cannot fake extra attributes' ((PolicyVerdict '<policies><p a="x&#0;b&#0;y"/></policies>' '<policies><p a="x" b="y"/></policies>') -cne 'noise')
Check 'policy neg: mid-text @( does not swallow tags' ((PolicyVerdict '<policies><value>x@(&lt;/value&gt;&lt;value&gt;)</value></policies>' '<policies><value>x@(</value><value>)</value></policies>') -cne 'noise')
Check 'policy neg: upper-case entity in an xml template is not decoded as its lower-case form' ((PolicyVerdict ($hdr -f 'a &amp;LT; b') ($hdr -f 'a &LT; b') 'xml') -cne 'noise')
Check 'policy: expression after leading whitespace in text is still scanned' ((PolicyVerdict ($hdr -f "`n  @(1 &lt; 2)`n") ($hdr -f "`n  @(1 < 2)`n")) -ceq 'noise')
Check 'policy neg: whitespace between child elements of set-body (mixed content) is not noise' ((PolicyVerdict '<policies><inbound><set-body><a/> <b/></set-body></inbound></policies>' '<policies><inbound><set-body><a/><b/></set-body></inbound></policies>') -cne 'noise')
Check 'policy neg (reported probe, xml format): <a/> <b/> vs <a/><b/> in set-body is not noise' ((PolicyVerdict '<policies><inbound><set-body><a/> <b/></set-body></inbound></policies>' '<policies><inbound><set-body><a/><b/></set-body></inbound></policies>' 'xml') -cne 'noise')
Check 'policy neg: structural name (trace) nested in set-body payload keeps whitespace' ((PolicyVerdict '<policies><inbound><set-body><Envelope><trace><a/> <b/></trace></Envelope></set-body></inbound></policies>' '<policies><inbound><set-body><Envelope><trace><a/><b/></trace></Envelope></set-body></inbound></policies>') -cne 'noise')
Check 'policy neg: structural name (backend) directly in liquid set-body keeps whitespace' ((PolicyVerdict '<policies><inbound><set-body template="liquid"><backend>  <x/></backend></set-body></inbound></policies>' '<policies><inbound><set-body template="liquid"><backend><x/></backend></set-body></inbound></policies>') -cne 'noise')
Check 'policy neg: structural name (when) in set-body, xml form, keeps whitespace' ((PolicyVerdict '<policies><inbound><set-body><when><a/>  </when></set-body></inbound></policies>' '<policies><inbound><set-body><when><a/></when></set-body></inbound></policies>' 'xml') -cne 'noise')
Check 'unmeasured: mismatched end tag' ((PolicyVerdict '<policies><inbound></outbound></policies>' '<policies><inbound></outbound></policies>') -ceq 'unmeasured')
Check 'policy neg: indentation between nested elements inside set-body is not noise' ((PolicyVerdict "<policies><inbound><set-body><a>`n  <b/>`n</a></set-body></inbound></policies>" '<policies><inbound><set-body><a><b/></a></set-body></inbound></policies>') -cne 'noise')
Check 'policy neg: whitespace between children of an unlisted element is not noise' ((PolicyVerdict '<policies><inbound><custom-x><a/> <b/></custom-x></inbound></policies>' '<policies><inbound><custom-x><a/><b/></custom-x></inbound></policies>') -cne 'noise')
Check 'policy neg: whitespace between <value> children of set-body-like text parent is not noise' ((PolicyVerdict '<policies><inbound><set-header name="h"><value><x/> <y/></value></set-header></inbound></policies>' '<policies><inbound><set-header name="h"><value><x/><y/></value></set-header></inbound></policies>') -cne 'noise')
Check 'policy: indentation inside choose/when/otherwise/set-header is noise' ((PolicyVerdict "<policies>`n <inbound>`n  <choose>`n   <when condition=`"@(true)`">`n    <set-header name=`"h`">`n     <value>v</value>`n    </set-header>`n   </when>`n   <otherwise>`n    <base />`n   </otherwise>`n  </choose>`n </inbound>`n</policies>" '<policies><inbound><choose><when condition="@(true)"><set-header name="h"><value>v</value></set-header></when><otherwise><base /></otherwise></choose></inbound></policies>') -ceq 'noise')
Check 'policy: text split by CDATA equals the same text' ((PolicyVerdict '<policies><set-body>ab</set-body></policies>' '<policies><set-body>a<![CDATA[b]]></set-body></policies>' 'xml') -ceq 'noise')
Check 'policy: indentation around a comment between tags is noise' ((PolicyVerdict "<policies>`r`n`t<!-- c -->`r`n`t<inbound />`r`n</policies>" "<policies>`n    <!-- c -->`n    <inbound />`n</policies>") -ceq 'noise')
Check 'policy neg: comment text change is drift' ((PolicyVerdict '<policies><!-- a --><inbound /></policies>' '<policies><!--  a --><inbound /></policies>') -ceq 'drift')
Check 'unmeasured: interpolated C# string' ((PolicyVerdict ($hdr -f '@($&quot;Bearer {x}&quot;)') ($hdr -f '@($"Bearer {x}")')) -ceq 'unmeasured')
Check 'unmeasured: entity inside rawxml is ambiguous' ((PolicyVerdict ($hdr -f 'a &amp; b') ($hdr -f 'a &amp; b')) -ceq 'unmeasured')
Check 'unmeasured: unbalanced rawxml expression' ((PolicyVerdict ($cond -f '@(1)') ($cond -f '@((1)')) -ceq 'unmeasured')
Check 'unmeasured: literal newline in a stored (escaped) attribute' ((PolicyVerdict ($cond -f "@(1`n)") ($cond -f "@(1`n)")) -ceq 'unmeasured')
Check 'unmeasured: unknown template format' ((PolicyVerdict ($hdr -f 'A') ($hdr -f 'A') 'xml-link') -ceq 'unmeasured')
Check 'policy: xml template (no format change) compared escaped' ((PolicyVerdict ($hdr -f 'a &amp; b') ($hdr -f 'a &amp; b') 'xml') -ceq 'noise')
Check 'policy neg: xml template entity change that alters text is drift' ((PolicyVerdict ($hdr -f 'a &amp; b') ($hdr -f 'a &amp;amp; b') 'xml') -ceq 'drift')
$c = Get-Change $frag; $v = Get-Leaf $c 'properties.value'; $v.before = $v.before.Replace('&quot;ccofStream&quot;, false', '&quot;ccofStream&quot;,  false')
Check 'policy neg (real fragment): double space inside stored expression is drift' (Has (Verdicts $c) 'drift' 'properties.value')
$c = Get-Change $frag; $v = Get-Leaf $c 'properties.value'; $v.after = $v.after.Replace('buffer-response="false"', 'buffer-response="false "')
Check 'policy neg (real fragment): space inside template attribute is drift' (Has (Verdicts $c) 'drift' 'properties.value')

# Write-only read-backs.
$c = Get-Change $sync; $key = @($script:fx.readBacks.Keys | Where-Object { $_ -match "^appsettings\|.*-sync/config/appsettings$" })[0]
$secretish = 'changed-value-7f3a'; $name = @($script:fx.readBacks[$key].Keys | Where-Object { $script:fx.readBacks[$key][$_] -notmatch '^\[' })[0]
$script:fx.readBacks[$key][$name] = $secretish; $v = Verdicts $c
Check 'neg: changed app setting is drift with its name, never its value' ((Only $v 'drift') -and $v[0].detail -match [regex]::Escape($name) -and ($v | ConvertTo-Json -Depth 5) -notmatch $secretish); Reset-ReadBacks
$script:fx.readBacks[$key]['MANUAL_SETTING'] = 'x'
Check 'neg: extra non-empty setting is drift' ((Only (Verdicts (Get-Change $sync)) 'drift')); Reset-ReadBacks
$script:fx.readBacks[$key]['EMPTY_SETTING'] = ''
$v = Verdicts (Get-Change $sync)
Check 'neg: extra empty live setting not in the what-if payload is unmeasured (deployment may remove it), named' ((Only $v 'unmeasured') -and $v[0].detail -match 'EMPTY_SETTING'); Reset-ReadBacks
$script:fx.readBacks[$key].Remove($name)
Check 'neg: missing setting is drift' (Only (Verdicts (Get-Change $sync)) 'drift'); Reset-ReadBacks
foreach ($k in @($script:fx.readBacks.Keys | Where-Object { $_ -like 'reference|*' })) { $script:fx.readBacks.Remove($k) }
Check 'unmeasured: reference read-back fails' (Only (Verdicts (Get-Change $sync)) 'unmeasured'); Reset-ReadBacks
$rkey = @($script:fx.readBacks.Keys | Where-Object { $_ -like 'reference|*-sync-ai|*' })[0]
$script:fx.readBacks[$rkey] = @{ OtherProperty = 'x' }
Check 'unmeasured: reference read-back lacks the property' (Only (Verdicts (Get-Change $sync)) 'unmeasured'); Reset-ReadBacks
$script:fx.readBacks[$rkey]['ConnectionString'] = 'InstrumentationKey=changed'
Check 'neg: resolved reference with a different value is drift' (Only (Verdicts (Get-Change $sync)) 'drift'); Reset-ReadBacks
Check 'unmeasured: read-back returns nothing' (Only (Verdicts (Get-Change $admin) { param($k, $t) $null }) 'unmeasured')
Check 'unmeasured: unknown read-back kind' ((Compare-StgWriteOnly -Kind 'other' -ResourceId '/x' -Leaf ([pscustomobject]@{ Path = 'p'; Change = 'Create'; After = 'a' }) -ReadBack $rb -Row { param($a, $b, $c) [pscustomobject]@{ verdict = $a } }).verdict -ceq 'unmeasured')
$c = Get-Change $db; (Get-Leaf $c 'properties.options').after = @{ autoscaleSettings = @{ maxThroughput = "[parameters('max')]" } }
Check 'unmeasured: unresolved throughput expression' (Only (Verdicts $c) 'unmeasured')
$c = Get-Change $sync; $p = Get-Leaf $c 'properties'; $p.after['CONCAT_SETTING'] = "[concat('a', 'b')]"
Check 'unmeasured: unsupported template expression' (Only (Verdicts $c) 'unmeasured')
$deny = { param($k, $t) throw '(AuthorizationFailed) The client does not have authorization to perform action list' }
Check 'unmeasured: read-back AuthorizationFailed (Reader identity)' ((Only (Verdicts (Get-Change $admin) $deny) 'unmeasured') -and (Verdicts (Get-Change $admin) $deny)[0].detail -match 'AuthorizationFailed')
$tkey = @($script:fx.readBacks.Keys | Where-Object { $_ -like 'throughput|*' })[0]
$script:fx.readBacks[$tkey].autoscaleSettings.maxThroughput = 2000
Check 'neg: autoscale maximum 2000 is drift' (Only (Verdicts (Get-Change $db)) 'drift'); Reset-ReadBacks
$script:fx.readBacks[$tkey] = @{ throughput = 400 }
Check 'neg: manual throughput instead of autoscale is drift' (Only (Verdicts (Get-Change $db)) 'drift'); Reset-ReadBacks
$wkey = @($script:fx.readBacks.Keys | Where-Object { $_ -like 'workbook|*' })[0]
$script:fx.readBacks[$wkey] = $script:fx.readBacks[$wkey] -replace '"version"', '"versionX"'
Check 'neg: changed workbook content is drift' (Only (Verdicts (Get-Change $wb)) 'drift'); Reset-ReadBacks
$script:fx.readBacks[$wkey] = $script:fx.readBacks[$wkey] -replace '[^\x00-\x7F]', ''
Check 'unmeasured: workbook differs only in non-ASCII (Windows az output)' (Only (Verdicts (Get-Change $wb)) 'unmeasured'); Reset-ReadBacks

# Canonical JSON.
Check 'canonical: key order does not matter' ((ConvertTo-StgCanonicalJson ('{"b":1,"a":[{"y":2,"x":1}]}' | ConvertFrom-Json)) -ceq (ConvertTo-StgCanonicalJson ('{"a":[{"x":1,"y":2}],"b":1}' | ConvertFrom-Json -AsHashtable)))
Check 'canonical: PSObject-wrapped string is a string' ((ConvertTo-StgCanonicalJson ([psobject]'/_ts')) -ceq '"/_ts"')
Check 'canonical: values differ' ((ConvertTo-StgCanonicalJson @{ a = 1 }) -cne (ConvertTo-StgCanonicalJson @{ a = 2 }))
Check 'type: nested resource type' ((Get-StgResourceType '/subscriptions/s/resourceGroups/g/providers/Microsoft.Web/sites/a/config/appsettings') -ceq 'Microsoft.Web/sites/config')

Write-Host "Test-StagedWhatIf: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0 -or $script:pass -lt 93) { exit 1 }
