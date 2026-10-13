#Requires -Version 7.0
function ConvertFrom-OnboardingJson {
    param([Parameter(Mandatory)][string]$Json)
    function Decode([System.Text.Json.JsonElement]$element) {
        switch ($element.ValueKind.ToString()) {
            'Object' {
                $map=[Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
                foreach($property in $element.EnumerateObject()){
                    if($map.Contains($property.Name)){throw 'Duplicate JSON property.'}
                    $map.Add($property.Name,(Decode $property.Value))
                }
                return $map
            }
            'Array' {
                $items=[Collections.Generic.List[object]]::new()
                foreach($item in $element.EnumerateArray()){$items.Add((Decode $item))}
                return ,$items.ToArray()
            }
            'String' {return $element.GetString()}
            'Number' {
                $integer=[long]0;$decimal=[decimal]0
                if($element.TryGetInt64([ref]$integer)){return $integer}
                if($element.TryGetDecimal([ref]$decimal)){return $decimal}
                return $element.GetDouble()
            }
            'True' {return $true}
            'False' {return $false}
            'Null' {return $null}
            default {throw 'Unsupported JSON value.'}
        }
    }
    $document=[System.Text.Json.JsonDocument]::Parse($Json)
    try {return Decode $document.RootElement}
    finally {$document.Dispose()}
}
Export-ModuleMember -Function ConvertFrom-OnboardingJson
