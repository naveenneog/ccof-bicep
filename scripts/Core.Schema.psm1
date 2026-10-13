#Requires -Version 7.0
<#
.SYNOPSIS
    A deterministic JSON Schema (2020-12) validator for the subset of keywords that
    config/core.answers.schema.json uses. Pure PowerShell, no Azure call.

.DESCRIPTION
    Test-Json reports every evaluated branch of oneOf and if/then, which buries the real problem in
    noise for an administrator. This validator evaluates conditions silently and reports only what
    applies, with a dotted path and a reason code: missing, invalid, unexpected, forbidden, conflict.
    A missing object is expanded into every required decision inside it, so one run lists them all.
    Keywords: $ref (#/...), type, const, enum, pattern, minLength, maxLength, minimum, maximum,
    multipleOf, required, properties, additionalProperties, propertyNames, maxProperties, items,
    minItems, maxItems, uniqueItems, allOf, oneOf, not, if/then/else, boolean schemas.
#>

function ConvertFrom-CoreJsonElement {
    param([System.Text.Json.JsonElement]$Element)
    switch ($Element.ValueKind) {
        'Object' {
            $map = [ordered]@{}
            foreach ($p in $Element.EnumerateObject()) { $map[$p.Name] = ConvertFrom-CoreJsonElement $p.Value }
            return $map
        }
        'Array' {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) { $list.Add((ConvertFrom-CoreJsonElement $item)) }
            return , $list.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' { $long = 0L; if ($Element.TryGetInt64([ref]$long)) { return $long }; return $Element.GetDouble() }
        'True' { return $true }
        'False' { return $false }
        default { return $null }
    }
}

function ConvertFrom-CoreJson {
    <#
    .SYNOPSIS
        Parses JSON into ordered dictionaries and arrays. Unlike ConvertFrom-Json, it never turns an
        ISO timestamp string into a DateTime, on every PowerShell 7 version. Throws on invalid JSON.
    #>
    param([Parameter(Mandatory, ValueFromPipeline)] [AllowEmptyString()] [string]$Json)
    $document = [System.Text.Json.JsonDocument]::Parse($Json, [System.Text.Json.JsonDocumentOptions]@{ AllowTrailingCommas = $false; CommentHandling = 'Disallow' })
    try { return ConvertFrom-CoreJsonElement $document.RootElement }
    finally { $document.Dispose() }
}

function Get-CoreJsonType {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return 'boolean' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [System.Numerics.BigInteger]) { return 'integer' }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) { return 'number' }
    if ($Value -is [System.Collections.IDictionary]) { return 'object' }
    if ($Value -is [System.Collections.IList]) { return 'array' }
    return 'unknown'
}

function Test-CoreJsonTypeMatch {
    param($Value, $Type)
    $actual = Get-CoreJsonType $Value
    foreach ($t in @($Type)) {
        if ($t -eq $actual) { return $true }
        if ($t -eq 'number' -and $actual -eq 'integer') { return $true }
        if ($t -eq 'integer' -and $actual -eq 'number' -and [math]::Floor([double]$Value) -eq [double]$Value) { return $true }
    }
    return $false
}

function ConvertTo-CoreCanonicalJson {
    param($Value)
    # -InputObject keeps arrays as arrays: piping would emit nothing for an empty array and unwrap a single item.
    return (ConvertTo-Json -InputObject $Value -Depth 50 -Compress)
}

function Test-CoreJsonEqual {
    param($A, $B)
    $ta = Get-CoreJsonType $A; $tb = Get-CoreJsonType $B
    $numeric = @('integer', 'number')
    if ($ta -in $numeric -and $tb -in $numeric) { return [decimal]$A -eq [decimal]$B }
    if ($ta -ne $tb) { return $false }
    if ($ta -eq 'string') { return [string]::Equals($A, $B, [StringComparison]::Ordinal) }
    return (ConvertTo-CoreCanonicalJson $A) -eq (ConvertTo-CoreCanonicalJson $B)
}

function Resolve-CoreSchemaRef {
    param($Schema, $Root)
    $guard = 0
    while ($Schema -is [System.Collections.IDictionary] -and $Schema.Contains('$ref')) {
        $ref = [string]$Schema['$ref']
        if (-not $ref.StartsWith('#/')) { throw "Unsupported schema reference '$ref'." }
        $node = $Root
        foreach ($part in $ref.Substring(2).Split('/')) { $node = $node[$part] }
        if ($null -eq $node) { throw "Unresolved schema reference '$ref'." }
        $Schema = $node
        if (++$guard -gt 20) { throw "Schema reference loop at '$ref'." }
    }
    return $Schema
}

function Join-CorePath {
    param([string]$Prefix, [string]$Name)
    if ([string]::IsNullOrEmpty($Prefix)) { return $Name }
    return "$Prefix.$Name"
}

function New-CoreProblem {
    param([string]$Path, [string]$Code, [string]$Detail)
    [pscustomobject]@{ path = $Path; code = $Code; detail = $Detail }
}

# Every required leaf decision of a schema, as dotted paths: a missing section lists what it needs.
function Get-CoreRequiredLeaves {
    param($Schema, $Root, [string]$Prefix, [int]$Depth = 0)
    $Schema = Resolve-CoreSchemaRef $Schema $Root
    $required = if ($Schema -is [System.Collections.IDictionary]) { @($Schema['required']) } else { @() }
    $properties = if ($Schema -is [System.Collections.IDictionary]) { $Schema['properties'] } else { $null }
    if ($Depth -gt 12 -or $required.Count -eq 0 -or $null -eq $properties) { return @($Prefix) }
    $leaves = foreach ($name in $required) {
        if ($null -eq $name) { continue }
        Get-CoreRequiredLeaves -Schema $properties[$name] -Root $Root -Prefix (Join-CorePath $Prefix $name) -Depth ($Depth + 1)
    }
    return @($leaves)
}

function Test-CoreSchemaQuiet {
    param($Value, $Schema, $Root)
    $sink = [System.Collections.Generic.List[object]]::new()
    Add-CoreSchemaProblems -Value $Value -Schema $Schema -Root $Root -Path '' -Problems $sink
    return $sink.Count -eq 0
}

# A oneOf whose branches only name which property must be present: report missing or conflict.
function Test-CoreChoiceOneOf {
    param($Value, $Branches, [string]$Path, $Problems)
    $names = @($Branches | ForEach-Object { @($_['required']) } | Select-Object -Unique)
    $present = @($names | Where-Object { $Value -is [System.Collections.IDictionary] -and $Value.Contains($_) })
    $label = Join-CorePath $Path ($names -join ' | ')
    if ($present.Count -eq 0) { $Problems.Add((New-CoreProblem $label 'missing' 'give exactly one of these')) }
    elseif ($present.Count -gt 1) { $Problems.Add((New-CoreProblem $label 'conflict' 'give exactly one of these, not both')) }
}

function Add-CoreOneOfProblems {
    param($Value, $Branches, $Root, [string]$Path, $Problems)
    $isChoice = @($Branches | Where-Object { -not ($_ -is [System.Collections.IDictionary] -and $_.Contains('required') -and @($_.Keys | Where-Object { $_ -notin @('required', 'not') }).Count -eq 0) }).Count -eq 0
    if ($isChoice) { Test-CoreChoiceOneOf -Value $Value -Branches $Branches -Path $Path -Problems $Problems; return }
    $passing = @($Branches | Where-Object { Test-CoreSchemaQuiet -Value $Value -Schema $_ -Root $Root })
    if ($passing.Count -eq 1) { return }
    $nonNull = @($Branches | Where-Object { $r = Resolve-CoreSchemaRef $_ $Root; -not ($r -is [System.Collections.IDictionary] -and $r['type'] -eq 'null') })
    if ($passing.Count -eq 0 -and $null -ne $Value -and $nonNull.Count -eq 1) {
        Add-CoreSchemaProblems -Value $Value -Schema $nonNull[0] -Root $Root -Path $Path -Problems $Problems
        return
    }
    $Problems.Add((New-CoreProblem $Path 'invalid' 'does not match any allowed form'))
}

function Add-CoreObjectProblems {
    param($Value, $Schema, $Root, [string]$Path, $Problems)
    $properties = $Schema['properties']
    foreach ($name in @($Schema['required'])) {
        if ($null -eq $name -or $Value.Contains($name)) { continue }
        $propertySchema = if ($properties) { $properties[$name] } else { $null }
        foreach ($leaf in (Get-CoreRequiredLeaves -Schema $propertySchema -Root $Root -Prefix (Join-CorePath $Path $name))) {
            $Problems.Add((New-CoreProblem $leaf 'missing' 'required decision'))
        }
    }
    if ($Schema.Contains('maxProperties') -and $Value.Count -gt $Schema['maxProperties']) {
        $Problems.Add((New-CoreProblem $Path 'invalid' "at most $($Schema['maxProperties']) entries"))
    }
    foreach ($key in @($Value.Keys)) {
        $childPath = Join-CorePath $Path $key
        if ($Schema.Contains('propertyNames')) {
            $nameSchema = Resolve-CoreSchemaRef $Schema['propertyNames'] $Root
            if ($nameSchema['pattern'] -and -not [regex]::IsMatch([string]$key, $nameSchema['pattern'])) {
                $Problems.Add((New-CoreProblem $childPath 'invalid' 'key name not allowed'))
                continue
            }
        }
        if ($properties -and $properties.Contains($key)) {
            Add-CoreSchemaProblems -Value $Value[$key] -Schema $properties[$key] -Root $Root -Path $childPath -Problems $Problems
        }
        elseif ($Schema.Contains('additionalProperties')) {
            $extra = $Schema['additionalProperties']
            if ($extra -is [bool] -and -not $extra) { $Problems.Add((New-CoreProblem $childPath 'unexpected' 'unknown key')) }
            elseif ($extra -isnot [bool]) { Add-CoreSchemaProblems -Value $Value[$key] -Schema $extra -Root $Root -Path $childPath -Problems $Problems }
        }
    }
}

function Add-CoreArrayProblems {
    param($Value, $Schema, $Root, [string]$Path, $Problems)
    $count = @($Value).Count
    if ($Schema.Contains('minItems') -and $count -lt $Schema['minItems']) { $Problems.Add((New-CoreProblem $Path 'invalid' "at least $($Schema['minItems']) item(s)")) }
    if ($Schema.Contains('maxItems') -and $count -gt $Schema['maxItems']) { $Problems.Add((New-CoreProblem $Path 'invalid' "at most $($Schema['maxItems']) item(s)")) }
    if ($Schema['uniqueItems'] -eq $true) {
        $seen = @($Value | ForEach-Object { ConvertTo-CoreCanonicalJson $_ })
        if (@($seen | Select-Object -Unique).Count -ne $seen.Count) { $Problems.Add((New-CoreProblem $Path 'invalid' 'items must be unique')) }
    }
    if ($Schema.Contains('items')) {
        for ($i = 0; $i -lt $count; $i++) {
            Add-CoreSchemaProblems -Value $Value[$i] -Schema $Schema['items'] -Root $Root -Path "$Path[$i]" -Problems $Problems
        }
    }
}

function Add-CoreScalarProblems {
    param($Value, $Schema, [string]$Path, $Problems)
    $type = Get-CoreJsonType $Value
    if ($type -eq 'string') {
        if ($Schema.Contains('minLength') -and $Value.Length -lt $Schema['minLength']) { $Problems.Add((New-CoreProblem $Path 'invalid' "at least $($Schema['minLength']) character(s)")) }
        if ($Schema.Contains('maxLength') -and $Value.Length -gt $Schema['maxLength']) { $Problems.Add((New-CoreProblem $Path 'invalid' "at most $($Schema['maxLength']) characters")) }
        if ($Schema.Contains('pattern') -and -not [regex]::IsMatch($Value, $Schema['pattern'])) { $Problems.Add((New-CoreProblem $Path 'invalid' 'format not allowed')) }
    }
    if ($type -in @('integer', 'number')) {
        if ($Schema.Contains('minimum') -and [decimal]$Value -lt [decimal]$Schema['minimum']) { $Problems.Add((New-CoreProblem $Path 'invalid' "minimum $($Schema['minimum'])")) }
        if ($Schema.Contains('maximum') -and [decimal]$Value -gt [decimal]$Schema['maximum']) { $Problems.Add((New-CoreProblem $Path 'invalid' "maximum $($Schema['maximum'])")) }
        if ($Schema.Contains('multipleOf') -and ([decimal]$Value % [decimal]$Schema['multipleOf']) -ne 0) { $Problems.Add((New-CoreProblem $Path 'invalid' "a multiple of $($Schema['multipleOf'])")) }
    }
}

function Add-CoreSchemaProblems {
    param($Value, $Schema, $Root, [string]$Path, $Problems)
    if ($Schema -is [bool]) {
        if (-not $Schema) { $Problems.Add((New-CoreProblem $Path 'forbidden' 'not allowed with the chosen mode')) }
        return
    }
    $Schema = Resolve-CoreSchemaRef $Schema $Root
    if ($Schema.Contains('type') -and -not (Test-CoreJsonTypeMatch $Value $Schema['type'])) {
        $Problems.Add((New-CoreProblem $Path 'invalid' "expected $(@($Schema['type']) -join ' or ')"))
        return
    }
    if ($Schema.Contains('const') -and -not (Test-CoreJsonEqual $Value $Schema['const'])) {
        $Problems.Add((New-CoreProblem $Path 'invalid' "must be $(ConvertTo-CoreCanonicalJson $Schema['const'])")); return
    }
    if ($Schema.Contains('enum') -and -not @($Schema['enum'] | Where-Object { Test-CoreJsonEqual $Value $_ }).Count) {
        $Problems.Add((New-CoreProblem $Path 'invalid' "must be one of $((@($Schema['enum']) | ForEach-Object { ConvertTo-CoreCanonicalJson $_ }) -join ', ')")); return
    }
    Add-CoreScalarProblems -Value $Value -Schema $Schema -Path $Path -Problems $Problems
    $type = Get-CoreJsonType $Value
    if ($type -eq 'object') { Add-CoreObjectProblems -Value $Value -Schema $Schema -Root $Root -Path $Path -Problems $Problems }
    if ($type -eq 'array') { Add-CoreArrayProblems -Value $Value -Schema $Schema -Root $Root -Path $Path -Problems $Problems }
    if ($Schema.Contains('oneOf')) { Add-CoreOneOfProblems -Value $Value -Branches @($Schema['oneOf']) -Root $Root -Path $Path -Problems $Problems }
    if ($Schema.Contains('not') -and (Test-CoreSchemaQuiet -Value $Value -Schema $Schema['not'] -Root $Root)) {
        $Problems.Add((New-CoreProblem $Path 'invalid' 'a form that is not allowed'))
    }
    foreach ($part in @($Schema['allOf'] | Where-Object { $null -ne $_ })) {
        Add-CoreSchemaProblems -Value $Value -Schema $part -Root $Root -Path $Path -Problems $Problems
    }
    if ($Schema.Contains('if')) {
        $branch = if (Test-CoreSchemaQuiet -Value $Value -Schema $Schema['if'] -Root $Root) { $Schema['then'] } else { $Schema['else'] }
        if ($null -ne $branch) { Add-CoreSchemaProblems -Value $Value -Schema $branch -Root $Root -Path $Path -Problems $Problems }
    }
}

function Test-CoreSchema {
    <#
    .SYNOPSIS
        Returns every problem of Value against Schema: objects with path, code and detail. Empty when valid.
    #>
    param([AllowNull()] $Value, [Parameter(Mandatory)] $Schema, $Root, [string]$Path = '')
    if ($null -eq $Root) { $Root = $Schema }
    $problems = [System.Collections.Generic.List[object]]::new()
    Add-CoreSchemaProblems -Value $Value -Schema $Schema -Root $Root -Path $Path -Problems $problems
    return $problems.ToArray()
}

Export-ModuleMember -Function Test-CoreSchema, Get-CoreRequiredLeaves, Get-CoreJsonType, ConvertTo-CoreCanonicalJson, ConvertFrom-CoreJson
