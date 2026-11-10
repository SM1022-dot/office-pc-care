"""Build PC-Care-Toolkit.bat from src/base-v11.bat + src/toolkit-additions.ps1.

Usage: python -I tools/build.py <output.bat> [build-number]
The public signing key from src/signing-key.public.xml is embedded so every PC can
verify updates. The private key is never read here.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = sys.argv[1]
build = sys.argv[2] if len(sys.argv) > 2 else "0"
assert build.isdigit(), "build number must be digits"

src = os.path.join(ROOT, "src", "base-v11.bat")
add = os.path.join(ROOT, "src", "toolkit-additions.ps1")
pub = os.path.join(ROOT, "src", "signing-key.public.xml")

lines = [l.rstrip("\r") for l in open(src, encoding="utf-8").read().split("\n")]
payload = lines[lines.index("#<OFFICE_PC_CARE_PAYLOAD_20261105_V11_0>") + 1:]

MARKER = "#<OFFICE_PC_CARE_PAYLOAD_V13>"
HEADER = r'''@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Office PC Care Toolkit v13
set "PCTOOLKIT_FILE=%~f0"
set "PCTOOLKIT_MODE=%~1"
set "PCTOOLKIT_ARG=%~2"

rem Always run the toolkit in an elevated CMD window.
fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting Administrator permission...
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$f=$env:PCTOOLKIT_FILE; $arg='/d /c '+[char]34+[char]34+$f+[char]34+' '+$env:PCTOOLKIT_MODE+' '+$env:PCTOOLKIT_ARG+[char]34; Start-Process -FilePath $env:ComSpec -ArgumentList $arg -WorkingDirectory (Split-Path -LiteralPath $f -Parent) -Verb RunAs"
    exit /b
)

rem Run the PowerShell payload stored below. The unique marker avoids matching this command itself.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$f=$env:PCTOOLKIT_FILE; try { [Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false) } catch {}; $lines=[IO.File]::ReadAllLines($f); $marker='MARKER_TEXT'; $i=[Array]::IndexOf($lines,$marker); if($i -lt 0){ Write-Host 'Toolkit payload was not found.' -ForegroundColor Red; exit 2 }; $body=[string]::Join([Environment]::NewLine,$lines[($i+1)..($lines.Length-1)]); & ([scriptblock]::Create($body))"
set "PCTOOLKIT_RC=%errorlevel%"
rem Automatic runs (Task Scheduler) must never wait for a key press.
if not "%PCTOOLKIT_MODE%"=="" exit /b %PCTOOLKIT_RC%
if not "%PCTOOLKIT_RC%"=="0" (
    echo.
    echo The toolkit stopped because of an error.
    pause
)
endlocal
exit /b

MARKER_TEXT'''.replace("MARKER_TEXT", MARKER).split("\n")


def drop_function(body, name):
    start = next(i for i, l in enumerate(body) if l.startswith("function " + name + " ") or l == "function " + name + " {")
    end = next(i for i in range(start + 1, len(body)) if body[i].startswith("function ") or body[i].startswith("$exitToolkit"))
    return body[:start] + body[end:]


for fn in ["Show-OutlookMenu", "Show-PCSpeedMenu", "Show-SystemCareMenu", "Show-InternetMenu"]:
    payload = drop_function(payload, fn)
payload = payload[:payload.index("$exitToolkit = $false")]

text = "\n".join(payload).replace("Office PC Care Toolkit v11.0", "Office PC Care Toolkit v13")
text = "\n".join(l for l in text.split("\n")
                 if not ((l.strip().startswith("Write-MajorWarning") or l.strip().startswith("Write-Host"))
                         and ("IT ONLY" in l or "ONLY FOR IT STAFF" in l)))

for old in ["(viber|outlook|express.?vpn|nordvpn|\\bvpn\\b|vmware|", "(viber|outlook|express.?vpn|nordvpn|vpn|vmware|"]:
    assert old in text, "protected startup pattern not found"
    text = text.replace(old, old + "avro|keyboard|anydesk|teamviewer|ultraviewer|rustdesk|onedrive|googledrive|google drive|")

anchor = "    $targets += @{ Path = (Join-Path $env:ProgramData 'Microsoft\\Windows\\WER\\ReportQueue'); Days = 30; Label = 'Old error queue' }"
assert anchor in text, "daily care anchor not found"
text = text.replace(anchor, anchor + "\n"
    "    $wuService = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue\n"
    "    if ($wuService -and $wuService.Status -ne 'Running') { $targets += @{ Path = (Join-Path $env:WINDIR 'SoftwareDistribution\\Download'); Days = 0; Label = 'Old Windows update files' } }")
anchor2 = "    Write-Host ''\n    Write-Host (\"Space released: {0:N1} MB (approx.)\" -f ($freed / 1MB)) -ForegroundColor Green"
assert anchor2 in text, "daily care anchor 2 not found"
text = text.replace(anchor2,
    "    try { if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null; Write-Host '  Update sharing cache        Cleared' } } catch {}\n" + anchor2)

additions = open(add, encoding="utf-8").read().replace("\r\n", "\n")
public_key = open(pub, encoding="ascii").read().strip()
assert "<D>" not in public_key, "public key file must not contain the private key"
additions = additions.replace("'__UPDATE_PUBLIC_KEY__'", "'" + public_key + "'")
additions = additions.replace("'__TOOLKIT_BUILD__'", "'" + build + "'")

final = "\r\n".join(HEADER) + "\r\n" + text.replace("\n", "\r\n") + "\r\n" + additions.replace("\n", "\r\n")
open(out, "w", encoding="utf-8", newline="").write(final)
print("built", out, "build", build, "lines", final.count("\r\n") + 1)
