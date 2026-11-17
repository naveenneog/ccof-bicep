Set-StrictMode -Version Latest
# Secret scan for scripts/New-CustomerRepoFromZip.ps1 (docs/runbooks/CICD-SETUP.md, section 9). Used when
# gitleaks is not installed. Customer names, subscription IDs and resource IDs are allowed; credentials are not.
# Every rule has a positive and a negative case in tests/Test-CustomerRepoZip.ps1.

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

function Find-CcofSecrets {
    # Scans every text file under $Path. Returns findings with the path, line, rule and a redacted excerpt.
    # Binary files (a NUL byte in the first 8 KB) and files over 5 MB are skipped and counted.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string[]]$AllowPatterns = @())
    $root = (Resolve-Path -LiteralPath $Path).Path
    $findings = [System.Collections.Generic.List[object]]::new()
    $skipped = 0; $scanned = 0
    foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        $rel = [IO.Path]::GetRelativePath($root, $f.FullName).Replace('\', '/')
        if ($rel -match '^\.git/') { continue }
        if ($f.Length -gt 5MB) { $skipped++; continue }
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        if ([Array]::IndexOf($bytes, [byte]0, 0, [Math]::Min(8192, $bytes.Length)) -ge 0) { $skipped++; continue }
        $scanned++
        $lines = [Text.Encoding]::UTF8.GetString($bytes) -split "`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            foreach ($name in $script:Rules.Keys) {
                foreach ($m in [regex]::Matches($lines[$i], $script:Rules[$name])) {
                    $id = "${rel}:$($i + 1):$name"
                    if (@($AllowPatterns | Where-Object { $_ -and $id -match $_ }).Count) { continue }
                    $v = $m.Value
                    $findings.Add([pscustomobject]@{ path = $rel; line = $i + 1; rule = $name; excerpt = $v.Substring(0, [Math]::Min(6, $v.Length)) + '...(' + $v.Length + ' chars)' })
                }
            }
        }
    }
    return [pscustomobject]@{ findings = $findings.ToArray(); scanned = $scanned; skipped = $skipped }
}

function Read-CcofSecretAllowList {
    # .secretscan-allow at the tree root: one regex per line matched against "path:line:rule"; # comments.
    param([Parameter(Mandatory)][string]$Path)
    $f = Join-Path $Path '.secretscan-allow'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    return @(Get-Content -LiteralPath $f | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

Export-ModuleMember -Function Get-CcofSecretRules, Find-CcofSecrets, Read-CcofSecretAllowList
