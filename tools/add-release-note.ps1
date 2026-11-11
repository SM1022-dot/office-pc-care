# Appends one entry to toolkit/releases.json (shown on the dashboard). Used by ci-sign.ps1 and publish.ps1.
param([int]$Build, [string]$Notes)
$file = Join-Path (Split-Path -Parent $PSScriptRoot) 'toolkit\releases.json'
$list = @()
if (Test-Path -LiteralPath $file) {
    $parsed = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    # Windows PowerShell 5.1 returns a JSON array as one object; unroll it.
    $list = @($parsed | ForEach-Object { $_ })
}
$list = @($list | Where-Object { [int]$_.build -ne $Build })
$list += [pscustomobject]@{ build = $Build; published = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); notes = $Notes }
$sorted = @($list | Sort-Object { [int]$_.build })
[IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $sorted -Depth 3), (New-Object Text.UTF8Encoding($false)))
