# Property-level classification of what-if Modify changes for the CI/CD drift check
# (docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md, "Drift check").
# An unchanged deployment still shows Modify in what-if: properties the template omits that Azure
# returns with their default value, read-only fields, APIM policy XML that APIM stores re-serialised,
# and write-only properties that a GET does not return. Each leaf gets one verdict, never a value:
#   noise       a narrow rule below matched the exact path and the exact default/read-only value
#   matched     a read-only read-back of a write-only property equals the template value
#   drift       anything else: an unknown path, a different value, a read-back that differs
#   unmeasured  the value cannot be compared (unresolved expression, read-back failed or not allowed)
# Rules match values, not only paths: a manual change to an indexing policy, an IPv6 flag or a
# policy body is still drift.

$script:StgApimPolicyType = '^Microsoft\.ApiManagement/service(/apis(/operations)?|/products)?/policies$|^Microsoft\.ApiManagement/service/policyFragments$'
$script:StgReferencePattern = "^\[reference\('(/subscriptions/[^']+)',\s*'([0-9]{4}-[0-9]{2}-[0-9]{2}(-preview)?)'\)\.([A-Za-z0-9_]+)\]$"

# Canonical JSON: object keys sorted, so two parses of the same document compare equal.
function ConvertTo-StgCanonicalJson { param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [psobject] -and $Value.PSObject.BaseObject -isnot [Management.Automation.PSCustomObject]) { $Value = $Value.PSObject.BaseObject }
    if ($Value -is [string]) { return ConvertTo-Json -InputObject $Value -Compress }
    if ($Value -is [Collections.IDictionary]) {
        $parts = foreach ($k in @($Value.Keys | Sort-Object -CaseSensitive)) { (ConvertTo-Json -InputObject ([string]$k) -Compress) + ':' + (ConvertTo-StgCanonicalJson $Value[$k]) }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}; foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return ConvertTo-StgCanonicalJson $h
    }
    if ($Value -is [Collections.IEnumerable]) { return '[' + (@(foreach ($x in $Value) { ConvertTo-StgCanonicalJson $x }) -join ',') + ']' }
    return ConvertTo-Json -InputObject $Value -Compress
}

function Get-StgResourceType { param([string]$ResourceId)
    $i = $ResourceId.LastIndexOf('/providers/', [StringComparison]::OrdinalIgnoreCase)
    if ($i -lt 0) { return '' }
    $seg = $ResourceId.Substring($i + 11).Split('/')
    $types = for ($j = 1; $j -lt $seg.Count; $j += 2) { $seg[$j] }
    return (@($seg[0]) + @($types)) -join '/'
}

# Flattens a what-if delta into leaves (path joined with '.', array children by index).
function Get-StgDeltaLeaves { param($Delta, [string]$Prefix = '')
    foreach ($d in @($Delta)) {
        if ($null -eq $d) { continue }
        $path = if ($Prefix) { "$Prefix.$($d['path'])" } else { [string]$d['path'] }
        $children = @($d['children'] | Where-Object { $null -ne $_ })
        if ($children.Count) { Get-StgDeltaLeaves $children $path; continue }
        [pscustomobject]@{ Path = $path; Change = [string]$d['propertyChangeType']; Before = $d['before']; After = $d['after'] }
    }
}

# APIM policy XML compared as tokens, never by collapsing or globally decoding text.
# -Raw is the template (format rawxml): policy expressions @(...) / @{...} are C# and are not XML-escaped,
# so they are scanned with balanced delimiters and C# string/char/comment rules; nothing is entity-decoded.
# Without -Raw (format xml, as APIM returns it) the five predefined entities and numeric references are
# decoded in text and attribute values. Both: CRLF/CR -> LF (XML 1.0 section 2.11), attributes compared
# by name, <x/> equals <x></x>, and whitespace-only text between two tags dropped unless it is an element's
# only content. Text, attribute values, expressions, comments and CDATA are otherwise compared exactly, so
# "Bearer A" -> "Bearer  A" is a difference. $null when the text cannot be tokenised with certainty
# (interpolated C# strings, an entity in rawxml, a literal newline in an escaped attribute, unbalanced input).
function Get-StgPolicyExpressionEnd { param([string]$S, [int]$I)
    # $S[$I] is '@' and $S[$I+1] is '(' or '{'. Returns the index after the closing delimiter, or -1.
    $stack = [Collections.Generic.Stack[char]]::new(); $j = $I + 1; $n = $S.Length
    while ($j -lt $n) {
        $c = $S[$j]
        if ($c -eq '$' -and $j + 1 -lt $n -and ($S[$j + 1] -eq '"' -or $S[$j + 1] -eq '@')) { return -1 }
        if ($c -eq '"') {
            $verbatim = $j -gt $I + 1 -and $S[$j - 1] -eq '@'
            $j++
            while ($j -lt $n) {
                if (-not $verbatim -and $S[$j] -eq '\') { $j += 2; continue }
                if ($S[$j] -eq '"') { if ($verbatim -and $j + 1 -lt $n -and $S[$j + 1] -eq '"') { $j += 2; continue }; break }
                if (-not $verbatim -and $S[$j] -eq "`n") { return -1 }
                $j++
            }
            if ($j -ge $n) { return -1 }; $j++; continue
        }
        if ($c -eq "'") {
            $j++; while ($j -lt $n -and $S[$j] -ne "'") { if ($S[$j] -eq '\') { $j++ }; if ($j -lt $n -and $S[$j] -eq "`n") { return -1 }; $j++ }
            if ($j -ge $n) { return -1 }; $j++; continue
        }
        if ($c -eq '/' -and $j + 1 -lt $n -and $S[$j + 1] -eq '/') { $k = $S.IndexOf("`n", $j); if ($k -lt 0) { return -1 }; $j = $k; continue }
        if ($c -eq '/' -and $j + 1 -lt $n -and $S[$j + 1] -eq '*') { $k = $S.IndexOf('*/', $j + 2); if ($k -lt 0) { return -1 }; $j = $k + 2; continue }
        if ($c -eq '(' -or $c -eq '{' -or $c -eq '[') { $stack.Push($c) }
        elseif ($c -eq ')' -or $c -eq '}' -or $c -eq ']') {
            if (-not $stack.Count) { return -1 }
            $o = $stack.Pop(); if (($o -eq '(' -and $c -ne ')') -or ($o -eq '{' -and $c -ne '}') -or ($o -eq '[' -and $c -ne ']')) { return -1 }
            if (-not $stack.Count) { return $j + 1 }
        }
        $j++
    }
    return -1
}

function ConvertTo-StgPolicyTokens { param([string]$Text, [switch]$Raw)
    $s = $Text.Replace("`r`n", "`n").Replace("`r", "`n"); $n = $s.Length; $i = 0
    if ($s -match '[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]') { return $null }
    $fail = $false
    $decode = { param([string]$v)
        if ($Raw) { if ($v -match '&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);') { $script:StgPolicyFail = $true }; return $v }
        if ($v -cmatch '&(?!(#x[0-9A-Fa-f]+|#[0-9]+|lt|gt|amp|quot|apos);)') { $script:StgPolicyFail = $true; return $v }
        $d = [regex]::Replace($v, '&(#x[0-9A-Fa-f]+|#[0-9]+|lt|gt|amp|quot|apos);', {
            param($m)
            switch -CaseSensitive ($m.Groups[1].Value) { 'lt' { '<' } 'gt' { '>' } 'amp' { '&' } 'quot' { '"' } 'apos' { "'" }
                default { $g = $m.Groups[1].Value; [char]::ConvertFromUtf32($(if ($g.StartsWith('#x')) { [Convert]::ToInt32($g.Substring(2), 16) } else { [int]$g.Substring(1) })) } }
        }, [Text.RegularExpressions.RegexOptions]::None)
        # A character XML 1.0 does not allow (U+0000 would also collide with the token separator).
        if ($d -match '[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]') { $script:StgPolicyFail = $true }
        return $d
    }
    $script:StgPolicyFail = $false
    $name = '[A-Za-z_][\w.\-:]*'
    $tokens = [Collections.Generic.List[string]]::new()
    while ($i -lt $n) {
        if ($s[$i] -ne '<') {
            $sb = [Text.StringBuilder]::new()
            while ($i -lt $n -and $s[$i] -ne '<') {
                # An expression only where it starts the text (after whitespace); elsewhere '@(' is plain text.
                if ($Raw -and $s[$i] -eq '@' -and $i + 1 -lt $n -and ($s[$i + 1] -eq '(' -or $s[$i + 1] -eq '{') -and $sb.ToString().Trim(" `t`n").Length -eq 0) {
                    $e = Get-StgPolicyExpressionEnd $s $i; if ($e -lt 0) { return $null }
                    $null = $sb.Append($s.Substring($i, $e - $i)); $i = $e; continue
                }
                $null = $sb.Append($s[$i]); $i++
            }
            $tokens.Add('T' + (& $decode $sb.ToString())); continue
        }
        $rest = $s.Substring($i)
        if ($rest.StartsWith('<!--')) { $j = $s.IndexOf('-->', $i + 4); if ($j -lt 0) { return $null }; $tokens.Add('C' + $s.Substring($i + 4, $j - $i - 4)); $i = $j + 3; continue }
        if ($rest.StartsWith('<![CDATA[')) { $j = $s.IndexOf(']]>', $i + 9); if ($j -lt 0) { return $null }; $tokens.Add('T' + $s.Substring($i + 9, $j - $i - 9)); $i = $j + 3; continue }
        $m = [regex]::Match($rest, "^</($name)\s*>")
        if ($m.Success) { $tokens.Add('E' + $m.Groups[1].Value); $i += $m.Length; continue }
        $m = [regex]::Match($rest, "^<($name)"); if (-not $m.Success) { return $null }
        $tag = $m.Groups[1].Value; $i += $m.Length
        $attrs = [Collections.Generic.SortedDictionary[string, string]]::new([StringComparer]::Ordinal); $close = $null
        while ($true) {
            $m = [regex]::Match($s.Substring($i), '^\s*(/?>)'); if ($m.Success) { $close = $m.Groups[1].Value; $i += $m.Length; break }
            $m = [regex]::Match($s.Substring($i), "^\s+($name)\s*=\s*([""'])"); if (-not $m.Success) { return $null }
            $an = $m.Groups[1].Value; $q = $m.Groups[2].Value[0]; $i += $m.Length
            if ($Raw -and $i + 1 -lt $n -and $s[$i] -eq '@' -and ($s[$i + 1] -eq '(' -or $s[$i + 1] -eq '{')) {
                $e = Get-StgPolicyExpressionEnd $s $i; if ($e -lt 0 -or $e -ge $n -or $s[$e] -ne $q) { return $null }
            } else { $e = $s.IndexOf($q, $i); if ($e -lt 0) { return $null } }
            $val = $s.Substring($i, $e - $i); $i = $e + 1
            # A literal newline or tab in an attribute is normalised to a space by an XML parser; uncertain unless
            # it is inside a rawxml policy expression (APIM keeps those and stores them as &#xA;).
            if ($val -match "[`n`t]" -and -not ($Raw -and $val -match '^@[({]')) { return $null }
            if ($attrs.ContainsKey($an)) { return $null }
            $attrs[$an] = & $decode $val
        }
        $tokens.Add('S' + $tag + (@($attrs.GetEnumerator() | ForEach-Object { "`0" + $_.Key + "`0" + $_.Value }) -join ''))
        if ($close -eq '/>') { $tokens.Add('E' + $tag) }
    }
    if ($script:StgPolicyFail) { return $null }
    # Adjacent text and CDATA are one run of character data.
    $merged = [Collections.Generic.List[string]]::new()
    foreach ($t in $tokens) { if ($t[0] -eq 'T' -and $merged.Count -and $merged[$merged.Count - 1][0] -eq 'T') { $merged[$merged.Count - 1] += $t.Substring(1) } else { $merged.Add($t) } }
    # Whitespace-only text is dropped only when the nearest tokens on both sides that are neither comments nor
    # whitespace are tags, and it is
    # not an element's only content; whitespace next to character data (across a comment) is kept.
    $blank = { param($x) $x[0] -eq 'C' -or ($x[0] -eq 'T' -and $x.Substring(1).Trim(" `t`n").Length -eq 0) }
    $out = [Collections.Generic.List[string]]::new()
    for ($k = 0; $k -lt $merged.Count; $k++) {
        $t = $merged[$k]
        if ($t -ceq 'T') { continue }
        if ($t[0] -eq 'T' -and $t.Substring(1).Trim(" `t`n").Length -eq 0) {
            $p = $k - 1; while ($p -ge 0 -and (& $blank $merged[$p])) { $p-- }
            $q = $k + 1; while ($q -lt $merged.Count -and (& $blank $merged[$q])) { $q++ }
            $prev = if ($p -ge 0) { $merged[$p] } else { 'B' }; $next = if ($q -lt $merged.Count) { $merged[$q] } else { 'B' }
            $tagsAround = $prev[0] -cin 'S', 'E', 'B' -and $next[0] -cin 'S', 'E', 'B'
            # Only comments and whitespace between an element's start and end tags: the whitespace is its content.
            $sole = $prev[0] -eq 'S' -and $next[0] -eq 'E' -and $prev.Substring(1).Split([char]0)[0] -ceq $next.Substring(1)
            if ($tagsAround -and -not $sole) { continue }
        }
        $out.Add($t)
    }
    return , $out.ToArray()
}

function Test-StgUnresolved { param($Value) return ($Value -is [string] -and $Value.StartsWith('[') -and $Value.EndsWith(']') -and -not $Value.StartsWith('[[')) }

# Server defaults and read-only fields an unchanged deployment returns but the templates do not send.
$script:StgNoiseRules = @(
    @{ Name = 'cosmos-container-default'; Type = '^Microsoft\.DocumentDB/databaseAccounts/sqlDatabases/containers$'; Change = 'Delete'
       Expect = @{ 'properties.resource.conflictResolutionPolicy.conflictResolutionPath' = '"/_ts"'
                   'properties.resource.indexingPolicy.automatic' = 'true'
                   'properties.resource.indexingPolicy.excludedPaths' = '[{"path":"/\"_etag\"/?"}]'
                   'properties.resource.indexingPolicy.includedPaths' = '[{"path":"/*"}]' } }
    @{ Name = 'private-endpoint-ipv6-default'; Type = '^Microsoft\.Network/privateEndpoints$'; Change = 'Delete'
       Expect = @{ 'properties.isIPv6EnabledPrivateEndpoint' = 'false' } }
    @{ Name = 'apim-api-default'; Type = '^Microsoft\.ApiManagement/service/apis$'; Change = 'Delete'
       Expect = @{ 'properties.isAgent' = 'false'; 'properties.subscriptionKeyParameterNames.header' = '"Ocp-Apim-Subscription-Key"' } }
    @{ Name = 'dns-zone-config-read-only'; Type = '^Microsoft\.Network/privateEndpoints/privateDnsZoneGroups$'; Change = 'Delete'
       PathPattern = '^properties\.privateDnsZoneConfigs\.[0-9]+\.(etag|id|type|properties\.provisioningState)$' }
)

function Get-StgLeafVerdict {
    param([string]$ResourceId, [string]$Type, $Leaf, [scriptblock]$ReadBack, [string]$PolicyFormat = 'xml')
    $v = { param($Verdict, $Rule, $Detail = '') [pscustomobject]@{ path = $Leaf.Path; change = $Leaf.Change; verdict = $Verdict; rule = $Rule; detail = $Detail } }
    foreach ($r in $script:StgNoiseRules) {
        if ($Type -cnotmatch $r.Type -or $Leaf.Change -cne $r.Change -or $null -ne $Leaf.After) { continue }
        if ($r.PathPattern -and $Leaf.Path -cmatch $r.PathPattern) { return & $v 'noise' $r.Name }
        if ($r.Expect -and $r.Expect.ContainsKey($Leaf.Path)) {
            if ((ConvertTo-StgCanonicalJson $Leaf.Before) -ceq $r.Expect[$Leaf.Path]) { return & $v 'noise' $r.Name }
            return & $v 'drift' $r.Name 'value differs from the service default'
        }
    }
    if ($Type -cmatch $script:StgApimPolicyType) {
        if ($Leaf.Path -ceq 'properties.format' -and $Leaf.After -ceq 'rawxml' -and (($Leaf.Change -ceq 'Modify' -and $Leaf.Before -ceq 'xml') -or ($Leaf.Change -ceq 'Create' -and $null -eq $Leaf.Before))) {
            return & $v 'noise' 'apim-policy-format'
        }
        if ($Leaf.Path -ceq 'properties.value' -and $Leaf.Change -ceq 'Modify' -and $Leaf.Before -is [string] -and $Leaf.After -is [string]) {
            if (Test-StgUnresolved $Leaf.After) { return & $v 'unmeasured' 'apim-policy-xml' 'template value is an unresolved expression' }
            if ($PolicyFormat -cnotin 'xml', 'rawxml') { return & $v 'unmeasured' 'apim-policy-xml' "template format '$PolicyFormat' is not compared" }
            $stored = ConvertTo-StgPolicyTokens $Leaf.Before
            $sent = ConvertTo-StgPolicyTokens $Leaf.After -Raw:($PolicyFormat -ceq 'rawxml')
            if ($null -eq $stored -or $null -eq $sent) { return & $v 'unmeasured' 'apim-policy-xml' 'policy text could not be tokenised with certainty' }
            if ($stored.Count -eq $sent.Count -and -not @(for ($k = 0; $k -lt $sent.Count; $k++) { if ($stored[$k] -cne $sent[$k]) { $k } }).Count) { return & $v 'noise' 'apim-policy-xml' }
            return & $v 'drift' 'apim-policy-xml' 'policy differs'
        }
    }
    # Write-only properties: what-if shows Create (before null) because a GET does not return them.
    $writeOnly = if ($Type -ceq 'Microsoft.Web/sites/config' -and $ResourceId -match '/config/appsettings$' -and $Leaf.Path -ceq 'properties') { 'appsettings' }
        elseif ($Type -cmatch '^Microsoft\.DocumentDB/databaseAccounts/sqlDatabases(/containers)?$' -and $Leaf.Path -ceq 'properties.options') { 'throughput' }
        elseif ($Type -ceq 'Microsoft.Insights/workbooks' -and $Leaf.Path -ceq 'properties.serializedData') { 'workbook' }
    if ($writeOnly -and $Leaf.Change -ceq 'Create' -and $null -eq $Leaf.Before) {
        if (-not $ReadBack) { return & $v 'unmeasured' "$writeOnly-read-back" 'no read-back available' }
        try { return Compare-StgWriteOnly -Kind $writeOnly -ResourceId $ResourceId -Leaf $Leaf -ReadBack $ReadBack -Row $v }
        catch { return & $v 'unmeasured' "$writeOnly-read-back" "read-back failed: $(($_.Exception.Message -split "`n")[0])" }
    }
    return & $v 'drift' '' 'no rule explains this change'
}

function Compare-StgWriteOnly {
    param([string]$Kind, [string]$ResourceId, $Leaf, [scriptblock]$ReadBack, [scriptblock]$Row)
    $want = $Leaf.After
    switch ($Kind) {
        'appsettings' {
            if ($want -isnot [Collections.IDictionary]) { return & $Row 'unmeasured' 'appsettings-read-back' 'template value is not a settings object' }
            $actual = (& $ReadBack 'appsettings' $ResourceId)
            if ($actual -isnot [Collections.IDictionary]) { return & $Row 'unmeasured' 'appsettings-read-back' 'read-back returned no settings' }
            $differs = [Collections.Generic.List[string]]::new(); $open = [Collections.Generic.List[string]]::new()
            foreach ($k in $want.Keys) {
                $w = $want[$k]
                if (Test-StgUnresolved $w) {
                    $m = [regex]::Match($w, $script:StgReferencePattern)
                    if (-not $m.Success) { $open.Add($k); continue }
                    try { $props = & $ReadBack 'reference' "$($m.Groups[1].Value)|$($m.Groups[2].Value)" } catch { $open.Add($k); continue }
                    if ($props -isnot [Collections.IDictionary] -or -not $props.Contains($m.Groups[4].Value)) { $open.Add($k); continue }
                    $w = $props[$m.Groups[4].Value]
                }
                if (-not $actual.Contains($k) -or [string]$actual[$k] -cne [string]$w) { $differs.Add($k) }
            }
            # What-if leaves out settings whose template value is ''; any other extra setting would be removed by a deployment.
            foreach ($k in $actual.Keys) { if (-not $want.Contains($k) -and [string]$actual[$k] -cne '') { $differs.Add($k) } }
            if ($differs.Count) { return & $Row 'drift' 'appsettings-read-back' "settings differ: $(@($differs | Sort-Object) -join ', ')" }
            if ($open.Count) { return & $Row 'unmeasured' 'appsettings-read-back' "cannot resolve: $(@($open | Sort-Object) -join ', ')" }
            return & $Row 'matched' 'appsettings-read-back'
        }
        'throughput' {
            $res = & $ReadBack 'throughput' $ResourceId
            if ($want -isnot [Collections.IDictionary] -or $res -isnot [Collections.IDictionary]) { return & $Row 'unmeasured' 'throughput-read-back' 'no comparable throughput' }
            $keys = @($want.Keys)
            if ($keys.Count -eq 1 -and $keys[0] -ceq 'autoscaleSettings' -and $want.autoscaleSettings -is [Collections.IDictionary] -and @($want.autoscaleSettings.Keys).Count -eq 1 -and $want.autoscaleSettings.Contains('maxThroughput')) {
                $got = if ($res['autoscaleSettings'] -is [Collections.IDictionary]) { $res['autoscaleSettings']['maxThroughput'] }
                if ($null -ne $got -and [long]$got -eq [long]$want.autoscaleSettings.maxThroughput) { return & $Row 'matched' 'throughput-read-back' }
                return & $Row 'drift' 'throughput-read-back' 'autoscale maximum differs'
            }
            if ($keys.Count -eq 1 -and $keys[0] -ceq 'throughput') {
                if ($null -eq $res['autoscaleSettings'] -and $null -ne $res['throughput'] -and [long]$res['throughput'] -eq [long]$want.throughput) { return & $Row 'matched' 'throughput-read-back' }
                return & $Row 'drift' 'throughput-read-back' 'manual throughput differs'
            }
            return & $Row 'unmeasured' 'throughput-read-back' 'options other than throughput or autoscaleSettings.maxThroughput'
        }
        'workbook' {
            if ($want -isnot [string] -or (Test-StgUnresolved $want)) { return & $Row 'unmeasured' 'workbook-read-back' 'template content is not a literal' }
            $got = & $ReadBack 'workbook' $ResourceId
            if ($got -isnot [string] -or -not $got) { return & $Row 'unmeasured' 'workbook-read-back' 'read-back returned no content' }
            $a = ConvertTo-StgCanonicalJson ($want | ConvertFrom-Json -AsHashtable -Depth 200)
            $b = ConvertTo-StgCanonicalJson ($got | ConvertFrom-Json -AsHashtable -Depth 200)
            if ($a -ceq $b) { return & $Row 'matched' 'workbook-read-back' }
            # az on Windows drops characters its console code page cannot encode from what-if output;
            # the read-back goes through a UTF-8 file. Equal without non-ASCII characters is not proof.
            if (($a -replace '[^\x00-\x7F]', '') -ceq ($b -replace '[^\x00-\x7F]', '')) { return & $Row 'unmeasured' 'workbook-read-back' 'content differs only in non-ASCII characters (lost in az output encoding); compare on a UTF-8 runner' }
            return & $Row 'drift' 'workbook-read-back' 'workbook content differs'
        }
        default { return & $Row 'unmeasured' "$Kind-read-back" 'no comparison for this read-back' }
    }
}

# Verdicts for one what-if Modify change. A Modify with no leaves is drift (nothing explains it).
function Get-StgModifyVerdicts {
    param($Change, [scriptblock]$ReadBack)
    $id = [string]$Change['resourceId']; $type = Get-StgResourceType $id
    $leaves = @(Get-StgDeltaLeaves $Change['delta'])
    if (-not $leaves.Count) { return @([pscustomobject]@{ path = ''; change = 'Modify'; verdict = 'drift'; rule = ''; detail = 'what-if gave no property delta' }) }
    # The template's policy format: from the format leaf when what-if shows one, else unchanged (APIM returns xml).
    $fmt = @($leaves | Where-Object Path -ceq 'properties.format')
    $policyFormat = if ($fmt.Count -eq 1) { [string]$fmt[0].After } elseif ($fmt.Count) { '?' } else { 'xml' }
    return @($leaves | ForEach-Object {
        $leaf = $_
        $r = @(try { Get-StgLeafVerdict -ResourceId $id -Type $type -Leaf $leaf -ReadBack $ReadBack -PolicyFormat $policyFormat } catch { [pscustomobject]@{ path = $leaf.Path; change = $leaf.Change; verdict = 'unmeasured'; rule = ''; detail = "classifier error: $(($_.Exception.Message -split "`n")[0])" } })
        # Exactly one known verdict per leaf; anything else is unmeasured, never silently dropped.
        if ($r.Count -eq 1 -and $r[0].verdict -cin 'noise', 'matched', 'drift', 'unmeasured') { $r[0] }
        else { [pscustomobject]@{ path = $leaf.Path; change = $leaf.Change; verdict = 'unmeasured'; rule = ''; detail = 'no single verdict' } }
    })
}

# Read-only Azure reads for write-only properties (az rest; the response goes to a file as UTF-8).
# appsettings uses the list action, which a Reader identity cannot call: the result is then 'unmeasured'.
function Invoke-StgReadBack {
    param([string]$Kind, [string]$Target)
    $file = Join-Path $script:StateDir 'what-if-read-back.json'
    $req = switch ($Kind) {
        'appsettings' { @('post', "$Target/list", 'api-version=2023-12-01') }
        'throughput'  { @('get', "$Target/throughputSettings/default", 'api-version=2024-05-15') }
        'workbook'    { @('get', $Target, 'api-version=2023-06-01', 'canFetchContent=true') }
        'reference'   { $p = $Target.Split('|'); @('get', $p[0], "api-version=$($p[1])") }
        default { throw "unknown read-back $Kind" }
    }
    try {
        $null = Invoke-QsAz (@('rest', '--method', $req[0], '--url', $req[1], '--uri-parameters') + @($req[2..($req.Count - 1)]) + @('--output-file', $file))
        $body = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 200
    } finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    switch ($Kind) {
        'appsettings' { return $body['properties'] }
        'throughput'  { return $body['properties']['resource'] }
        'workbook'    { return $body['properties']['serializedData'] }
        'reference'   { return $body['properties'] }
    }
}
