Set-StrictMode -Version Latest
# Secret scan for scripts/New-CustomerRepoFromZip.ps1 (docs/runbooks/CICD-SETUP.md, section 9). It always runs,
# also when gitleaks is installed. Customer names, subscription IDs and resource IDs are allowed; credentials are not.
# Every rule has a positive and a negative case in tests/Test-CustomerRepoZip.ps1.
# Every file is scanned or reported as unscanned; unscanned files make the scan fail (never "clean"):
#   text           UTF-8, or UTF-16/UTF-32 (BOM, or BOM-less UTF-16 detected from NUL bytes)
#   ZIP containers .zip/.docx/.xlsx/... by signature: every entry is scanned (3 levels)
#   PNG            raw bytes and the decompressed zTXt/iTXt text chunks
#   anything else  unscanned (unknown binary, larger than -MaxBytes, link, unreadable)
# Exceptions come only from an operator allow-list file outside the scanned tree (Read-CcofSecretAllowList):
# exact entries, no patterns.

$script:Rules = [ordered]@{
    'private-key'           = '-----BEGIN (RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY( BLOCK)?-----'
    'github-token'          = '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{60,}\b'
    'entra-client-secret'   = '(?<![A-Za-z0-9_~.-])[A-Za-z0-9_~.-]{3}\dQ~[A-Za-z0-9_~.-]{31,34}(?![A-Za-z0-9_~.-])'
    'storage-account-key'   = '(?i)AccountKey=[A-Za-z0-9+/]{80,}={0,2}'
    'cosmos-or-service-key' = '(?<![A-Za-z0-9+/]|sha512-)[A-Za-z0-9+/]{86}==(?![A-Za-z0-9+/=])'
    'sas-signature'         = '(?i)[?&]sig=[A-Za-z0-9%+/]{40,}(%3D|=){0,2}'
    'connection-string-key' = '(?i)(SharedAccessKey|AccountKey|Password)=(?!<|\$|\{|\*)[^;\s''"\[\]{}]{16,}'
    'aws-access-key'        = '\b(AKIA|ASIA)[0-9A-Z]{16}\b'
    'slack-token'           = '\bxox[abprs]-[A-Za-z0-9-]{10,}\b'
    'jwt'                   = '\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{20,}\b'
    'runner-token'          = '(?i)RUNNER_TOKEN\s*=\s*[''"]?[A-Z0-9]{29}\b'
}

function Get-CcofSecretRules { return $script:Rules }

function Get-Sha256Hex([byte[]]$Bytes) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }

function ConvertFrom-CcofTextBytes {
    # Returns the decoded text, or $null when the bytes are not text in a supported encoding.
    param([byte[]]$Bytes)
    $n = $Bytes.Length
    if ($n -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return [Text.Encoding]::UTF8.GetString($Bytes, 3, $n - 3) }
    if ($n -ge 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) { return [Text.Encoding]::UTF32.GetString($Bytes, 4, $n - 4) }
    if ($n -ge 4 -and $Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF) { return [Text.UTF32Encoding]::new($true, $false).GetString($Bytes, 4, $n - 4) }
    if ($n -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($Bytes, 2, $n - 2) }
    if ($n -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $n - 2) }
    if ([Array]::IndexOf($Bytes, [byte]0) -lt 0) { return [Text.Encoding]::UTF8.GetString($Bytes) }
    if ($n % 2 -eq 0) {
        # BOM-less UTF-16: nearly every high byte of mostly-ASCII text is NUL.
        $even = 0; $odd = 0
        for ($i = 0; $i -lt $n; $i += 2) { if ($Bytes[$i] -eq 0) { $even++ }; if ($Bytes[$i + 1] -eq 0) { $odd++ } }
        $half = $n / 2
        if ($odd -ge 0.9 * $half -and $even -lt 0.1 * $half) { return [Text.Encoding]::Unicode.GetString($Bytes) }
        if ($even -ge 0.9 * $half -and $odd -lt 0.1 * $half) { return [Text.Encoding]::BigEndianUnicode.GetString($Bytes) }
    }
    return $null
}

function Find-CcofSecrets {
    # Scans every file under $Path. Returns findings (path, line, rule, redacted excerpt, value hash), the files
    # that could not be scanned (path, reason, sha256) and the number of allow-listed findings and files.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string[]]$Allow = @(), [long]$MaxBytes = 20MB)
    $root = (Resolve-Path -LiteralPath $Path).Path
    $st = [pscustomobject]@{ findings = [Collections.Generic.List[object]]::new(); unscanned = [Collections.Generic.List[object]]::new(); scanned = 0; allowed = 0 }
    $allowSet = [Collections.Generic.HashSet[string]]::new([string[]]@($Allow), [StringComparer]::Ordinal)

    $scanText = {
        param([string]$Rel, [string]$Text)
        $lines = $Text -split "`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            foreach ($name in $script:Rules.Keys) {
                foreach ($m in [regex]::Matches($lines[$i], $script:Rules[$name])) {
                    $v = $m.Value; $hash = Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($v))
                    if ($allowSet.Contains("finding:${Rel}:$($i + 1):${name}:$hash")) { $st.allowed++; continue }
                    $st.findings.Add([pscustomobject]@{ path = $Rel; line = $i + 1; rule = $name; sha256 = $hash
                            excerpt = $v.Substring(0, [Math]::Min(6, $v.Length)) + '...(' + $v.Length + ' chars)' })
                }
            }
        }
    }
    $unscanned = {
        param([string]$Rel, [string]$Reason, [string]$Hash)
        if ($Hash -and $allowSet.Contains("file:${Rel}:$Hash")) { $st.allowed++; return }
        $st.unscanned.Add([pscustomobject]@{ path = $Rel; reason = $Reason; sha256 = $Hash })
    }
    $inflate = {
        param([byte[]]$Data, [int]$Offset)
        $in = [IO.MemoryStream]::new($Data, $Offset, $Data.Length - $Offset); $z = [IO.Compression.ZLibStream]::new($in, [IO.Compression.CompressionMode]::Decompress)
        $out = [IO.MemoryStream]::new(); $buf = [byte[]]::new(65536)
        try { while (($k = $z.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $k); if ($out.Length -gt $MaxBytes) { throw 'chunk too large' } } } finally { $z.Dispose() }
        $out.ToArray()
    }
    $scanBytes = $null
    $scanBytes = {
        param([string]$Rel, [byte[]]$Bytes, [int]$Depth)
        $hash = Get-Sha256Hex $Bytes
        $isZip = $Bytes.Length -ge 4 -and $Bytes[0] -eq 0x50 -and $Bytes[1] -eq 0x4B -and (($Bytes[2] -eq 3 -and $Bytes[3] -eq 4) -or ($Bytes[2] -eq 5 -and $Bytes[3] -eq 6))
        $isPng = $Bytes.Length -ge 8 -and $Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47
        if ($isZip) {
            if ($Depth -ge 3) { & $unscanned $Rel 'archive nested more than 3 levels' $hash; return }
            try {
                $za = [IO.Compression.ZipArchive]::new([IO.MemoryStream]::new($Bytes), [IO.Compression.ZipArchiveMode]::Read)
                try {
                    foreach ($e in $za.Entries) {
                        if ($e.FullName.EndsWith('/')) { continue }
                        if ($e.Length -gt $MaxBytes) { & $unscanned "$Rel!/$($e.FullName)" "entry larger than $($MaxBytes / 1MB) MB" ''; continue }
                        $ms = [IO.MemoryStream]::new(); $s = $e.Open(); try { $s.CopyTo($ms) } finally { $s.Dispose() }
                        & $scanBytes "$Rel!/$($e.FullName)" $ms.ToArray() ($Depth + 1)
                    }
                } finally { $za.Dispose() }
                $st.scanned++
            } catch { & $unscanned $Rel "unreadable archive: $($_.Exception.Message)" $hash }
            return
        }
        if ($isPng) {
            try {
                & $scanText $Rel ([Text.Encoding]::Latin1.GetString($Bytes))
                $p = 8
                while ($p + 12 -le $Bytes.Length) {
                    $len = ([int]$Bytes[$p] -shl 24) -bor ([int]$Bytes[$p + 1] -shl 16) -bor ([int]$Bytes[$p + 2] -shl 8) -bor [int]$Bytes[$p + 3]
                    $type = [Text.Encoding]::ASCII.GetString($Bytes, $p + 4, 4)
                    if ($len -lt 0 -or $p + 12 + $len -gt $Bytes.Length) { throw 'truncated chunk' }
                    $data = [byte[]]::new($len); [Array]::Copy($Bytes, $p + 8, $data, 0, $len)
                    $kw = [Array]::IndexOf($data, [byte]0)
                    if ($type -ceq 'zTXt' -and $kw -ge 0) { & $scanText $Rel ([Text.Encoding]::Latin1.GetString((& $inflate $data ($kw + 2)))) }
                    elseif ($type -ceq 'iTXt' -and $kw -ge 0 -and $data[$kw + 1] -eq 1) {
                        $q = [Array]::IndexOf($data, [byte]0, $kw + 3); $q = [Array]::IndexOf($data, [byte]0, $q + 1)
                        & $scanText $Rel ([Text.Encoding]::UTF8.GetString((& $inflate $data ($q + 1))))
                    }
                    $p += 12 + $len
                }
                if ($p -ne $Bytes.Length) { throw 'truncated chunk or trailing data' }
                $st.scanned++
            } catch { & $unscanned $Rel "unreadable PNG: $($_.Exception.Message)" $hash }
            return
        }
        $text = ConvertFrom-CcofTextBytes $Bytes
        if ($null -ne $text) { & $scanText $Rel $text; $st.scanned++; return }
        # Unknown binary: report ASCII-looking secrets, and fail as unscanned unless the operator allow-lists the file.
        & $scanText $Rel ([Text.Encoding]::Latin1.GetString($Bytes))
        & $unscanned $Rel 'binary file of an unknown type' $hash
    }

    foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force) {
        $rel = [IO.Path]::GetRelativePath($root, $item.FullName).Replace('\', '/')
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { & $unscanned $rel 'symbolic link or junction' ''; continue }
        if ($item.PSIsContainer) { continue }
        if ($item.Length -gt $MaxBytes) { & $unscanned $rel "larger than $($MaxBytes / 1MB) MB" ''; continue }
        & $scanBytes $rel ([IO.File]::ReadAllBytes($item.FullName)) 0
    }
    return [pscustomobject]@{ findings = $st.findings.ToArray(); unscanned = $st.unscanned.ToArray(); scanned = $st.scanned; allowed = $st.allowed }
}

function Read-CcofSecretAllowList {
    # Operator allow-list (kept outside the scanned tree). One exact entry per line, # comments:
    #   finding:<path>:<line>:<rule>:<sha256 of the matched value>   (printed by the scan for each finding)
    #   file:<path>:<sha256 of the file>                              (an unscanned file, e.g. a vetted binary)
    # There are no patterns: a new or changed value never matches. Invalid lines throw.
    param([Parameter(Mandatory)][string]$Path, [string]$ScannedRoot)
    $full = [IO.Path]::GetFullPath($Path)
    if ($ScannedRoot) {
        $r = [IO.Path]::GetFullPath($ScannedRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { throw "allow-list $Path is inside the scanned tree: it must come from the operator, not the archive" }
    }
    $rule = '(' + ((@($script:Rules.Keys) | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'
    $ok = "^(finding:[^:*?\r\n]+:[1-9][0-9]*:${rule}:[0-9a-f]{64}|file:[^:*?\r\n]+:[0-9a-f]{64})$"
    $n = 0
    return @(Get-Content -LiteralPath $full | ForEach-Object {
            $n++; $l = $_.Trim()
            if ($l -and -not $l.StartsWith('#')) {
                if ($l -cnotmatch $ok) { throw "allow-list ${Path}:$n is not an exact finding:<path>:<line>:<rule>:<sha256> or file:<path>:<sha256> entry" }
                $l
            }
        })
}

Export-ModuleMember -Function Get-CcofSecretRules, Find-CcofSecrets, Read-CcofSecretAllowList, ConvertFrom-CcofTextBytes
