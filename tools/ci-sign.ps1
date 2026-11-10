# Runs in GitHub Actions (windows-latest, Windows PowerShell 5.1) on every change to main.
# Builds toolkit/PC-Care-Toolkit.bat with the next build number, signs toolkit/manifest.json
# with the private key from the "release" environment secret SIGNING_KEY_XML.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'toolkit'
$manifestPath = Join-Path $out 'manifest.json'
$publicXml = (Get-Content -LiteralPath (Join-Path $root 'src\signing-key.public.xml') -Raw).Trim()

function Set-Output([string]$Name, [string]$Value) { if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value ($Name + '=' + $Value) } }

$keyXml = [string]$env:SIGNING_KEY_XML
if (-not $keyXml -or $keyXml -notmatch '<D>') {
    Write-Host 'SIGNING_KEY_XML is not set yet. Nothing was built or published.'
    Set-Output 'published' 'false'
    exit 0
}

New-Item -ItemType Directory -Path $out -Force | Out-Null
$build = 1
if (Test-Path -LiteralPath $manifestPath) { $build = [int]((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).build) + 1 }

& python -I (Join-Path $PSScriptRoot 'build.py') (Join-Path $out 'PC-Care-Toolkit.bat') $build
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
Copy-Item -LiteralPath (Join-Path $root 'src\config.json') -Destination (Join-Path $out 'config.json') -Force
$null = Get-Content -LiteralPath (Join-Path $out 'config.json') -Raw | ConvertFrom-Json

$files = @()
foreach ($name in @('PC-Care-Toolkit.bat', 'config.json')) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $out $name))
    $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    $files += [ordered]@{ name = $name; sha256 = $sha }
}
$notes = ([string]$env:RELEASE_NOTES -split "`n")[0].Trim()
if ($notes.Length -gt 120) { $notes = $notes.Substring(0, 120) }
$manifest = [ordered]@{ build = $build; published = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); notes = $notes; files = $files }
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))

$manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
$rsa = [Security.Cryptography.RSA]::Create()
$rsa.FromXmlString($keyXml)
$keyXml = $null
$signature = [Convert]::ToBase64String($rsa.SignData($manifestBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
$rsa.Dispose()
[IO.File]::WriteAllText((Join-Path $out 'manifest.sig'), $signature, (New-Object Text.ASCIIEncoding))

$check = [Security.Cryptography.RSA]::Create()
$check.FromXmlString($publicXml)
if (-not $check.VerifyData($manifestBytes, [Convert]::FromBase64String($signature), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
    throw 'Signature does not match the public key built into the toolkit. Nothing will be published.'
}
Write-Host ('Built and signed build ' + $build)
Set-Output 'published' 'true'
Set-Output 'build' ([string]$build)
