@echo off
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
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$f=$env:PCTOOLKIT_FILE; try { [Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false) } catch {}; $lines=[IO.File]::ReadAllLines($f); $marker='#<OFFICE_PC_CARE_PAYLOAD_V13>'; $i=[Array]::IndexOf($lines,$marker); if($i -lt 0){ Write-Host 'Toolkit payload was not found.' -ForegroundColor Red; exit 2 }; $body=[string]::Join([Environment]::NewLine,$lines[($i+1)..($lines.Length-1)]); & ([scriptblock]::Create($body))"
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

#<OFFICE_PC_CARE_PAYLOAD_V13>
# Office PC Care Toolkit v13 - Windows PowerShell 5.1 compatible.
# Offline-first. Does not download tools or change VMware/VPN services.
$ErrorActionPreference = 'Continue'
# Designed for Windows PowerShell 5.1 on Windows 10/11. Unsupported components are skipped safely.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
try { $Host.UI.RawUI.WindowTitle = 'Office PC Care Toolkit v13' } catch {}

$script:LogRoot = Join-Path $env:ProgramData 'Office-PC-Care-Toolkit\Logs'
try { New-Item -ItemType Directory -Path $script:LogRoot -Force | Out-Null } catch {}
$script:LogFile = Join-Path $script:LogRoot ("PC-Care_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
try {
    Get-ChildItem -LiteralPath $script:LogRoot -File -Filter 'PC-Care_*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch {}
try { Start-Transcript -Path $script:LogFile -Force | Out-Null } catch {}

function Write-Header([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
}
function Write-MajorWarning([string]$Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor Red
}
function Wait-Back {
    do {
        $answer = Read-Host 'Press 0 to return'
        if ($answer -ne '0') { Write-Host 'Please press 0 to return.' -ForegroundColor Yellow }
    } while ($answer -ne '0')
}
function Ask-YesNo([string]$Question) {
    do {
        $answer = (Read-Host ($Question + ' (Y/N)')).Trim()
        if ($answer -match '^(?i:Y|YES)$') { return $true }
        if ($answer -match '^(?i:N|NO)$') { return $false }
        Write-Host 'Please type Y or N.' -ForegroundColor Yellow
    } while ($true)
}
function Get-InteractiveProfile {
    # Resolve the desktop user's profile by SID, not by folder name. This also
    # works when the toolkit is elevated with a different administrator account.
    $sessionId = 0
    try { $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId } catch {}
    $result = [pscustomobject]@{ UserName = $null; SID = $null; LocalPath = $null; SessionId = $sessionId }
    $identityCandidates = @()

    try {
        $explorers = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
            Where-Object { $_.SessionId -eq $sessionId } | Sort-Object ProcessId)
        foreach ($explorer in $explorers) {
            try {
                $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction Stop
                if ($owner.ReturnValue -eq 0 -and $owner.User) {
                    $account = if ($owner.Domain) { $owner.Domain + '\' + $owner.User } else { $owner.User }
                    $identityCandidates += $account
                    break
                }
            } catch {}
        }
    } catch {}

    # Fallback for systems where Explorer ownership cannot be queried.
    if ($identityCandidates.Count -eq 0) {
        try {
            $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            if ($computer.UserName) { $identityCandidates += [string]$computer.UserName }
        } catch {}
    }

    foreach ($accountName in $identityCandidates) {
        try {
            $account = [System.Security.Principal.NTAccount]::new($accountName)
            $sid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
            $profile = Get-CimInstance Win32_UserProfile -Filter ("SID='{0}'" -f $sid.Replace("'", "''")) -ErrorAction Stop
            if ($profile -and $profile.Loaded -and $profile.LocalPath -and (Test-Path -LiteralPath $profile.LocalPath)) {
                $result.UserName = $accountName
                $result.SID = $sid
                $result.LocalPath = $profile.LocalPath
                return $result
            }
        } catch {}
    }

    # Last safe fallback: current token's profile, but only when its SID maps
    # to a loaded local profile. Never guess a profile folder from a username.
    try {
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $currentProfile = Get-CimInstance Win32_UserProfile -Filter ("SID='{0}'" -f $currentSid) -ErrorAction Stop
        if ($currentProfile -and $currentProfile.Loaded -and $currentProfile.LocalPath -and (Test-Path -LiteralPath $currentProfile.LocalPath)) {
            $result.UserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $result.SID = $currentSid
            $result.LocalPath = $currentProfile.LocalPath
            return $result
        }
    } catch {}
    return $result
}
function Remove-OldFiles([string]$Path, [int]$OlderThanDays, [string]$Label) {
    $count = 0
    $bytes = [int64]0
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        Write-Host ("  {0,-27} Skipped" -f $Label) -ForegroundColor DarkGray
        return [pscustomobject]@{ Count = 0; Bytes = [int64]0 }
    }
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    try {
        $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
        foreach ($file in $files) {
            try {
                $length = [int64]$file.Length
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                if (-not (Test-Path -LiteralPath $file.FullName)) { $count++; $bytes += $length }
            } catch {}
        }
        $folders = @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending)
        foreach ($folder in $folders) {
            try {
                $child = Get-ChildItem -LiteralPath $folder.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $child) { Remove-Item -LiteralPath $folder.FullName -Force -ErrorAction SilentlyContinue }
            } catch {}
        }
    } catch {}
    Write-Host ("  {0,-27} {1,5} files  {2,8:N1} MB" -f $Label, $count, ($bytes / 1MB))
    return [pscustomobject]@{ Count = $count; Bytes = $bytes }
}

function Invoke-DailyCare {
    Write-Header 'DAILY PC CARE - SAFE CLEANUP'
    Write-Host 'Automatic cleanup. No confirmation is needed.' -ForegroundColor Green
    Write-Host 'Outlook, Viber, VPN, VMware, browser windows and network settings are NOT changed.' -ForegroundColor DarkGray
    Write-Host 'Only old temporary and error-report files are removed. Files in use are skipped.' -ForegroundColor DarkGray
    Write-Host 'Browser data, passwords, cookies, Downloads, Viber chats and Recycle Bin are untouched.' -ForegroundColor DarkGray
    Write-Host ''

    $profile = Get-InteractiveProfile
    $targets = @()
    if ($profile.LocalPath) {
        $targets += @{ Path = (Join-Path $profile.LocalPath 'AppData\Local\Temp'); Days = 2; Label = 'Old user temp files' }
        $targets += @{ Path = (Join-Path $profile.LocalPath 'AppData\Local\CrashDumps'); Days = 14; Label = 'Old app crash files' }
    } else {
        Write-Host 'User temp cleanup skipped: desktop profile could not be identified.' -ForegroundColor Yellow
    }
    $targets += @{ Path = (Join-Path $env:WINDIR 'Temp'); Days = 2; Label = 'Old Windows temp files' }
    $targets += @{ Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'); Days = 30; Label = 'Old error reports' }
    $targets += @{ Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'); Days = 30; Label = 'Old error queue' }
    $wuService = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
    if ($wuService -and $wuService.Status -ne 'Running') { $targets += @{ Path = (Join-Path $env:WINDIR 'SoftwareDistribution\Download'); Days = 0; Label = 'Old Windows update files' } }
    $freed = [int64]0
    foreach ($target in $targets) {
        $result = Remove-OldFiles -Path $target.Path -OlderThanDays $target.Days -Label $target.Label
        $freed += $result.Bytes
    }
    try { if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null; Write-Host '  Update sharing cache        Cleared' } } catch {}
    Write-Host ''
    Write-Host ("Space released: {0:N1} MB (approx.)" -f ($freed / 1MB)) -ForegroundColor Green
    Write-Host 'Daily care completed. No app restart, network reset or PC restart was done.' -ForegroundColor Green
}

function Find-OutlookExe {
    $candidates = @()
    $appPathKeys = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE',
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE'
    )
    $desktopProfile = Get-InteractiveProfile
    if ($desktopProfile.SID) {
        $appPathKeys += ('Registry::HKEY_USERS\' + $desktopProfile.SID + '\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE')
    }
    foreach ($keyPath in $appPathKeys) {
        try {
            if (Test-Path -LiteralPath $keyPath) {
                $key = Get-Item -LiteralPath $keyPath -ErrorAction Stop
                $value = $key.GetValue('')
                if ($value) { $candidates += ([string]$value).Trim([char]34) }
            }
        } catch {}
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16\OUTLOOK.EXE')
        $candidates += (Join-Path $env:ProgramFiles 'Microsoft Office\Office16\OUTLOOK.EXE')
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\root\Office16\OUTLOOK.EXE')
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\Office16\OUTLOOK.EXE')
    }
    foreach ($candidate in $candidates) { if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate } }
    try {
        $cmd = Get-Command outlook.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { return $cmd.Source }
    } catch {}
    return $null
}
function Get-CurrentSessionProcesses([string]$ProcessName) {
    $sessionId = 0
    try { $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId } catch {}
    try {
        return @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $sessionId })
    } catch { return @() }
}
function Close-AppRobust([string]$ProcessName, [string]$AppLabel, [string]$ForceWarning = 'Unsaved work may be lost.') {
    # First request a normal window close. If the app is hung/tray-only, offer
    # a clearly warned force-close and verify that its process really exits.
    $processes = @(Get-CurrentSessionProcesses -ProcessName $ProcessName)
    if ($processes.Count -eq 0) { return $true }
    Write-Host ('Trying to close ' + $AppLabel + ' normally...') -ForegroundColor Cyan
    foreach ($process in $processes) {
        try { if ($process.MainWindowHandle -ne 0) { [void]$process.CloseMainWindow() } } catch {}
    }
    $deadline = (Get-Date).AddSeconds(12)
    do {
        Start-Sleep -Milliseconds 700
        $processes = @(Get-CurrentSessionProcesses -ProcessName $ProcessName)
    } while ($processes.Count -gt 0 -and (Get-Date) -lt $deadline)
    if ($processes.Count -eq 0) { return $true }

    Write-MajorWarning ($AppLabel + ' did not close normally. ' + $ForceWarning)
    if (-not (Ask-YesNo ('Force close ' + $AppLabel + ' now?'))) {
        Write-Host ($AppLabel + ' was left open. No related settings or cache were changed.') -ForegroundColor Yellow
        return $false
    }

    $failedIds = @()
    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        } catch {
            # taskkill is a second built-in Windows fallback for stuck processes.
            try {
                & (Join-Path $env:WINDIR 'System32\taskkill.exe') /PID $process.Id /F 2>&1 | Out-Null
            } catch {}
        }
    }
    $verifyDeadline = (Get-Date).AddSeconds(6)
    do {
        Start-Sleep -Milliseconds 500
        $remaining = @(Get-CurrentSessionProcesses -ProcessName $ProcessName)
    } while ($remaining.Count -gt 0 -and (Get-Date) -lt $verifyDeadline)
    if ($remaining.Count -gt 0) {
        $failedIds = @($remaining | ForEach-Object { $_.Id })
        Write-Host ($AppLabel + ' could not be closed. Process ID(s): ' + ($failedIds -join ', ')) -ForegroundColor Red
        Write-Host 'No cache or settings were changed. Close the app manually and retry.' -ForegroundColor Yellow
        return $false
    }
    Write-Host ($AppLabel + ' was force-closed successfully.') -ForegroundColor Green
    return $true
}
function Start-UserProgram([string]$Path, [string]$Arguments = '') {
    # Prefer the signed-in desktop user's Explorer token. This starts GUI apps in
    # the normal interactive session even when this toolkit is elevated.
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        throw ('Application file was not found: ' + $Path)
    }
    $profile = Get-InteractiveProfile
    if (-not $profile -or -not $profile.LocalPath -or $profile.SessionId -lt 1) {
        throw 'Could not safely identify the signed-in desktop session. Sign in normally and retry.'
    }
    $nativeErrors = @()
    try {
        if (-not ('OfficePCTokenLauncher' -as [type])) {
            Add-Type -Language CSharp -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class OfficePCTokenLauncher {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars;
        public int dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    private static extern bool CreateProcessWithTokenW(IntPtr token, uint logonFlags,
        string applicationName, StringBuilder commandLine, uint creationFlags,
        IntPtr environment, string currentDirectory, ref STARTUPINFO startup,
        out PROCESS_INFORMATION processInfo);
    [DllImport("userenv.dll", SetLastError=true)]
    private static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inherit);
    [DllImport("userenv.dll", SetLastError=true)]
    private static extern bool DestroyEnvironmentBlock(IntPtr environment);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool CloseHandle(IntPtr handle);
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint TOKEN_ASSIGN_PRIMARY = 0x0001;
    private const uint TOKEN_DUPLICATE = 0x0002;
    private const uint TOKEN_QUERY = 0x0008;
    private const uint LOGON_WITH_PROFILE = 1;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const int STARTF_USESHOWWINDOW = 1;
    public static int Launch(int explorerPid, string appPath, string args, string workDir) {
        IntPtr process = IntPtr.Zero, token = IntPtr.Zero, environment = IntPtr.Zero;
        PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
        try {
            process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, explorerPid);
            if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");
            if (!OpenProcessToken(process, TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed");
            CreateEnvironmentBlock(out environment, token, false);
            STARTUPINFO si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            si.lpDesktop = @"winsta0\default";
            si.dwFlags = STARTF_USESHOWWINDOW;
            si.wShowWindow = 1;
            string cmd = "\"" + appPath + "\"" + (String.IsNullOrWhiteSpace(args) ? "" : " " + args);
            StringBuilder commandLine = new StringBuilder(cmd);
            if (!CreateProcessWithTokenW(token, LOGON_WITH_PROFILE, appPath, commandLine,
                CREATE_UNICODE_ENVIRONMENT, environment, workDir, ref si, out pi))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessWithTokenW failed");
            return pi.dwProcessId;
        }
        finally {
            if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
            if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
            if (environment != IntPtr.Zero) DestroyEnvironmentBlock(environment);
            if (token != IntPtr.Zero) CloseHandle(token);
            if (process != IntPtr.Zero) CloseHandle(process);
        }
    }
}
'@
        }
        $explorers = @()
        try {
            $explorers = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
                Where-Object { $_.SessionId -eq $profile.SessionId } | Sort-Object ProcessId)
        } catch {}
        foreach ($explorer in $explorers) {
            try {
                $startedPid = [OfficePCTokenLauncher]::Launch([int]$explorer.ProcessId, [string]$Path, [string]$Arguments, [string](Split-Path -Path $Path -Parent))
                if ($startedPid -gt 0) { return $startedPid }
            } catch { $nativeErrors += $_.Exception.Message }
        }
        if ($explorers.Count -eq 0) { $nativeErrors += 'No Explorer process was found in the signed-in desktop session.' }
    } catch { $nativeErrors += ('Native user-session launch: ' + $_.Exception.Message) }

    # Compatibility fallback for locked-down/modified Windows builds where the
    # Explorer token cannot be duplicated. This uses only a temporary task.
    try {
        return (Start-UserProgramScheduledFallback -Path $Path -Arguments $Arguments)
    } catch {
        $fallbackError = $_.Exception.Message
    }
    throw ('Could not start the application in the signed-in user session. Native launcher: ' + ($nativeErrors -join ' | ') + '; Task Scheduler fallback: ' + $fallbackError)
}

function Start-UserProgramScheduledFallback([string]$Path, [string]$Arguments = '') {
    # Launch a GUI app as the logged-in desktop user, not as the elevated toolkit.
    # Uses Task Scheduler's COM API directly (no ScheduledTasks PowerShell cmdlets,
    # avoiding the parameter-set error reported on some Windows 10 builds).
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        throw ('Application file was not found: ' + $Path)
    }

    $profile = Get-InteractiveProfile
    if (-not $profile.SID -or -not $profile.LocalPath -or -not $profile.UserName -or $profile.SessionId -lt 1) {
        throw 'Could not safely identify the signed-in desktop user. Sign in to the normal Windows desktop and try again.'
    }

    $userTemp = Join-Path $profile.LocalPath 'AppData\Local\Temp'
    try { New-Item -ItemType Directory -Path $userTemp -Force -ErrorAction Stop | Out-Null }
    catch { throw ('Could not access the signed-in user temp folder: ' + $_.Exception.Message) }

    $tag = [Guid]::NewGuid().ToString('N')
    $helperPath = Join-Path $userTemp ('OfficePCTool_Launch_' + $tag + '.ps1')
    $resultPath = Join-Path $userTemp ('OfficePCTool_Launch_' + $tag + '.txt')
    $taskName = 'OfficePCToolkit_Launch_' + $tag
    $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe)) { throw 'Windows PowerShell was not found.' }

    $pathB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$Path))
    $argsB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$Arguments))
    $workB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string](Split-Path -Path $Path -Parent)))
    $resultB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$resultPath))
    $helperCode = @"
`$ErrorActionPreference = 'Stop'
`$appPath = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$pathB64'))
`$appArgs = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$argsB64'))
`$workDir = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$workB64'))
`$resultFile = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$resultB64'))
try {
    `$psi = [System.Diagnostics.ProcessStartInfo]::new()
    `$psi.FileName = `$appPath
    `$psi.Arguments = `$appArgs
    `$psi.WorkingDirectory = `$workDir
    `$psi.UseShellExecute = `$true
    `$process = [System.Diagnostics.Process]::Start(`$psi)
    `$processId = 0
    if (`$process) { `$processId = [int]`$process.Id }
    [IO.File]::WriteAllText(`$resultFile, ('OK|' + `$processId), ([System.Text.UTF8Encoding]::new([bool]0)))
} catch {
    `$errorText = ([string]`$_.Exception.Message).Replace([char]13, ' ').Replace([char]10, ' ').Replace('|', ' ')
    [IO.File]::WriteAllText(`$resultFile, ('ERROR|' + `$errorText), ([System.Text.UTF8Encoding]::new([bool]0)))
}
"@

    try { Set-Content -LiteralPath $helperPath -Value $helperCode -Encoding UTF8 -ErrorAction Stop }
    catch { throw ('Could not prepare user-session launcher: ' + $_.Exception.Message) }

    $taskError = ''
    $stage = 'connect to Windows Task Scheduler'
    $service = $null
    $rootFolder = $null
    $taskDefinition = $null
    $registeredTask = $null
    try {
        $schedulerType = [Type]::GetTypeFromProgID('Schedule.Service')
        if (-not $schedulerType) { throw 'Task Scheduler COM service is not registered on this Windows installation.' }
        $service = [Activator]::CreateInstance($schedulerType)
        $service.Connect()
        $rootFolder = $service.GetFolder('\')

        $stage = 'create temporary interactive task'
        $taskDefinition = $service.NewTask(0)
        $taskDefinition.RegistrationInfo.Description = 'Temporary Office PC Care app launcher; removed after use.'
        $taskDefinition.Principal.UserId = [string]$profile.UserName
        $taskDefinition.Principal.LogonType = 3  # TASK_LOGON_INTERACTIVE_TOKEN
        $taskDefinition.Principal.RunLevel = 0   # TASK_RUNLEVEL_LUA (non-elevated)
        $taskDefinition.Settings.Enabled = $true
        $taskDefinition.Settings.AllowDemandStart = $true
        $taskDefinition.Settings.StartWhenAvailable = $true
        $taskDefinition.Settings.DisallowStartIfOnBatteries = $false
        $taskDefinition.Settings.StopIfGoingOnBatteries = $false
        $taskDefinition.Settings.ExecutionTimeLimit = 'PT2M'

        $stage = 'add temporary launcher action'
        $action = $taskDefinition.Actions.Create(0) # TASK_ACTION_EXEC
        $action.Path = $powershellExe
        $action.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $helperPath + '"'
        $action.WorkingDirectory = $userTemp

        $stage = 'register temporary interactive task'
        # TASK_CREATE_OR_UPDATE = 6; TASK_LOGON_INTERACTIVE_TOKEN = 3.
        $registeredTask = $rootFolder.RegisterTaskDefinition($taskName, $taskDefinition, 6, $null, $null, 3, $null)

        $stage = 'run temporary interactive task'
        $null = $registeredTask.Run($null)

        $deadline = (Get-Date).AddSeconds(20)
        while (-not (Test-Path -LiteralPath $resultPath) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
        }
        if (-not (Test-Path -LiteralPath $resultPath)) {
            throw 'The signed-in user session did not return a launch result within 20 seconds.'
        }

        $launchResult = (Get-Content -LiteralPath $resultPath -Raw -ErrorAction Stop).Trim()
        $parts = $launchResult -split '\|', 2
        if ($parts.Count -lt 2 -or $parts[0] -ne 'OK') {
            $details = if ($parts.Count -gt 1) { $parts[1] } else { $launchResult }
            throw ('The user-session helper could not start the application: ' + $details)
        }
        $pidValue = 0
        [void][int]::TryParse($parts[1], [ref]$pidValue)
        return $pidValue
    } catch {
        $taskError = $stage + ': ' + $_.Exception.Message
    } finally {
        # Delete only this uniquely named temporary task. Do not touch user tasks.
        try { if ($rootFolder) { $rootFolder.DeleteTask($taskName, 0) } } catch {}
        foreach ($comObject in @($registeredTask, $taskDefinition, $rootFolder, $service)) {
            try { if ($comObject) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject) } } catch {}
        }
        foreach ($tempPath in @($helperPath, $resultPath)) {
            try { if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } } catch {}
        }
    }

    # Fallback: ask the existing Windows desktop shell to open the program.
    # Explorer's shell server normally runs in the standard interactive session.
    $shellError = ''
    $shell = $null
    try {
        $shellType = [Type]::GetTypeFromProgID('Shell.Application')
        if (-not $shellType) { throw 'Windows Shell.Application is not registered.' }
        $shell = [Activator]::CreateInstance($shellType)
        $workingDirectory = Split-Path -Path $Path -Parent
        $shell.ShellExecute([string]$Path, [string]$Arguments, [string]$workingDirectory, 'open', 1)
        Start-Sleep -Milliseconds 800
        return 1
    } catch {
        $shellError = $_.Exception.Message
    } finally {
        try { if ($shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } } catch {}
        foreach ($tempPath in @($helperPath, $resultPath)) {
            try { if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } } catch {}
        }
    }

    throw ('Could not launch the application in the signed-in user session. Task Scheduler COM [' + $taskError + ']; Windows Shell [' + $shellError + '].')
}

function Invoke-OutlookSendReceive {
    Write-Header 'OUTLOOK SEND / RECEIVE - GET LATEST MAIL'
    $outlookExe = Find-OutlookExe
    if (-not $outlookExe) {
        Write-Host 'Classic Outlook was not found on this PC.' -ForegroundColor Red
        Write-Host 'This action supports Classic Outlook. New Outlook does not provide this COM feature.' -ForegroundColor Yellow
        return
    }

    Write-Host 'This runs Send/Receive All for every account in the signed-in Outlook profile.' -ForegroundColor Cyan
    Write-Host 'Internet/VPN must be connected and Work Offline must be OFF.' -ForegroundColor Yellow
    Write-Host 'Outlook may also send any messages already waiting in Outbox.' -ForegroundColor DarkGray
    Write-Host 'The mail command will run as the signed-in user, not as Administrator.' -ForegroundColor DarkGray

    $profile = Get-InteractiveProfile
    if (-not $profile.LocalPath -or -not (Test-Path -LiteralPath $profile.LocalPath)) {
        Write-Host 'Could not identify the signed-in Windows user profile safely.' -ForegroundColor Red
        return
    }
    $userTemp = Join-Path $profile.LocalPath 'AppData\Local\Temp'
    try { New-Item -ItemType Directory -Path $userTemp -Force -ErrorAction Stop | Out-Null }
    catch { Write-Host ('Could not access the signed-in user temp folder: ' + $_.Exception.Message) -ForegroundColor Red; return }

    $tag = '{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $PID
    $helperPath = Join-Path $userTemp ('OfficePCTool_Outlook_' + $tag + '.ps1')
    $resultPath = Join-Path $userTemp ('OfficePCTool_Outlook_' + $tag + '.txt')
    $helperCode = @'
param(
    [Parameter(Mandatory=$true)][string]$OutlookExe,
    [Parameter(Mandatory=$true)][string]$ResultFile
)
$ErrorActionPreference = 'Stop'
$app = $null
$session = $null
function Save-Result([string]$State, [string]$Message) {
    $content = $State + [Environment]::NewLine + $Message
    [IO.File]::WriteAllText($ResultFile, $content, ([System.Text.UTF8Encoding]::new($false)))
}
try {
    # First attach to the existing Outlook instance, if any.
    try { $app = [Runtime.InteropServices.Marshal]::GetActiveObject('Outlook.Application') } catch {}

    # If Outlook is not open, start Classic Outlook in this normal user session.
    if (-not $app) {
        $outlookProcesses = @(Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue)
        if ($outlookProcesses.Count -eq 0) {
            Start-Process -FilePath $OutlookExe -ErrorAction Stop | Out-Null
        }
        $deadline = (Get-Date).AddSeconds(65)
        do {
            try { $app = [Runtime.InteropServices.Marshal]::GetActiveObject('Outlook.Application') } catch {}
            if (-not $app) { Start-Sleep -Seconds 2 }
        } while (-not $app -and (Get-Date) -lt $deadline)
    }

    # COM activation is a fallback for a newly started Outlook instance.
    if (-not $app) {
        try {
            $outlookComType = [Type]::GetTypeFromProgID('Outlook.Application')
            if (-not $outlookComType) { throw 'Classic Outlook COM registration was not found.' }
            $app = [Activator]::CreateInstance($outlookComType)
        } catch { $comMessage = $_.Exception.Message }
    }
    if (-not $app) {
        if ($comMessage) { throw ('Outlook COM connection failed: ' + $comMessage) }
        throw 'Outlook did not register its COM automation object. Check that Classic Outlook has finished starting and is not running as Administrator.'
    }

    $session = $app.GetNamespace('MAPI')
    if (-not $session) { throw 'Outlook opened, but its MAPI mail profile was not available.' }

    $isOffline = $false
    try {
        if ([int]$session.ExchangeConnectionMode -eq 100) { $isOffline = $true }
    } catch {}
    if ($isOffline) {
        Save-Result 'OFFLINE' 'Outlook is set to Work Offline. Turn Work Offline OFF in Outlook, then try Send/Receive again.'
        exit 0
    }

    # Microsoft Outlook Object Model: same as Send/Receive All (F9).
    $session.SendAndReceive($true)
    Save-Result 'OK' 'Send/Receive All was requested successfully. Wait for Outlook sync to finish and check the Inbox.'
} catch {
    Save-Result 'ERROR' $_.Exception.Message
} finally {
    if ($session) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($session) } catch {} }
    if ($app) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app) } catch {} }
}
'@

    try {
        Set-Content -LiteralPath $helperPath -Value $helperCode -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Host ('Could not prepare the Outlook helper: ' + $_.Exception.Message) -ForegroundColor Red
        return
    }

    $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumentLine = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $helperPath + '" -OutlookExe "' + $outlookExe + '" -ResultFile "' + $resultPath + '"'
    $launched = $false
    try {
        # Start the COM helper with the actual desktop user's token, not the
        # elevated Toolkit token. This keeps Outlook COM calls at matching integrity.
        $helperPid = Start-UserProgram -Path $powershellExe -Arguments $argumentLine
        $launched = ($helperPid -gt 0)
    } catch {
        Write-Host ('Could not start the normal-user Outlook helper: ' + $_.Exception.Message) -ForegroundColor Red
    }

    if ($launched) {
        Write-Host 'Connecting to Outlook in the signed-in user session...' -ForegroundColor Cyan
        $deadline = (Get-Date).AddSeconds(85)
        while (-not (Test-Path -LiteralPath $resultPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 700 }
        if (Test-Path -LiteralPath $resultPath) {
            try {
                $result = @(Get-Content -LiteralPath $resultPath -ErrorAction Stop)
                $state = if ($result.Count -gt 0) { [string]$result[0] } else { 'ERROR' }
                $message = if ($result.Count -gt 1) { [string]::Join(' ', $result[1..($result.Count - 1)]) } else { 'No details were returned by Outlook.' }
                switch ($state) {
                    'OK' {
                        Write-Host 'Send/Receive All started successfully.' -ForegroundColor Green
                        Write-Host $message -ForegroundColor Cyan
                        Write-Host 'New mail will arrive only if the account and mail server are working.' -ForegroundColor DarkGray
                    }
                    'OFFLINE' {
                        Write-MajorWarning 'Outlook is in Work Offline mode.'
                        Write-Host $message -ForegroundColor Yellow
                    }
                    default {
                        Write-Host 'Outlook automation could not complete.' -ForegroundColor Red
                        Write-Host $message -ForegroundColor Yellow
                        Write-Host 'Check that Classic Outlook is open normally (not Run as administrator), fully signed in, and using the expected mail profile.' -ForegroundColor Yellow
                    }
                }
            } catch { Write-Host ('Could not read Outlook result: ' + $_.Exception.Message) -ForegroundColor Red }
        } else {
            Write-Host 'Outlook did not respond to the helper within 85 seconds.' -ForegroundColor Red
            Write-Host 'It may be waiting for a sign-in or first-run prompt. Finish that prompt, then try again.' -ForegroundColor Yellow
        }
    }

    foreach ($tempFile in @($helperPath, $resultPath)) {
        try { if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue } } catch {}
    }
}

function Invoke-OutlookSyncSettingsReset {
    Write-Header 'REBUILD OUTLOOK SEND / RECEIVE SETTINGS'
    Write-MajorWarning 'IMPORTANT: Outlook will close. Save drafts and check Outbox first.'
    Write-Host 'This rebuilds Outlook Send/Receive rules only. It does NOT rebuild mailbox data or delete PST/OST files.' -ForegroundColor Cyan
    Write-Host 'The old .SRS settings file is kept as a dated backup.' -ForegroundColor Green

    $profile = Get-InteractiveProfile
    if (-not $profile.LocalPath -or -not (Test-Path -LiteralPath $profile.LocalPath)) {
        Write-Host 'Could not identify the signed-in desktop user profile. Nothing was changed.' -ForegroundColor Red
        Write-Host 'Run the Toolkit from the same Windows session where Outlook is used.' -ForegroundColor Yellow
        return
    }
    $settingsFolder = Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Outlook'
    if (-not (Test-Path -LiteralPath $settingsFolder)) {
        Write-Host 'The Outlook settings folder does not exist for this Windows user.' -ForegroundColor Yellow
        Write-Host ('Checked: ' + $settingsFolder) -ForegroundColor DarkGray
        return
    }
    $srsFiles = @()
    try { $srsFiles = @(Get-ChildItem -LiteralPath $settingsFolder -File -Filter '*.srs' -ErrorAction Stop) }
    catch { Write-Host ('Could not read Outlook settings folder: ' + $_.Exception.Message) -ForegroundColor Red; return }
    if ($srsFiles.Count -eq 0) {
        Write-Host 'No .SRS Send/Receive settings file was found. Nothing was changed.' -ForegroundColor Yellow
        Write-Host 'This fix only rebuilds Send/Receive rules. It does not repair passwords, server issues or a damaged OST mailbox cache.' -ForegroundColor DarkGray
        return
    }

    Write-Host ('Windows user: ' + $profile.UserName) -ForegroundColor DarkGray
    Write-Host ('Settings found: ' + $srsFiles.Count) -ForegroundColor Cyan
    Write-Host ('Folder: ' + $settingsFolder) -ForegroundColor DarkGray
    if (-not (Ask-YesNo 'Back up and rebuild Send/Receive settings now?')) {
        Write-Host 'Cancelled. Outlook settings were not changed.' -ForegroundColor Yellow
        return
    }

    if (-not (Close-AppRobust -ProcessName 'OUTLOOK' -AppLabel 'Outlook' -ForceWarning 'Unsaved emails/drafts or messages waiting in Outbox may be lost.')) { return }
    if (@(Get-CurrentSessionProcesses -ProcessName 'OUTLOOK').Count -gt 0) {
        Write-Host 'Outlook is still running. Settings were NOT changed.' -ForegroundColor Red
        return
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $renamed = 0
    $backupPaths = @()
    foreach ($file in $srsFiles) {
        try {
            $backupName = $file.Name + '.backup_' + $stamp
            Rename-Item -LiteralPath $file.FullName -NewName $backupName -ErrorAction Stop
            $renamed++
            $backupPaths += (Join-Path $settingsFolder $backupName)
        } catch {
            Write-Host ('Could not back up ' + $file.Name + ': ' + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    if ($renamed -eq 0) {
        Write-Host 'No settings were changed because a backup could not be created.' -ForegroundColor Red
        return
    }

    Write-Host ('Backed up ' + $renamed + ' Send/Receive settings file(s).') -ForegroundColor Green
    foreach ($backup in $backupPaths) { Write-Host ('Backup: ' + $backup) -ForegroundColor DarkGray }
    Write-Host 'Starting Outlook so it can create fresh default Send/Receive settings...' -ForegroundColor Cyan
    $outlookExe = Find-OutlookExe
    if (-not $outlookExe) {
        Write-Host 'Settings were rebuilt, but Classic Outlook could not be located for automatic restart.' -ForegroundColor Yellow
        return
    }
    try {
        Start-UserProgram -Path $outlookExe
        $deadline = (Get-Date).AddSeconds(25)
        do {
            Start-Sleep -Seconds 1
            $started = @(Get-CurrentSessionProcesses -ProcessName 'OUTLOOK')
        } while ($started.Count -eq 0 -and (Get-Date) -lt $deadline)
        if ($started.Count -gt 0) {
            Write-Host 'Outlook reopened. Fresh Send/Receive settings will be created by Outlook.' -ForegroundColor Green
            Write-Host 'To request mail now, use Outlook Send/Receive or press F9.' -ForegroundColor Cyan
        } else {
            Write-Host 'Settings were backed up and reset, but Outlook did not appear to start.' -ForegroundColor Yellow
            Write-Host 'Open Classic Outlook normally. The reset has already been completed.' -ForegroundColor Yellow
        }
    } catch {
        Write-Host ('Settings were reset, but Outlook could not be reopened: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-Host 'Open Classic Outlook normally to finish rebuilding its settings.' -ForegroundColor Yellow
    }
    Write-Host 'This does not rebuild the OST mailbox cache or fix a mail-server/account problem.' -ForegroundColor DarkGray
}
function Invoke-OutlookAction([string]$Mode) {
    $outlookExe = Find-OutlookExe
    if (-not $outlookExe) {
        Write-Host 'Classic Outlook was not found on this PC.' -ForegroundColor Red
        Write-Host 'This option is for Classic Outlook, not the New Outlook app.' -ForegroundColor Yellow
        return
    }
    $label = switch ($Mode) { 'Normal' { 'Restart Outlook' } 'Safe' { 'Open Outlook in Safe Mode' } 'Nav' { 'Reset Outlook Navigation' } }
    Write-MajorWarning 'IMPORTANT: Outlook will close. Save emails and drafts before continuing.'
    if ($Mode -eq 'Safe') { Write-Host 'Safe Mode starts Outlook with add-ins disabled for testing.' -ForegroundColor Red }
    if ($Mode -eq 'Nav') { Write-Host 'This resets the Outlook side-panel layout. Mail and account data are not deleted.' -ForegroundColor Red }
    if (-not (Ask-YesNo ($label + ' now?'))) { Write-Host 'Cancelled. Outlook was not changed.' -ForegroundColor Yellow; return }
    if (-not (Close-AppRobust -ProcessName 'OUTLOOK' -AppLabel 'Outlook' -ForceWarning 'Unsaved emails/drafts or messages waiting in Outbox may be lost.')) { return }
    Start-Sleep -Seconds 2
    $switch = switch ($Mode) { 'Safe' { '/safe' } 'Nav' { '/resetnavpane' } default { '' } }
    try {
        Start-UserProgram -Path $outlookExe -Arguments $switch
        Start-Sleep -Seconds 8
        if (@(Get-CurrentSessionProcesses -ProcessName 'OUTLOOK').Count -gt 0) { Write-Host 'Outlook started. Check the mail window.' -ForegroundColor Green }
        else { Write-Host 'Outlook start command was sent. If it did not open, start it from the Start menu.' -ForegroundColor Yellow }
    } catch { Write-Host ('Could not start Outlook: ' + $_.Exception.Message) -ForegroundColor Red }
}
function Invoke-OutlookFullFix {
    Write-Header 'OUTLOOK - ONE-CLICK MAIL FIX'
    $outlookExe = Find-OutlookExe
    if (-not $outlookExe) {
        Write-Host 'Classic Outlook was not found. This fix is for Classic Outlook only.' -ForegroundColor Red
        return
    }
    $profile = Get-InteractiveProfile
    if (-not $profile.LocalPath) {
        Write-Host 'Could not identify the signed-in Windows user. Outlook was not changed.' -ForegroundColor Red
        return
    }

    Write-MajorWarning 'IMPORTANT: Outlook will close and reopen. Save drafts and check Outbox first.'
    Write-MajorWarning 'This fix requests Send/Receive, rebuilds Send/Receive settings, and resets the side panel.'
    Write-Host 'Queued outgoing mail may be sent. Use this only when Outlook has a problem, not every day.' -ForegroundColor Yellow
    if (-not (Ask-YesNo 'Run the full Outlook fix now?')) {
        Write-Host 'Cancelled. Outlook was not changed.' -ForegroundColor Yellow
        return
    }

    # Close Outlook before touching its profile settings. A forced close still needs
    # a second explicit confirmation because drafts or Outbox items may be lost.
    if (-not (Close-AppRobust -ProcessName 'OUTLOOK' -AppLabel 'Outlook' -ForceWarning 'Unsaved drafts or messages waiting in Outbox may be lost.')) {
        return
    }
    if (@(Get-CurrentSessionProcesses -ProcessName 'OUTLOOK').Count -gt 0) {
        Write-Host 'Outlook is still running. No settings were changed.' -ForegroundColor Red
        return
    }

    # Back up and rebuild only the classic Outlook Send/Receive rules (.SRS).
    $settingsFolder = Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Outlook'
    $renamed = 0
    $backupPairs = @()
    if (Test-Path -LiteralPath $settingsFolder) {
        $srsFiles = @(Get-ChildItem -LiteralPath $settingsFolder -File -Filter '*.srs' -ErrorAction SilentlyContinue)
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        foreach ($file in $srsFiles) {
            try {
                $backupName = $file.Name + '.backup_' + $stamp
                Rename-Item -LiteralPath $file.FullName -NewName $backupName -ErrorAction Stop
                $backupPath = Join-Path $settingsFolder $backupName
                $backupPairs += [pscustomobject]@{ Backup = $backupPath; Original = $file.FullName }
                $renamed++
                Write-Host ('Backup created: ' + $backupName) -ForegroundColor DarkGray
            } catch {
                Write-Host ('Could not back up ' + $file.Name + ': ' + $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    }
    if ($renamed -gt 0) {
        Write-Host ('Backed up ' + $renamed + ' Send/Receive settings file(s).') -ForegroundColor Green
    } else {
        Write-Host 'No Send/Receive settings file was found, or no file needed changing.' -ForegroundColor Yellow
    }

    # Reopen Outlook with the navigation-pane reset switch as the signed-in
    # desktop user. The previous Explorer.exe argument method could return
    # without actually launching OUTLOOK.EXE.
    try {
        Write-Host 'Starting Classic Outlook in the signed-in Windows account...' -ForegroundColor Cyan
        $outlookStartPid = Start-UserProgram -Path $outlookExe -Arguments '/resetnavpane'
        Write-Host 'Launch request sent to the signed-in Windows user session.' -ForegroundColor DarkGray
        $deadline = (Get-Date).AddSeconds(60)
        do {
            Start-Sleep -Seconds 1
            $started = @(Get-CurrentSessionProcesses -ProcessName 'OUTLOOK')
        } while ($started.Count -eq 0 -and (Get-Date) -lt $deadline)

        if ($started.Count -eq 0) {
            Write-Host 'Windows accepted the launch request, but Classic Outlook did not appear within 60 seconds.' -ForegroundColor Red
            Write-Host 'Check for an Outlook sign-in / first-run prompt, then open Classic Outlook manually.' -ForegroundColor Yellow
            # Restore the previous .SRS file only when no new settings file has
            # been generated, so a failed launch does not leave the profile half-reset.
            foreach ($pair in $backupPairs) {
                try {
                    if ((Test-Path -LiteralPath $pair.Backup) -and -not (Test-Path -LiteralPath $pair.Original)) {
                        Rename-Item -LiteralPath $pair.Backup -NewName (Split-Path -Path $pair.Original -Leaf) -ErrorAction Stop
                        Write-Host ('Previous Send/Receive settings restored: ' + (Split-Path -Path $pair.Original -Leaf)) -ForegroundColor Yellow
                    }
                } catch { Write-Host ('Could not restore previous settings: ' + $_.Exception.Message) -ForegroundColor Red }
            }
            return
        }

        Write-Host 'Outlook process detected. Waiting for its mail profile...' -ForegroundColor Green
        Start-Sleep -Seconds 8
        Write-Host 'Requesting Send/Receive...' -ForegroundColor Cyan
        Invoke-OutlookSendReceive
        Write-Host ''
        Write-Host 'Outlook repair sequence completed. Allow time for mail sync to finish.' -ForegroundColor Green
    } catch {
        Write-Host ('Outlook settings were backed up, but restart failed: ' + $_.Exception.Message) -ForegroundColor Red
        if (@(Get-CurrentSessionProcesses -ProcessName 'OUTLOOK').Count -eq 0) {
            foreach ($pair in $backupPairs) {
                try {
                    if ((Test-Path -LiteralPath $pair.Backup) -and -not (Test-Path -LiteralPath $pair.Original)) {
                        Rename-Item -LiteralPath $pair.Backup -NewName (Split-Path -Path $pair.Original -Leaf) -ErrorAction Stop
                        Write-Host ('Previous Send/Receive settings restored: ' + (Split-Path -Path $pair.Original -Leaf)) -ForegroundColor Yellow
                    }
                } catch { Write-Host ('Could not restore previous settings: ' + $_.Exception.Message) -ForegroundColor Red }
            }
        }
        Write-Host 'Open Classic Outlook manually if needed; mailbox data was not deleted.' -ForegroundColor Yellow
    }
}
function Find-OutlookDataFiles {
    $profile = Get-InteractiveProfile
    if (-not $profile.LocalPath) { return @() }
    $roots = @(
        (Join-Path $profile.LocalPath 'AppData\Local\Microsoft\Outlook'),
        (Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Outlook'),
        (Join-Path $profile.LocalPath 'Documents\Outlook Files'),
        (Join-Path $profile.LocalPath 'My Documents\Outlook Files')
    )
    $found = @()
    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($pattern in @('*.ost','*.pst')) {
            try {
                $found += @(Get-ChildItem -LiteralPath $root -File -Filter $pattern -Force -ErrorAction SilentlyContinue)
            } catch {}
        }
    }
    $seen = @{}
    $results = @()
    foreach ($file in $found) {
        $key = $file.FullName.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $results += [pscustomobject]@{ FullName=$file.FullName; Name=$file.Name; Extension=$file.Extension.ToLowerInvariant(); Length=[int64]$file.Length; LastWriteTime=$file.LastWriteTime }
        }
    }
    return @($results | Sort-Object Extension, Name)
}
function Find-ScanPstExe {
    $candidates = @()
    $outlookExe = Find-OutlookExe
    if ($outlookExe) { $candidates += (Join-Path (Split-Path -Path $outlookExe -Parent) 'SCANPST.EXE') }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16\SCANPST.EXE')
        $candidates += (Join-Path $env:ProgramFiles 'Microsoft Office\Office16\SCANPST.EXE')
        $candidates += (Join-Path $env:ProgramFiles 'Microsoft Office\Office15\SCANPST.EXE')
        $candidates += (Join-Path $env:ProgramFiles 'Microsoft Office\Office14\SCANPST.EXE')
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\root\Office16\SCANPST.EXE')
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\Office16\SCANPST.EXE')
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\Office15\SCANPST.EXE')
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\Office14\SCANPST.EXE')
    }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}
function Invoke-OutlookDataFileRepair {
    Write-Header 'OUTLOOK DATA FILE REPAIR - OST / PST'
    Write-Host 'This tool will NOT delete a data file. It keeps a dated backup before repair.' -ForegroundColor Green
    Write-Host 'OST = offline cache that can usually be rebuilt only when the mailbox is safely stored on the mail server.' -ForegroundColor Cyan
    Write-Host 'PST = personal data file. It must be backed up and checked with Microsoft SCANPST.' -ForegroundColor Cyan

    $files = @(Find-OutlookDataFiles)
    Write-Host ''
    if ($files.Count -gt 0) {
        Write-Host 'Data files found in common Outlook folders:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $files.Count; $i++) {
            $mb = [math]::Round($files[$i].Length / 1MB, 1)
            Write-Host (('{0,2}. [{1}] {2}  ({3:N1} MB)' -f ($i + 1), $files[$i].Extension.TrimStart('.').ToUpperInvariant(), $files[$i].Name, $mb)) -ForegroundColor Green
            Write-Host ('    ' + $files[$i].FullName) -ForegroundColor DarkGray
        }
    } else {
        Write-Host 'No data files were found in the common Outlook folders.' -ForegroundColor Yellow
    }
    Write-Host 'M. Enter a full file path manually' -ForegroundColor Cyan
    $choice = Read-Host 'Choose a file number, M, or 0 to cancel'
    if ($choice -eq '0') { Write-Host 'Cancelled. No Outlook data file was changed.' -ForegroundColor Yellow; return }
    $selected = $null
    if ($choice -match '^(?i:M)$') {
        $manualPath = (Read-Host 'Enter the full OST or PST path').Trim().Trim([char]34)
        if (-not (Test-Path -LiteralPath $manualPath -PathType Leaf)) { Write-Host 'That file was not found. Nothing was changed.' -ForegroundColor Red; return }
        $manualItem = Get-Item -LiteralPath $manualPath -ErrorAction SilentlyContinue
        if (-not $manualItem -or $manualItem.Extension.ToLowerInvariant() -notin @('.ost','.pst')) { Write-Host 'Only .OST and .PST files are supported.' -ForegroundColor Red; return }
        $selected = [pscustomobject]@{ FullName=$manualItem.FullName; Name=$manualItem.Name; Extension=$manualItem.Extension.ToLowerInvariant(); Length=[int64]$manualItem.Length; LastWriteTime=$manualItem.LastWriteTime }
    } else {
        $index = 0
        if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $files.Count) { Write-Host 'Invalid selection. Nothing was changed.' -ForegroundColor Yellow; return }
        $selected = $files[$index - 1]
    }

    Write-Host ''
    Write-Host ('Selected file: ' + $selected.FullName) -ForegroundColor Cyan
    Write-Host ('Size: {0:N1} MB | Last changed: {1}' -f ($selected.Length / 1MB), $selected.LastWriteTime) -ForegroundColor DarkGray
    if ($selected.Extension -eq '.ost') {
        Write-MajorWarning 'OST REBUILD: Make sure Outlook has finished syncing and all recent mail is visible on webmail/server.'
        Write-MajorWarning 'Any unsynced/offline-only items may not return after a new OST is created. The old OST will be kept as backup.'
        Write-Host 'Outlook will close. The selected OST will be renamed, then Outlook will create a fresh cache when opened.' -ForegroundColor Yellow
        if (-not (Ask-YesNo 'Is this a server-synced mailbox, and do you want to rebuild this OST?')) { Write-Host 'Cancelled. The OST was not changed.' -ForegroundColor Yellow; return }
        $outlookExe = Find-OutlookExe
        if (-not $outlookExe) { Write-Host 'Classic Outlook was not found. Nothing was changed.' -ForegroundColor Red; return }
        if (-not (Close-AppRobust -ProcessName 'OUTLOOK' -AppLabel 'Outlook' -ForceWarning 'Unsaved drafts, Outbox messages or unsynced mailbox changes may be lost.')) { return }
        if (@(Get-CurrentSessionProcesses -ProcessName 'OUTLOOK').Count -gt 0) { Write-Host 'Outlook is still running. No file was changed.' -ForegroundColor Red; return }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $backupPath = $selected.FullName + '.backup_' + $stamp
        try {
            Rename-Item -LiteralPath $selected.FullName -NewName (Split-Path -Path $backupPath -Leaf) -ErrorAction Stop
            Write-Host ('Original OST retained as: ' + $backupPath) -ForegroundColor Green
        } catch { Write-Host ('Could not preserve the original OST. No rebuild was attempted: ' + $_.Exception.Message) -ForegroundColor Red; return }
        try {
            Write-Host 'Opening Outlook so it can create a fresh OST...' -ForegroundColor Cyan
            Start-UserProgram -Path $outlookExe | Out-Null
            $deadline = (Get-Date).AddSeconds(60)
            do { Start-Sleep -Seconds 1; $running = @(Get-CurrentSessionProcesses -ProcessName 'OUTLOOK') } while ($running.Count -eq 0 -and (Get-Date) -lt $deadline)
            if ($running.Count -gt 0) {
                Write-Host 'Outlook started. Connect to the internet and allow the mailbox to sync fully.' -ForegroundColor Green
                Write-Host 'Keep the old OST backup until you confirm all expected mail, folders and recent items are present.' -ForegroundColor Yellow
            } else {
                Write-MajorWarning 'Outlook did not start automatically. The old OST backup has been kept.'
                if (-not (Test-Path -LiteralPath $selected.FullName)) {
                    if (Ask-YesNo 'Restore the old OST to its original name now?') {
                        Rename-Item -LiteralPath $backupPath -NewName (Split-Path -Path $selected.FullName -Leaf) -ErrorAction Stop
                        Write-Host 'Old OST restored. No new cache was created.' -ForegroundColor Yellow
                    }
                }
            }
        } catch {
            Write-Host ('Outlook launch failed: ' + $_.Exception.Message) -ForegroundColor Red
            if (-not (Test-Path -LiteralPath $selected.FullName) -and (Test-Path -LiteralPath $backupPath)) {
                try {
                    Rename-Item -LiteralPath $backupPath -NewName (Split-Path -Path $selected.FullName -Leaf) -ErrorAction Stop
                    Write-Host 'The original OST was restored because Outlook did not launch.' -ForegroundColor Yellow
                } catch { Write-Host ('Automatic restore also failed. Original backup remains here: ' + $backupPath) -ForegroundColor Red }
            }
        }
        return
    }

    # PST repair uses SCANPST only after a verified backup has been made.
    $scanpst = Find-ScanPstExe
    if (-not $scanpst) {
        Write-Host 'Microsoft SCANPST.EXE was not found in the detected Office folders.' -ForegroundColor Red
        Write-Host 'No PST change was made. Repair may require Office repair or IT to locate SCANPST.' -ForegroundColor Yellow
        return
    }
    Write-MajorWarning 'PST REPAIR: Outlook must be closed. A full backup copy will be made before SCANPST opens.'
    if (-not (Ask-YesNo 'Back up this PST and open Microsoft Inbox Repair Tool?')) { Write-Host 'Cancelled. No PST file was changed.' -ForegroundColor Yellow; return }
    if (-not (Close-AppRobust -ProcessName 'OUTLOOK' -AppLabel 'Outlook' -ForceWarning 'Unsaved drafts and mail changes may be lost.')) { return }
    if (@(Get-CurrentSessionProcesses -ProcessName 'OUTLOOK').Count -gt 0) { Write-Host 'Outlook is still running. No PST file was changed.' -ForegroundColor Red; return }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupPath = $selected.FullName + '.backup_' + $stamp
    try {
        $root = [IO.Path]::GetPathRoot($selected.FullName)
        $driveInfo = [System.IO.DriveInfo]::new($root)
        if ($driveInfo.IsReady -and $driveInfo.AvailableFreeSpace -lt ($selected.Length + 50MB)) {
            Write-Host 'Not enough free disk space for a safe PST backup. Nothing was changed.' -ForegroundColor Red
            return
        }
        Write-Host 'Creating a full PST backup. Large files may take several minutes...' -ForegroundColor Cyan
        Copy-Item -LiteralPath $selected.FullName -Destination $backupPath -ErrorAction Stop
        $backupItem = Get-Item -LiteralPath $backupPath -ErrorAction Stop
        if ([int64]$backupItem.Length -ne [int64]$selected.Length) { throw 'Backup size does not match the original PST file.' }
        Write-Host ('Verified backup: ' + $backupPath) -ForegroundColor Green
    } catch {
        if (Test-Path -LiteralPath $backupPath) { try { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue } catch {} }
        Write-Host ('PST backup failed. SCANPST was not started: ' + $_.Exception.Message) -ForegroundColor Red
        return
    }
    Write-Host 'Opening Microsoft Inbox Repair Tool (SCANPST)...' -ForegroundColor Cyan
    try {
        Start-UserProgram -Path $scanpst | Out-Null
        Write-Host 'In SCANPST, browse to the exact PST file shown above, click Start, then Repair if errors are found.' -ForegroundColor Green
        Write-Host 'SCANPST may need more than one scan. Keep the verified backup until Outlook data is checked.' -ForegroundColor Yellow
    } catch { Write-Host ('Could not open SCANPST: ' + $_.Exception.Message) -ForegroundColor Red; Write-Host ('Your PST backup remains at: ' + $backupPath) -ForegroundColor Yellow }
}

function Invoke-OutlookSafeMode {
    Write-Header 'OUTLOOK NOT OPENING - SAFE MODE'
    $outlookExe = Find-OutlookExe
    if (-not $outlookExe) {
        Write-Host 'Classic Outlook was not found on this PC.' -ForegroundColor Red
        return
    }
    Write-MajorWarning 'Outlook will close if it is open. Save any drafts first.'
    Write-Host 'Safe Mode starts Outlook with add-ins disabled. Use this when Outlook will not open or keeps crashing.' -ForegroundColor Cyan
    if (-not (Ask-YesNo 'Open Outlook in Safe Mode now?')) {
        Write-Host 'Cancelled. Outlook was not changed.' -ForegroundColor Yellow
        return
    }
    if (-not (Close-AppRobust -ProcessName 'OUTLOOK' -AppLabel 'Outlook' -ForceWarning 'Unsaved drafts or messages waiting in Outbox may be lost.')) { return }
    try {
        Start-UserProgram -Path $outlookExe -Arguments '/safe'
        Start-Sleep -Seconds 8
        if (@(Get-CurrentSessionProcesses -ProcessName 'OUTLOOK').Count -gt 0) {
            Write-Host 'Outlook Safe Mode started. Check whether it opens correctly.' -ForegroundColor Green
        } else {
            Write-Host 'Safe Mode start was requested. If Outlook did not open, contact IT.' -ForegroundColor Yellow
        }
    } catch { Write-Host ('Could not start Outlook Safe Mode: ' + $_.Exception.Message) -ForegroundColor Red }
}
function Invoke-InternetOneClickFix {
    Write-Header 'INTERNET PROBLEM FIX - ONE CLICK'
    Write-MajorWarning 'IMPORTANT: Disconnect NordVPN / ExpressVPN before running this fix.'
    Write-MajorWarning 'Internet may pause briefly while the network address is renewed.'
    Write-Host 'This clears DNS and renews DHCP on active physical Ethernet/Wi-Fi adapters only.' -ForegroundColor Cyan
    if (-not (Ask-YesNo 'Continue with Internet Problem Fix?')) {
        Write-Host 'Cancelled. No network change was made.' -ForegroundColor Yellow
        return
    }

    Write-Host '[1/2] Refreshing DNS...' -ForegroundColor Cyan
    try { Clear-DnsClientCache -ErrorAction Stop; Write-Host 'DNS cache refreshed.' -ForegroundColor Green }
    catch { & ipconfig.exe /flushdns | Out-Host }

    Write-Host ''
    Write-Host '[2/2] Renewing physical network connection...' -ForegroundColor Cyan
    $adapters = @()
    try {
        $physical = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
        foreach ($adapter in $physical) {
            $ipInterface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($ipInterface -and [string]$ipInterface.Dhcp -eq 'Enabled') { $adapters += $adapter }
        }
    } catch {}

    if ($adapters.Count -eq 0) {
        Write-Host 'No active physical DHCP adapter was found. DNS was refreshed; IP renew was skipped.' -ForegroundColor Yellow
        Write-Host 'Static IP connections are left unchanged.' -ForegroundColor DarkGray
        return
    }
    foreach ($adapter in $adapters) {
        Write-Host ('Renewing: ' + $adapter.Name) -ForegroundColor Cyan
        & ipconfig.exe /renew $adapter.Name | Out-Host
        if ($LASTEXITCODE -eq 0) { Write-Host ($adapter.Name + ': renew command completed.') -ForegroundColor Green }
        else { Write-Host ($adapter.Name + ': renew reported an issue. Check the connection.') -ForegroundColor Yellow }
    }
    Write-Host 'Wait for the internet to reconnect before turning VPN back on.' -ForegroundColor Green
}
function Invoke-NetworkToolsReset {
    Write-Header 'RESET NETWORK TOOLS'
    Write-MajorWarning 'This can break custom IP/DNS settings and interrupt VPN / VMware networking.'
    Write-MajorWarning 'A PC restart may be required. Do not use for a normal internet issue.'
    if (-not (Ask-YesNo 'Continue with the network reset?')) {
        Write-Host 'Cancelled. No network reset was performed.' -ForegroundColor Yellow
        return
    }

    $backupRoot = Join-Path $env:ProgramData ('Office-PC-Care-Toolkit\NetworkBackup\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try { New-Item -ItemType Directory -Path $backupRoot -Force -ErrorAction Stop | Out-Null }
    catch { Write-Host 'Could not create a network backup folder. Reset cancelled.' -ForegroundColor Red; return }
    try { & ipconfig.exe /all | Out-File -LiteralPath (Join-Path $backupRoot 'ipconfig-all.txt') -Encoding UTF8 }
    catch {}
    try { & netsh.exe interface ip dump | Out-File -LiteralPath (Join-Path $backupRoot 'ip-settings.txt') -Encoding UTF8 }
    catch {}
    try { & netsh.exe winsock show catalog | Out-File -LiteralPath (Join-Path $backupRoot 'winsock-catalog.txt') -Encoding UTF8 }
    catch {}
    Write-Host ('Network information backup: ' + $backupRoot) -ForegroundColor DarkGray

    Write-Host '[1/2] Resetting Winsock...' -ForegroundColor Cyan
    & netsh.exe winsock reset | Out-Host
    $winsockCode = $LASTEXITCODE
    Write-Host ''
    Write-Host '[2/2] Resetting TCP/IP settings...' -ForegroundColor Cyan
    & netsh.exe int ip reset (Join-Path $backupRoot 'ip-reset.log') | Out-Host
    $ipCode = $LASTEXITCODE
    if ($winsockCode -eq 0 -and $ipCode -eq 0) {
        Write-Host 'Network reset commands completed. Restart the PC outside busy hours.' -ForegroundColor Green
    } else {
        Write-Host ('Network reset returned codes: Winsock=' + $winsockCode + ', TCP/IP=' + $ipCode) -ForegroundColor Yellow
        Write-Host 'Read the command output and ask IT to review the saved backup.' -ForegroundColor Yellow
    }
}
function Find-ViberExe([string]$ProfilePath) {
    $paths = @()
    if ($ProfilePath -and (Test-Path -LiteralPath $ProfilePath)) {
        $paths += (Join-Path $ProfilePath 'AppData\Local\Viber\Viber.exe')
        $paths += (Join-Path $ProfilePath 'AppData\Local\Programs\Viber\Viber.exe')
    }
    if ($env:ProgramFiles) { $paths += (Join-Path $env:ProgramFiles 'Viber\Viber.exe') }
    if (${env:ProgramFiles(x86)}) { $paths += (Join-Path ${env:ProgramFiles(x86)} 'Viber\Viber.exe') }
    foreach ($path in $paths) { if (Test-Path -LiteralPath $path) { return $path } }
    try {
        $process = Get-CurrentSessionProcesses -ProcessName 'Viber' | Select-Object -First 1
        if ($process.Path -and (Test-Path -LiteralPath $process.Path)) { return $process.Path }
    } catch {}
    return $null
}
function Stop-ViberSafely {
    return (Close-AppRobust -ProcessName 'Viber' -AppLabel 'Viber' -ForceWarning 'Active calls will end. Unsent messages may be lost.')
}
function Move-ViberCacheToBackup([string]$ProfilePath, [bool]$IncludeLocks) {
    $candidates = @()
    $roamingRoot = Join-Path $ProfilePath 'AppData\Roaming\ViberPC'
    if (Test-Path -LiteralPath $roamingRoot) {
        foreach ($versionFolder in (Get-ChildItem -LiteralPath $roamingRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            foreach ($cacheName in @('QmlWebCache', 'QmlUrlCache')) {
                $cachePath = Join-Path $versionFolder.FullName $cacheName
                if (Test-Path -LiteralPath $cachePath) {
                    $candidates += [pscustomobject]@{ Path = $cachePath; Relative = (Join-Path 'Roaming-ViberPC' (Join-Path $versionFolder.Name $cacheName)) }
                }
            }
        }
        if ($IncludeLocks) {
            foreach ($lock in (Get-ChildItem -LiteralPath $roamingRoot -File -Filter '*.lock' -Force -ErrorAction SilentlyContinue)) {
                $candidates += [pscustomobject]@{ Path = $lock.FullName; Relative = (Join-Path 'Roaming-ViberPC\locks' $lock.Name) }
            }
            foreach ($runFolder in (Get-ChildItem -LiteralPath $roamingRoot -Directory -Filter '*.run' -Force -ErrorAction SilentlyContinue)) {
                $candidates += [pscustomobject]@{ Path = $runFolder.FullName; Relative = (Join-Path 'Roaming-ViberPC\locks' $runFolder.Name) }
            }
        }
    }
    $localRoot = Join-Path $ProfilePath 'AppData\Local'
    if (Test-Path -LiteralPath $localRoot) {
        foreach ($vendorFolder in (Get-ChildItem -LiteralPath $localRoot -Directory -Filter 'Viber Media*' -Force -ErrorAction SilentlyContinue)) {
            $qmlCache = Join-Path $vendorFolder.FullName 'ViberPC\cache\qmlcache'
            if (Test-Path -LiteralPath $qmlCache) {
                $relativeName = Join-Path 'Local-ViberMedia' (Join-Path $vendorFolder.Name 'ViberPC\cache\qmlcache')
                $candidates += [pscustomobject]@{ Path = $qmlCache; Relative = $relativeName }
            }
        }
    }
    $roamingVendorRoot = Join-Path $ProfilePath 'AppData\Roaming'
    if (Test-Path -LiteralPath $roamingVendorRoot) {
        foreach ($vendorFolder in (Get-ChildItem -LiteralPath $roamingVendorRoot -Directory -Filter 'Viber Media*' -Force -ErrorAction SilentlyContinue)) {
            $qmlCache = Join-Path $vendorFolder.FullName 'ViberPC\cache\qmlcache'
            if (Test-Path -LiteralPath $qmlCache) {
                $relativeName = Join-Path 'Roaming-ViberMedia' (Join-Path $vendorFolder.Name 'ViberPC\cache\qmlcache')
                $candidates += [pscustomobject]@{ Path = $qmlCache; Relative = $relativeName }
            }
        }
    }
    if ($IncludeLocks) {
        $tempLock = Join-Path $ProfilePath 'AppData\Local\Temp\qtsingleapp-Viber-0-1-lockfile'
        if (Test-Path -LiteralPath $tempLock) {
            $candidates += [pscustomobject]@{ Path = $tempLock; Relative = 'Temp\qtsingleapp-Viber-0-1-lockfile' }
        }
    }
    if ($candidates.Count -eq 0) {
        Write-Host 'No known Viber cache or stale lock items were found. Nothing was deleted.' -ForegroundColor Yellow
        return 0
    }
    $backupRoot = Join-Path $ProfilePath 'AppData\Local\Office-PC-Care-Toolkit\ViberCacheBackup'
    $backupPath = Join-Path $backupRoot ('Backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try { New-Item -ItemType Directory -Path $backupPath -Force | Out-Null }
    catch { Write-Host 'Could not create the Viber cache backup. Nothing was moved.' -ForegroundColor Red; return 0 }
    $moved = 0
    foreach ($item in $candidates) {
        try {
            $destination = Join-Path $backupPath $item.Relative
            $parent = Split-Path -Parent $destination
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            Move-Item -LiteralPath $item.Path -Destination $destination -ErrorAction Stop
            $moved++
        } catch { Write-Host ('Could not move cache item: ' + $item.Path) -ForegroundColor Yellow }
    }
    if ($moved -gt 0) {
        Write-Host ("Moved {0} cache/lock item(s) to backup:" -f $moved) -ForegroundColor Green
        Write-Host $backupPath -ForegroundColor DarkGray
        Write-Host 'Backup is kept. The toolkit will NOT auto-delete it.' -ForegroundColor DarkGray
    } else {
        try { Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        Write-Host 'No cache item could be moved. Viber data was not deleted.' -ForegroundColor Yellow
    }
    return $moved
}
function Bring-ViberWindowForward {
    try {
        if (-not ('OfficeViberWindowApi' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class OfficeViberWindowApi {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr extraData);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    public static IntPtr FindWindow(int[] ids) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr extra) {
            uint pid = 0;
            GetWindowThreadProcessId(hWnd, out pid);
            if (Array.IndexOf(ids, (int)pid) >= 0 && IsWindowVisible(hWnd)) { found = hWnd; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@
        }
        $ids = @((Get-CurrentSessionProcesses -ProcessName 'Viber' | ForEach-Object { [int]$_.Id }))
        if ($ids.Count -gt 0) {
            $window = [OfficeViberWindowApi]::FindWindow([int[]]$ids)
            if ($window -ne [IntPtr]::Zero) {
                [OfficeViberWindowApi]::ShowWindow($window, 9) | Out-Null
                [OfficeViberWindowApi]::SetForegroundWindow($window) | Out-Null
            }
        }
    } catch {}
}
function Start-ViberAgain([string]$ViberExe) {
    if (-not $ViberExe -or -not (Test-Path -LiteralPath $ViberExe)) {
        Write-Host 'Viber program was not found. Open Viber from the Start menu.' -ForegroundColor Yellow
        return
    }
    try {
        Start-UserProgram -Path $ViberExe
        Start-Sleep -Seconds 10
        if (@(Get-CurrentSessionProcesses -ProcessName 'Viber').Count -gt 0) {
            Bring-ViberWindowForward
            Write-Host 'Viber started. Check the Viber window or system tray.' -ForegroundColor Green
        } else {
            Write-Host 'Viber did not start. Open it from the Start menu.' -ForegroundColor Yellow
        }
    } catch { Write-Host ('Could not start Viber: ' + $_.Exception.Message) -ForegroundColor Red }
}
function Invoke-ViberFix([string]$Mode) {
    Write-Header 'VIBER FIX - HANG / SLOW APP'
    $profile = Get-InteractiveProfile
    if (-not $profile.LocalPath) { Write-Host 'Could not identify the signed-in desktop profile. Viber was not changed.' -ForegroundColor Red; return }
    $viberExe = Find-ViberExe -ProfilePath $profile.LocalPath
    if (-not $viberExe) { Write-Host 'Viber was not found on this PC.' -ForegroundColor Red; return }
    Write-Host 'Chats, contacts, account and message database are not targeted.' -ForegroundColor DarkGray
    if ($Mode -eq 'Restart') {
        Write-MajorWarning 'IMPORTANT: Viber will close. Active calls end. Send any pending message before continuing.'
        if (-not (Ask-YesNo 'Restart Viber now?')) { Write-Host 'Cancelled. Viber was not changed.' -ForegroundColor Yellow; return }
    } else {
        Write-MajorWarning 'WARNING: DO NOT run during a Viber call, live sales chat, or customer-information work.'
        Write-MajorWarning 'Viber will close. Active calls end; unsent messages may be delayed. The first start may take longer.'
        Write-Host 'Only recognised UI cache and stale lock items are moved to backup. Chats, media and account data are not deleted.' -ForegroundColor Yellow
        if (-not (Ask-YesNo 'Continue with Viber cache repair?')) { Write-Host 'Cancelled. Viber was not changed.' -ForegroundColor Yellow; return }
    }
    if (-not (Stop-ViberSafely)) { return }
    Start-Sleep -Seconds 2
    if ($Mode -eq 'Cache' -or $Mode -eq 'Full') {
        $includeLocks = ($Mode -eq 'Full')
        [void](Move-ViberCacheToBackup -ProfilePath $profile.LocalPath -IncludeLocks:$includeLocks)
    }
    Write-Host 'Starting Viber...' -ForegroundColor Cyan
    Start-ViberAgain -ViberExe $viberExe
}
function Find-VpnApps {
    $items = @()
    $expressPaths = @()
    if (${env:ProgramFiles(x86)}) {
        $expressPaths += (Join-Path ${env:ProgramFiles(x86)} 'ExpressVPN\services\expressvpnctl.exe')
        $expressPaths += (Join-Path ${env:ProgramFiles(x86)} 'ExpressVPN\expressvpnctl.exe')
    }
    if ($env:ProgramFiles) {
        $expressPaths += (Join-Path $env:ProgramFiles 'ExpressVPN\services\expressvpnctl.exe')
        $expressPaths += (Join-Path $env:ProgramFiles 'ExpressVPN\expressvpnctl.exe')
    }
    $express = $expressPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if ($express) { $items += [pscustomobject]@{ Name = 'ExpressVPN'; Kind = 'Express'; Path = $express } }

    $nordPaths = @()
    if ($env:ProgramFiles) { $nordPaths += (Join-Path $env:ProgramFiles 'NordVPN\NordVPN.exe') }
    if (${env:ProgramFiles(x86)}) { $nordPaths += (Join-Path ${env:ProgramFiles(x86)} 'NordVPN\NordVPN.exe') }
    $nord = $nordPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if ($nord) { $items += [pscustomobject]@{ Name = 'NordVPN'; Kind = 'Nord'; Path = $nord } }
    return @($items)
}
function Invoke-VpnReconnect([string]$Kind) {
    $items = @(Find-VpnApps)
    $selected = $items | Where-Object { $_.Kind -eq $Kind } | Select-Object -First 1
    $label = if ($Kind -eq 'Nord') { 'NordVPN' } else { 'ExpressVPN' }
    if (-not $selected) {
        Write-Host ($label + ' was not found on this PC. No VPN setting was changed.') -ForegroundColor Yellow
        return
    }
    Write-Header ($label.ToUpperInvariant() + ' - RECONNECT')
    Write-MajorWarning ($label + ' will disconnect briefly. Internet, active office work and VMware network traffic may pause.')
    if (-not (Ask-YesNo ('Reconnect ' + $label + ' now?'))) { Write-Host 'Cancelled. VPN was not changed.' -ForegroundColor Yellow; return }
    try {
        if ($Kind -eq 'Express') {
            Write-Host 'Checking ExpressVPN command-line control...' -ForegroundColor Cyan
            $status = @(& $selected.Path status 2>&1)
            $statusCode = $LASTEXITCODE
            if ($statusCode -ne 0) {
                Write-Host 'This ExpressVPN CLI did not return a valid status. No disconnect was attempted.' -ForegroundColor Red
                Write-Host 'Open ExpressVPN manually and use its Connect button, or ask IT to check the installed app version.' -ForegroundColor Yellow
                return
            }
            Write-Host 'Disconnecting ExpressVPN...' -ForegroundColor Cyan
            & $selected.Path disconnect 2>&1 | Out-Host
            $disconnectCode = $LASTEXITCODE
            Start-Sleep -Seconds 3
            Write-Host 'Connecting ExpressVPN...' -ForegroundColor Cyan
            & $selected.Path connect 2>&1 | Out-Host
            $connectCode = $LASTEXITCODE
            if ($connectCode -eq 0) { Write-Host 'ExpressVPN connect request completed. Wait for the app to show Connected.' -ForegroundColor Green }
            else { Write-Host ('ExpressVPN connect returned exit code ' + $connectCode + '. Open the app and reconnect manually.') -ForegroundColor Yellow }
            if ($disconnectCode -ne 0) { Write-Host ('Disconnect returned exit code ' + $disconnectCode + '; the connect request was still sent.') -ForegroundColor Yellow }
        } elseif ($Kind -eq 'Nord') {
            Write-Host 'Sending NordVPN disconnect command...' -ForegroundColor Cyan
            $null = Start-Process -FilePath $selected.Path -ArgumentList '-d' -WorkingDirectory (Split-Path -Path $selected.Path -Parent) -PassThru -ErrorAction Stop
            Start-Sleep -Seconds 3
            Write-Host 'Sending NordVPN quick-connect command...' -ForegroundColor Cyan
            $null = Start-Process -FilePath $selected.Path -ArgumentList '-c' -WorkingDirectory (Split-Path -Path $selected.Path -Parent) -PassThru -ErrorAction Stop
            Start-Sleep -Seconds 5
            Write-Host 'NordVPN reconnect commands were sent. Confirm that the NordVPN app shows Connected.' -ForegroundColor Green
        } else {
            Write-Host 'Unsupported VPN selection. No change was made.' -ForegroundColor Red
        }
    } catch {
        Write-Host ($label + ' reconnect command failed: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host 'Open the VPN app and reconnect manually. Do not reset network adapters for this error.' -ForegroundColor Yellow
    }
}
function Show-VpnMenu {
    while ($true) {
        Clear-Host
        Write-Header 'VPN FIX - NORDVPN / EXPRESSVPN ONLY'
        Write-Host '  1. NordVPN Reconnect' -ForegroundColor Green
        Write-Host '  2. ExpressVPN Reconnect' -ForegroundColor Green
        Write-Host '  0. Back'
        $pick = Read-Host 'Choose a number'
        switch ($pick) {
            '1' { Invoke-VpnReconnect 'Nord'; Wait-Back }
            '2' { Invoke-VpnReconnect 'Express'; Wait-Back }
            '0' { return }
            default { Write-Host 'Choose 0, 1 or 2.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}

function Invoke-ExplorerRestart {
    Write-Header 'RESTART FILE EXPLORER'
    Write-MajorWarning 'IMPORTANT: The taskbar and desktop may disappear briefly. Open File Explorer windows may close.'
    if (-not (Ask-YesNo 'Restart File Explorer now?')) { Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow; return }
    try {
        Get-CurrentSessionProcesses -ProcessName 'explorer' | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 3
        if (@(Get-CurrentSessionProcesses -ProcessName 'explorer').Count -gt 0) { Write-Host 'File Explorer restarted.' -ForegroundColor Green }
        else { Write-Host 'Explorer restart command was sent. If the taskbar is missing, press Ctrl+Shift+Esc and run explorer.exe.' -ForegroundColor Yellow }
    } catch { Write-Host ('Explorer restart failed: ' + $_.Exception.Message) -ForegroundColor Red }
}
function Get-VisualTuneBackupPath {
    $profile = Get-InteractiveProfile
    if (-not $profile.LocalPath) { return $null }
    return (Join-Path $profile.LocalPath 'AppData\Local\Office-PC-Care-Toolkit\VisualEffectsBackup.xml')
}
function Get-RegistryValueSnapshot([string]$Path, [string]$Name) {
    $exists = $false
    $value = $null
    try {
        if (Test-Path -LiteralPath $Path) {
            $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
            $value = $item.$Name
            $exists = $true
        }
    } catch {}
    return [pscustomobject]@{ Path = $Path; Name = $Name; Exists = $exists; Value = $value }
}
function Set-LowEndVisualTune {
    Write-Header 'LOW-END PC TUNE - BASIC SPEED'
    Write-Host 'Reducing a few animations and transparency effects for older PCs...' -ForegroundColor Cyan
    Write-Host 'Dark/light mode, wallpaper, icons and app colours will NOT change.' -ForegroundColor Green
    Write-Host 'Office apps, VPN, VMware and Windows services will NOT be disabled.' -ForegroundColor Green
    $profile = Get-InteractiveProfile
    if (-not $profile.LocalPath -or -not $profile.SID) {
        Write-Host 'Could not identify the signed-in Windows profile. Visual settings were not changed.' -ForegroundColor Red
        return
    }
    $userRoot = 'Registry::HKEY_USERS\' + $profile.SID
    $settings = @(
        @{ Path = ($userRoot + '\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'); Name = 'EnableTransparency'; Value = 0; Type = 'DWord' },
        @{ Path = ($userRoot + '\Control Panel\Desktop\WindowMetrics'); Name = 'MinAnimate'; Value = '0'; Type = 'String' },
        @{ Path = ($userRoot + '\Control Panel\Desktop'); Name = 'MenuShowDelay'; Value = '100'; Type = 'String' },
        @{ Path = ($userRoot + '\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'); Name = 'TaskbarAnimations'; Value = 0; Type = 'DWord' }
    )
    $backupFile = Get-VisualTuneBackupPath
    if (-not $backupFile) { Write-Host 'Could not create a backup path for the signed-in user.' -ForegroundColor Red; return }
    try {
        $backupFolder = Split-Path -Parent $backupFile
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        if (-not (Test-Path -LiteralPath $backupFile)) {
            $snapshot = @()
            foreach ($setting in $settings) { $snapshot += Get-RegistryValueSnapshot -Path $setting.Path -Name $setting.Name }
            $snapshot | Export-Clixml -LiteralPath $backupFile -Force
        }
        foreach ($setting in $settings) {
            if (-not (Test-Path -LiteralPath $setting.Path)) { New-Item -Path $setting.Path -Force | Out-Null }
            New-ItemProperty -LiteralPath $setting.Path -Name $setting.Name -Value $setting.Value -PropertyType $setting.Type -Force | Out-Null
        }
        Write-Host 'Basic visual speed settings applied. Theme colours were left unchanged.' -ForegroundColor Green
        Write-Host ('Original settings backup: ' + $backupFile) -ForegroundColor DarkGray
        try { & rundll32.exe user32.dll,UpdatePerUserSystemParameters | Out-Null } catch {}
    } catch { Write-Host ('Could not apply visual tune: ' + $_.Exception.Message) -ForegroundColor Red }
}
function Restore-VisualTune {
    Write-Header 'RESTORE VISUAL SETTINGS'
    $backupFile = Get-VisualTuneBackupPath
    if (-not (Test-Path -LiteralPath $backupFile)) { Write-Host 'No saved visual settings were found. Nothing to restore.' -ForegroundColor Yellow; return }
    try {
        $snapshot = @(Import-Clixml -LiteralPath $backupFile -ErrorAction Stop)
        foreach ($entry in $snapshot) {
            if ($entry.Exists) {
                if (-not (Test-Path -LiteralPath $entry.Path)) { New-Item -Path $entry.Path -Force | Out-Null }
                $kind = if ($entry.Value -is [int] -or $entry.Value -is [long]) { 'DWord' } else { 'String' }
                New-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $entry.Value -PropertyType $kind -Force | Out-Null
            } else {
                try { Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue } catch {}
            }
        }
        Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue
        try { & rundll32.exe user32.dll,UpdatePerUserSystemParameters | Out-Null } catch {}
        Write-Host 'Your previous visual settings have been restored.' -ForegroundColor Green
    } catch { Write-Host ('Could not restore visual settings: ' + $_.Exception.Message) -ForegroundColor Red }
}
function Get-StartupEntries {
    $profile = Get-InteractiveProfile
    if (-not $profile.LocalPath -or -not $profile.SID) { return @() }
    $entries = @()
    $runPath = 'Registry::HKEY_USERS\' + $profile.SID + '\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path -LiteralPath $runPath) {
        try {
            $key = Get-Item -LiteralPath $runPath -ErrorAction Stop
            foreach ($name in $key.GetValueNames()) {
                try {
                    $kind = $key.GetValueKind($name).ToString()
                    if ($kind -notin @('String','ExpandString')) { continue }
                    $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $combined = [string]$name + ' ' + [string]$value
                    $protected = ($combined -match '(?i)(viber|outlook|express.?vpn|nordvpn|\bvpn\b|vmware|avro|keyboard|anydesk|teamviewer|ultraviewer|rustdesk|onedrive|googledrive|google drive|browser.?lock|lock.?browser|defender|antivirus|securityhealth|realtek|audio|touchpad|synaptics|intel|nvidia|amd)')
                    $entries += [pscustomobject]@{ Kind='Registry'; Name=[string]$name; Value=[string]$value; ValueKind=$kind; Path=$runPath; Protected=$protected; Detail=[string]$value }
                } catch {}
            }
        } catch { Write-Host ('Could not read user startup settings: ' + $_.Exception.Message) -ForegroundColor Yellow }
    }

    $startupFolder = Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
    if (Test-Path -LiteralPath $startupFolder) {
        try {
            foreach ($file in (Get-ChildItem -LiteralPath $startupFolder -File -Filter '*.lnk' -Force -ErrorAction Stop)) {
                $protected = ($file.Name -match '(?i)(viber|outlook|express.?vpn|nordvpn|vpn|vmware|avro|keyboard|anydesk|teamviewer|ultraviewer|rustdesk|onedrive|googledrive|google drive|browser.?lock|lock.?browser|defender|antivirus|security|realtek|audio|touchpad|synaptics|intel|nvidia|amd)')
                $entries += [pscustomobject]@{ Kind='File'; Name=$file.BaseName; Value=$file.FullName; ValueKind=''; Path=$file.FullName; Protected=$protected; Detail=$file.FullName }
            }
        } catch { Write-Host ('Could not read Startup folder: ' + $_.Exception.Message) -ForegroundColor Yellow }
    }
    return @($entries)
}
function Get-StartupBackupRoot {
    $profile = Get-InteractiveProfile
    if (-not $profile.LocalPath) { return $null }
    return (Join-Path $profile.LocalPath 'AppData\Local\Office-PC-Care-Toolkit\StartupBackup')
}
function Show-StartupEntries {
    Write-Header 'STARTUP APPS - WHAT OPENS WITH WINDOWS'
    Write-Host 'Only your Windows user startup items are listed. System services are not changed.' -ForegroundColor DarkGray
    Write-Host 'VPN, Viber, Outlook, VMware and security/driver items are protected from this tool.' -ForegroundColor Green
    $entries = @(Get-StartupEntries)
    if ($entries.Count -eq 0) { Write-Host 'No supported startup items were found, or the user profile could not be read.' -ForegroundColor Yellow; return }
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $label = if ($entries[$i].Protected) { '[KEEP]' } else { '[OPTIONAL]' }
        $colour = if ($entries[$i].Protected) { 'DarkGray' } else { 'Green' }
        Write-Host (('{0,2}. {1,-28} {2}' -f ($i + 1), $entries[$i].Name, $label)) -ForegroundColor $colour
    }
    Write-Host ''
    Write-Host 'Optional items can be disabled one at a time. Changes apply at next sign-in.' -ForegroundColor Cyan
}
function Disable-OneStartupEntry {
    Write-Header 'DISABLE ONE STARTUP APP'
    $profile = Get-InteractiveProfile
    if (-not $profile.LocalPath) { Write-Host 'Could not identify the signed-in Windows user. Nothing was changed.' -ForegroundColor Red; return }
    $entries = @(Get-StartupEntries | Where-Object { -not $_.Protected })
    if ($entries.Count -eq 0) { Write-Host 'No optional startup items are available to disable.' -ForegroundColor Yellow; return }
    Write-Host 'Choose only apps you do not need immediately after Windows starts.' -ForegroundColor Cyan
    Write-Host 'Do NOT disable anything you do not recognise.' -ForegroundColor Yellow
    for ($i = 0; $i -lt $entries.Count; $i++) {
        Write-Host (('{0,2}. {1}' -f ($i + 1), $entries[$i].Name)) -ForegroundColor Green
    }
    $raw = Read-Host 'Enter the number to disable (0 = cancel)'
    if ($raw -eq '0') { Write-Host 'Cancelled. No startup item was changed.' -ForegroundColor Yellow; return }
    $selectedNumber = 0
    if (-not [int]::TryParse($raw, [ref]$selectedNumber) -or $selectedNumber -lt 1 -or $selectedNumber -gt $entries.Count) {
        Write-Host 'Invalid number. Nothing was changed.' -ForegroundColor Yellow; return
    }
    $entry = $entries[$selectedNumber - 1]
    Write-MajorWarning ('This prevents ' + $entry.Name + ' from starting automatically at the next sign-in. It does not uninstall the app.')
    if (-not (Ask-YesNo ('Disable startup for ' + $entry.Name + '?'))) { Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow; return }

    $backupRoot = Get-StartupBackupRoot
    if (-not $backupRoot) { Write-Host 'Could not find the user profile backup folder.' -ForegroundColor Red; return }
    try { New-Item -ItemType Directory -Path $backupRoot -Force -ErrorAction Stop | Out-Null }
    catch { Write-Host ('Could not create backup folder: ' + $_.Exception.Message) -ForegroundColor Red; return }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $backupFile = Join-Path $backupRoot ('Startup_' + $stamp + '.clixml')
    $record = $null
    if ($entry.Kind -eq 'Registry') {
        $record = [pscustomobject]@{ Kind='Registry'; Path=$entry.Path; Name=$entry.Name; Value=$entry.Value; ValueKind=$entry.ValueKind; SourcePath=''; BackupPath='' }
    } else {
        $disabledFolder = Join-Path $backupRoot 'DisabledShortcuts'
        try { New-Item -ItemType Directory -Path $disabledFolder -Force -ErrorAction Stop | Out-Null }
        catch { Write-Host 'Could not create shortcut backup folder. Nothing was changed.' -ForegroundColor Red; return }
        $backupPath = Join-Path $disabledFolder ($stamp + '_' + [IO.Path]::GetFileName($entry.Path))
        $record = [pscustomobject]@{ Kind='File'; Path=''; Name=$entry.Name; Value=''; ValueKind=''; SourcePath=$entry.Path; BackupPath=$backupPath }
    }
    try { $record | Export-Clixml -LiteralPath $backupFile -Force -ErrorAction Stop }
    catch { Write-Host ('Could not save a restore point: ' + $_.Exception.Message) -ForegroundColor Red; return }

    try {
        if ($entry.Kind -eq 'Registry') {
            Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction Stop
        } else {
            Move-Item -LiteralPath $entry.Path -Destination $record.BackupPath -ErrorAction Stop
        }
        Write-Host ('Startup disabled: ' + $entry.Name) -ForegroundColor Green
        Write-Host 'A backup was saved. The app will not be closed in this session.' -ForegroundColor DarkGray
        Write-Host ('Backup: ' + $backupFile) -ForegroundColor DarkGray
    } catch {
        try { Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue } catch {}
        Write-Host ('Could not disable startup item: ' + $_.Exception.Message) -ForegroundColor Red
    }
}
function Restore-StartupEntries {
    Write-Header 'RESTORE DISABLED STARTUP APPS'
    $backupRoot = Get-StartupBackupRoot
    if (-not $backupRoot -or -not (Test-Path -LiteralPath $backupRoot)) { Write-Host 'No startup backup was found.' -ForegroundColor Yellow; return }
    $backups = @(Get-ChildItem -LiteralPath $backupRoot -File -Filter 'Startup_*.clixml' -ErrorAction SilentlyContinue)
    if ($backups.Count -eq 0) { Write-Host 'No disabled startup items are waiting to be restored.' -ForegroundColor Yellow; return }
    if (-not (Ask-YesNo ('Restore ' + $backups.Count + ' backed-up startup item(s)?'))) { Write-Host 'Cancelled. Nothing was restored.' -ForegroundColor Yellow; return }
    $restored = 0
    $skipped = 0
    foreach ($backup in $backups) {
        try {
            $record = Import-Clixml -LiteralPath $backup.FullName -ErrorAction Stop
            if ($record.Kind -eq 'Registry') {
                if (Test-Path -LiteralPath $record.Path) {
                    $key = Get-Item -LiteralPath $record.Path -ErrorAction Stop
                    if ($key.GetValueNames() -contains [string]$record.Name) { $skipped++; continue }
                } else { New-Item -Path $record.Path -Force -ErrorAction Stop | Out-Null }
                New-ItemProperty -LiteralPath $record.Path -Name $record.Name -Value $record.Value -PropertyType $record.ValueKind -ErrorAction Stop | Out-Null
            } elseif ($record.Kind -eq 'File') {
                if (Test-Path -LiteralPath $record.SourcePath) { $skipped++; continue }
                if (-not (Test-Path -LiteralPath $record.BackupPath)) { $skipped++; continue }
                $parent = Split-Path -Parent $record.SourcePath
                New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
                Move-Item -LiteralPath $record.BackupPath -Destination $record.SourcePath -ErrorAction Stop
            } else { $skipped++; continue }
            Remove-Item -LiteralPath $backup.FullName -Force -ErrorAction SilentlyContinue
            $restored++
        } catch { Write-Host ('Could not restore ' + $backup.Name + ': ' + $_.Exception.Message) -ForegroundColor Yellow; $skipped++ }
    }
    Write-Host ('Restored: ' + $restored + '   Skipped: ' + $skipped) -ForegroundColor Green
    Write-Host 'Restored startup items apply the next time the user signs in.' -ForegroundColor Cyan
}
function Show-StartupMenu {
    while ($true) {
        Clear-Host
        Write-Header 'STARTUP APPS - SPEED UP STARTUP'
        Write-Host '  1. Review Startup Apps  [See what opens]'
        Write-Host '  2. Disable One App      [Stop auto-start]'
        Write-Host '  3. Restore Apps         [Undo changes]'
        Write-Host '  0. Back'
        $pick = Read-Host 'Choose a number'
        switch ($pick) {
            '1' { Show-StartupEntries; Wait-Back }
            '2' { Disable-OneStartupEntry; Wait-Back }
            '3' { Restore-StartupEntries; Wait-Back }
            '0' { return }
            default { Write-Host 'Choose 0, 1, 2 or 3.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}
function Show-RamRelief {
    Write-Header 'RAM RELIEF - FIND HEAVY APPS'
    Write-Host 'This does not use a fake RAM cleaner. Windows manages memory automatically.' -ForegroundColor Cyan
    Write-Host 'Close only an app you are not using. Save your work first.' -ForegroundColor Yellow
    $sessionId = 0
    try { $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId } catch {}
    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
    if ($os) {
        $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
        $freeMB = [math]::Round($os.FreePhysicalMemory / 1024, 0)
        Write-Host ("RAM: {0:N0} MB total | {1:N0} MB available" -f $totalMB, $freeMB) -ForegroundColor Cyan
    }
    $protectedPattern = '(?i)^(outlook|viber|vmware-vmx|vmware|vmware-tray|expressvpn|expressvpnservice|nordvpn|nordvpn-service|openvpn|explorer|dwm|winlogon|wininit|csrss|lsass|services|svchost|MsMpEng|SecurityHealthService|spoolsv|powershell|pwsh|cmd|conhost|taskhostw|searchindexer|searchhost|searchprotocolhost|searchfilterhost|applicationframehost|runtimebroker|sihost|ctfmon|shellexperiencehost|startmenuexperiencehost|msedgewebview2)$'
    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId } | Sort-Object WorkingSet64 -Descending | Select-Object -First 10)
    if ($processes.Count -eq 0) { Write-Host 'No user apps were found.' -ForegroundColor Yellow; return }
    Write-Host ''
    Write-Host 'Top memory users:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $processes.Count; $i++) {
        $mb = [math]::Round($processes[$i].WorkingSet64 / 1MB, 0)
        $keep = ($processes[$i].ProcessName -match $protectedPattern)
        $tag = if ($keep) { '[KEEP]' } else { '[APP]' }
        $colour = if ($keep) { 'DarkGray' } else { 'Green' }
        Write-Host (('{0,2}. {1,-24} {2,6:N0} MB  {3}' -f ($i + 1), $processes[$i].ProcessName, $mb, $tag)) -ForegroundColor $colour
    }
    Write-Host ''
    Write-Host 'KEEP items are protected. Outlook, Viber, VPN and VMware will not be closed here.' -ForegroundColor Green
    $raw = Read-Host 'Enter an APP number to close it, or 0 to return'
    if ($raw -eq '0') { return }
    $selectedNumber = 0
    if (-not [int]::TryParse($raw, [ref]$selectedNumber) -or $selectedNumber -lt 1 -or $selectedNumber -gt $processes.Count) {
        Write-Host 'Invalid number. No app was closed.' -ForegroundColor Yellow; return
    }
    $selected = $processes[$selectedNumber - 1]
    if ($selected.ProcessName -match $protectedPattern) {
        Write-Host 'This is a protected Office, VPN, VMware or Windows process. It will not be closed.' -ForegroundColor Yellow; return
    }
    Write-MajorWarning ('Closing ' + $selected.ProcessName + ' may close all its windows and lose unsaved work.')
    if (-not (Ask-YesNo ('Try to close ' + $selected.ProcessName + '?'))) { Write-Host 'Cancelled. App was not changed.' -ForegroundColor Yellow; return }
    [void](Close-AppRobust -ProcessName $selected.ProcessName -AppLabel $selected.ProcessName -ForceWarning 'All windows of this app may close. Unsaved work or browser tabs may be lost.')
}
function Show-VMwareCare {
    Write-Header 'VMWARE SAFETY - PROTECT YOUR VM'
    Write-Host 'This check does not change VMware settings, services or virtual network adapters.' -ForegroundColor Green
    $vmProcesses = @(Get-Process -Name 'vmware-vmx' -ErrorAction SilentlyContinue)
    $totalVMRam = [int64]0
    foreach ($p in $vmProcesses) { $totalVMRam += [int64]$p.WorkingSet64 }
    if ($vmProcesses.Count -gt 0) {
        Write-Host ('Running VM process count: ' + $vmProcesses.Count) -ForegroundColor Cyan
        Write-Host ("VMware memory currently in use: {0:N0} MB" -f ($totalVMRam / 1MB)) -ForegroundColor Cyan
    } else {
        Write-Host 'No running VMware virtual machine process was found.' -ForegroundColor Green
    }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
        $freeMB = [math]::Round($os.FreePhysicalMemory / 1024, 0)
        Write-Host ("Host RAM: {0:N0} MB total | {1:N0} MB available" -f $totalMB, $freeMB) -ForegroundColor Cyan
        if ($freeMB -lt 1200) { Write-MajorWarning 'Available RAM is low. Avoid opening extra apps while the VM is running.' }
    } catch { Write-Host 'Could not read host RAM information.' -ForegroundColor Yellow }
    try {
        $systemDrive = $env:SystemDrive
        $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $systemDrive) -ErrorAction Stop
        $freeDiskGB = [math]::Round($disk.FreeSpace / 1GB, 1)
        Write-Host ("System drive free space: {0:N1} GB" -f $freeDiskGB) -ForegroundColor Cyan
        if ($freeDiskGB -lt 15) { Write-MajorWarning 'Disk space is low. Free some space before running a VM.' }
    } catch { Write-Host 'Could not read system drive space.' -ForegroundColor Yellow }
    if ($vmProcesses.Count -gt 0) {
        Write-MajorWarning 'Do not run Drive Optimization or large Windows repairs while a VM is busy.'
        Write-Host 'Close the virtual machine normally before heavy maintenance. Never delete VM files or disable VMware services.' -ForegroundColor Yellow
    } else {
        Write-Host 'For best performance, close the VM normally before heavy disk maintenance.' -ForegroundColor DarkGray
    }
}
function Invoke-OneClickSpeedOptimization {
    Write-Header 'ONE-CLICK SPEED OPTIMIZATION'
    Write-Host 'Step 1: Apply light Windows visual settings.' -ForegroundColor Cyan
    Write-Host 'Step 2: Review optional apps that start with Windows.' -ForegroundColor Cyan
    Write-Host 'Outlook, Viber, NordVPN, ExpressVPN, VMware, Windows security and driver items are protected.' -ForegroundColor Green
    Set-LowEndVisualTune

    $entries = @(Get-StartupEntries | Where-Object { -not $_.Protected })
    $startupBackupRoot = Get-StartupBackupRoot
    $startupBackups = if ($startupBackupRoot -and (Test-Path -LiteralPath $startupBackupRoot)) { @(Get-ChildItem -LiteralPath $startupBackupRoot -File -Filter 'Startup_*.clixml' -ErrorAction SilentlyContinue) } else { @() }
    if ($entries.Count -eq 0) {
        if ($startupBackups.Count -gt 0) {
            Write-Host 'No optional startup apps remain. Earlier startup changes can be restored.' -ForegroundColor Cyan
            if ((Read-Host 'Type R to restore previously disabled startup apps, or press Enter to skip') -match '^(?i:R)$') { Restore-StartupEntries }
        } else {
            Write-Host 'No optional startup items were found. Basic speed settings are complete.' -ForegroundColor Green
        }
        return
    }
    Write-Host ''
    Write-Host 'Optional startup apps (only choose apps you recognise and do not need at sign-in):' -ForegroundColor Cyan
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $detail = [string]$entries[$i].Detail
        if ($detail.Length -gt 92) { $detail = $detail.Substring(0, 89) + '...' }
        Write-Host (('{0,2}. {1,-25} {2}' -f ($i + 1), $entries[$i].Name, $detail)) -ForegroundColor Green
    }
    Write-Host ''
    Write-Host 'Do not select anything you do not recognise. This will not uninstall apps.' -ForegroundColor Yellow
    $raw = Read-Host 'Enter number(s) to stop auto-start (e.g. 1,3), R = restore, or Enter = skip'
    if ($raw.Trim() -match '^(?i:R)$') { Restore-StartupEntries; return }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host 'Startup settings were left unchanged. Basic speed settings are complete.' -ForegroundColor Green
        return
    }

    $selected = @()
    $invalid = $false
    foreach ($token in ($raw -split '[,;\s]+')) {
        if ([string]::IsNullOrWhiteSpace($token)) { continue }
        $number = 0
        if (-not [int]::TryParse($token, [ref]$number) -or $number -lt 1 -or $number -gt $entries.Count) { $invalid = $true; break }
        if (-not ($selected | Where-Object { $_.Index -eq $number })) {
            $selected += [pscustomobject]@{ Index = $number; Entry = $entries[$number - 1] }
        }
    }
    if ($invalid -or $selected.Count -eq 0) {
        Write-Host 'Invalid selection. Startup settings were not changed.' -ForegroundColor Yellow
        return
    }
    Write-Host ''
    Write-Host 'Selected apps:' -ForegroundColor Cyan
    foreach ($item in $selected) { Write-Host ('  - ' + $item.Entry.Name) -ForegroundColor Yellow }
    if (-not (Ask-YesNo 'Stop these selected apps from starting automatically?')) {
        Write-Host 'Startup settings were left unchanged.' -ForegroundColor Yellow
        return
    }

    $backupRoot = Get-StartupBackupRoot
    if (-not $backupRoot) { Write-Host 'Could not find the user backup folder. Startup settings were not changed.' -ForegroundColor Red; return }
    try { New-Item -ItemType Directory -Path $backupRoot -Force -ErrorAction Stop | Out-Null }
    catch { Write-Host 'Could not create the backup folder. Startup settings were not changed.' -ForegroundColor Red; return }

    $done = 0
    foreach ($item in $selected) {
        $entry = $item.Entry
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
        $backupFile = Join-Path $backupRoot ('Startup_' + $stamp + '_' + $item.Index + '.clixml')
        try {
            if ($entry.Kind -eq 'Registry') {
                $record = [pscustomobject]@{ Kind='Registry'; Path=$entry.Path; Name=$entry.Name; Value=$entry.Value; ValueKind=$entry.ValueKind; SourcePath=''; BackupPath='' }
            } elseif ($entry.Kind -eq 'File') {
                $disabledFolder = Join-Path $backupRoot 'DisabledShortcuts'
                New-Item -ItemType Directory -Path $disabledFolder -Force -ErrorAction Stop | Out-Null
                $backupPath = Join-Path $disabledFolder ($stamp + '_' + [IO.Path]::GetFileName($entry.Path))
                $record = [pscustomobject]@{ Kind='File'; Path=''; Name=$entry.Name; Value=''; ValueKind=''; SourcePath=$entry.Path; BackupPath=$backupPath }
            } else { continue }
            $record | Export-Clixml -LiteralPath $backupFile -Force -ErrorAction Stop
            if ($entry.Kind -eq 'Registry') {
                Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction Stop
            } else {
                Move-Item -LiteralPath $entry.Path -Destination $record.BackupPath -ErrorAction Stop
            }
            $done++
            Write-Host ('Auto-start disabled: ' + $entry.Name) -ForegroundColor Green
        } catch {
            try { Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue } catch {}
            Write-Host ('Could not change ' + $entry.Name + ': ' + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    Write-Host ('Startup apps disabled: ' + $done) -ForegroundColor Green
    Write-Host 'Changes apply the next time the user signs in. Backups are kept for IT restore.' -ForegroundColor DarkGray
}

function Invoke-WindowsFileRepair {
    Write-Header 'REPAIR WINDOWS FILES'
    Write-MajorWarning 'These jobs can take time and use CPU/disk. Run outside busy office hours.'
    if (@(Get-Process -Name 'vmware-vmx' -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-MajorWarning 'A VMware virtual machine is running. Windows repair may make the VM slow.'
        if (-not (Ask-YesNo 'Continue while VMware is running?')) { Write-Host 'Close the VM normally and run this later.' -ForegroundColor Yellow; return }
    }
    Write-Host 'Uses Windows repair files already on this PC. No website or tool download is used.' -ForegroundColor DarkGray
    Write-Host 'Some modified Windows builds may not have all repair source files.' -ForegroundColor Yellow
    if (-not (Ask-YesNo 'Run Windows repair now?')) { Write-Host 'Cancelled. No repair was started.' -ForegroundColor Yellow; return }
    Write-Host ''
    Write-Host '[1/2] Repair Windows image (local source only)...' -ForegroundColor Cyan
    & dism.exe /Online /Cleanup-Image /RestoreHealth /LimitAccess
    $dismCode = $LASTEXITCODE
    Write-Host ''
    Write-Host '[2/2] Check and repair protected system files...' -ForegroundColor Cyan
    & sfc.exe /scannow
    $sfcCode = $LASTEXITCODE
    Write-Host ''
    if ($dismCode -eq 0 -and $sfcCode -eq 0) { Write-Host 'Windows repair commands completed successfully.' -ForegroundColor Green }
    else {
        Write-Host 'One or more repair commands reported a problem. Read the results above.' -ForegroundColor Yellow
        Write-Host 'DISM may need a matching Windows installation source if this PC uses a modified build.' -ForegroundColor Yellow
    }
    Write-Host 'Restart later if Windows asks for it.' -ForegroundColor Yellow
}
function Invoke-AdvancedWindowsRepairCleanup {
    Write-Header 'WINDOWS REPAIR + CLEANUP'
    Write-MajorWarning 'These jobs can take time and use CPU/disk. Run outside busy office hours.'
    Write-Host 'Runs in order: DISM repair, SFC file repair, then old component cleanup.' -ForegroundColor Cyan
    Write-Host 'Uses local Windows repair sources only. Modified Windows builds may report source errors.' -ForegroundColor Yellow
    Write-Host 'No /ResetBase is used. Personal files, browser data and Office data are not targeted.' -ForegroundColor Green
    if (@(Get-Process -Name 'vmware-vmx' -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-MajorWarning 'A VMware virtual machine is running. This maintenance can make it slow.'
        if (-not (Ask-YesNo 'Continue while VMware is running?')) { Write-Host 'Cancelled. Close the VM normally and run later.' -ForegroundColor Yellow; return }
    }
    if (-not (Ask-YesNo 'Run Windows repair and cleanup now?')) { Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow; return }

    Write-Host ''
    Write-Host '[1/3] Repair Windows component image...' -ForegroundColor Cyan
    & dism.exe /Online /Cleanup-Image /RestoreHealth /LimitAccess
    $dismCode = $LASTEXITCODE

    Write-Host ''
    Write-Host '[2/3] Scan and repair protected Windows files...' -ForegroundColor Cyan
    & sfc.exe /scannow
    $sfcCode = $LASTEXITCODE

    Write-Host ''
    Write-Host '[3/3] Remove replaced Windows component files...' -ForegroundColor Cyan
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup
    $cleanupCode = $LASTEXITCODE

    Write-Host ''
    Write-Host 'RESULT SUMMARY' -ForegroundColor Cyan
    Write-Host ('DISM repair: ' + $(if ($dismCode -eq 0) { 'SUCCESS' } else { 'Exit code ' + $dismCode })) -ForegroundColor $(if ($dismCode -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host ('SFC repair: ' + $(if ($sfcCode -eq 0) { 'SUCCESS' } else { 'Exit code ' + $sfcCode })) -ForegroundColor $(if ($sfcCode -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host ('Component cleanup: ' + $(if ($cleanupCode -eq 0) { 'SUCCESS' } else { 'Exit code ' + $cleanupCode })) -ForegroundColor $(if ($cleanupCode -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host 'A successful command means that command completed; it does not guarantee every Windows issue is fixed.' -ForegroundColor DarkGray
    Write-Host 'Restart later only if Windows requests it.' -ForegroundColor Yellow
}

function Invoke-ComponentCleanup {
    Write-Header 'CLEAN OLD WINDOWS COMPONENTS'
    Write-MajorWarning 'This job can take time and use CPU/disk. Run outside busy office hours.'
    if (@(Get-Process -Name 'vmware-vmx' -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-MajorWarning 'A VMware virtual machine is running. Component cleanup may slow the VM.'
        if (-not (Ask-YesNo 'Continue while VMware is running?')) { Write-Host 'Close the VM normally and run this later.' -ForegroundColor Yellow; return }
    }
    Write-Host 'Removes replaced Windows component versions from the system component store.' -ForegroundColor DarkGray
    Write-Host 'It does NOT clean Downloads, browser files, personal files or ordinary app temp files.' -ForegroundColor DarkGray
    Write-Host 'DISM may not show an MB-freed total. A successful completion message means the cleanup command finished.' -ForegroundColor Cyan
    Write-Host 'This does NOT use /ResetBase, so existing update uninstall options are not deliberately removed.' -ForegroundColor Green
    if (-not (Ask-YesNo 'Clean old Windows component files now?')) { Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow; return }
    Write-Host ''
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup
    $cleanupCode = $LASTEXITCODE
    Write-Host ''
    if ($cleanupCode -eq 0) {
        Write-Host 'SUCCESS: Windows component cleanup completed.' -ForegroundColor Green
        Write-Host 'Your earlier result ("The operation completed successfully") already confirmed success.' -ForegroundColor Green
        Write-Host 'Checking remaining component-store status...' -ForegroundColor Cyan
        & dism.exe /Online /Cleanup-Image /AnalyzeComponentStore
        if ($LASTEXITCODE -eq 0) {
            Write-Host 'Component-store check completed. Review the report above for cleanup recommendation and size.' -ForegroundColor Green
        } else {
            Write-Host 'Cleanup succeeded; the additional size report was unavailable.' -ForegroundColor Yellow
        }
    } else {
        Write-Host ('CLEANUP FAILED: DISM returned exit code ' + $cleanupCode + '. Read the DISM error above.') -ForegroundColor Red
    }
}
function Invoke-DriveCare {
    Write-Header 'DRIVE CARE - SSD / HDD'
    Write-MajorWarning 'This job can take time and use CPU/disk. Run outside busy office hours.'
    Write-Host 'Windows chooses the suitable method: TRIM for SSD or defrag for HDD.' -ForegroundColor DarkGray
    Write-Host 'Run this only when no VM is actively using a busy virtual disk.' -ForegroundColor Yellow
    $runningVm = @(Get-Process -Name 'vmware-vmx' -ErrorAction SilentlyContinue)
    if ($runningVm.Count -gt 0) {
        Write-MajorWarning 'VMware is running. Drive optimization can make the VM slow while it works.'
        if (-not (Ask-YesNo 'A VMware VM is running. Continue anyway?')) { Write-Host 'Close the VM and run drive care later.' -ForegroundColor Yellow; return }
    }
    if (-not (Ask-YesNo 'Optimize fixed drives now?')) { Write-Host 'Cancelled. No drive optimization was started.' -ForegroundColor Yellow; return }
    $volumes = @()
    try { $volumes = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }) } catch {}
    if ($volumes.Count -eq 0) {
        try { $volumes = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | Where-Object { $_.DeviceID } | ForEach-Object { [pscustomobject]@{ DriveLetter = $_.DeviceID.TrimEnd(':') } }) } catch {}
    }
    if ($volumes.Count -eq 0) { Write-Host 'No fixed drives were found. Nothing was changed.' -ForegroundColor Yellow; return }
    foreach ($volume in $volumes) {
        Write-Host ("Working on {0}: ..." -f $volume.DriveLetter) -ForegroundColor Cyan
        try {
            if (Get-Command Optimize-Volume -ErrorAction SilentlyContinue) { Optimize-Volume -DriveLetter $volume.DriveLetter -Verbose -ErrorAction Stop | Out-Host }
            else { & defrag.exe ($volume.DriveLetter + ':') /O /U | Out-Host }
            Write-Host ("{0}: completed." -f $volume.DriveLetter) -ForegroundColor Green
        } catch { Write-Host ("{0}: skipped - {1}" -f $volume.DriveLetter, $_.Exception.Message) -ForegroundColor Yellow }
    }
    Write-Host 'Drive care finished.' -ForegroundColor Green
}
function Invoke-SafeAction([scriptblock]$Action) {
    try {
        & $Action
    } catch {
        $message = $_.Exception.Message
        Write-Host ''
        Write-Host ('The action stopped safely: ' + $message) -ForegroundColor Red
        Write-Host 'No further changes were attempted. Check the log for details.' -ForegroundColor Yellow
        try {
            if ($script:LogFile) {
                Add-Content -LiteralPath $script:LogFile -Value (($_ | Format-List * -Force | Out-String)) -ErrorAction SilentlyContinue
            }
        } catch {}
        Wait-Back
    }
}


# =====================================================================
# v12 additions: problem-first menus, tracked changes with full undo,
# full speed setup, Windows Update / Edge control, Chrome memory saver,
# Viber auto-start, Word / Excel / Outlook fixes, IT report, Auto Care.
# =====================================================================
$script:ToolRoot     = Join-Path $env:ProgramData 'Office-PC-Care-Toolkit'
$script:InstalledBat = Join-Path $script:ToolRoot 'PC-Care-Toolkit.bat'
$script:UndoFile     = Join-Path $script:ToolRoot 'Backup\undo-v12.clixml'
$script:SetupMarker  = Join-Path $script:ToolRoot 'setup-v12.done'
$script:TaskName     = 'Office PC Care Toolkit'
$script:OneShotTask  = 'Office PC Care Toolkit - One Shot'
$script:ViberTask    = 'Office PC Care Toolkit - Viber First'
$script:Mode         = ([string]$env:PCTOOLKIT_MODE).Trim().ToLowerInvariant()

function Write-Done([string]$Text) { Write-Host ('  [DONE] ' + $Text) -ForegroundColor Green }
function Write-Skip([string]$Text) { Write-Host ('  [SKIP] ' + $Text) -ForegroundColor Yellow }
function Write-Step([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Note([string]$Text) { Write-Host ('  ' + $Text) -ForegroundColor DarkGray }

function Show-ActionInfo([string]$Does, [string]$Safe, [string]$Lose, [string]$Time) {
    Write-Host ''
    Write-Host ('  What this does : ' + $Does) -ForegroundColor Cyan
    Write-Host ('  What stays safe: ' + $Safe) -ForegroundColor Green
    Write-Host ('  You may lose   : ' + $Lose) -ForegroundColor Yellow
    Write-Host ('  Time           : ' + $Time) -ForegroundColor Gray
    Write-Host ''
}
function Confirm-Action([string]$Does, [string]$Safe, [string]$Lose, [string]$Time, [string]$Question = 'Continue?') {
    Show-ActionInfo $Does $Safe $Lose $Time
    if (Ask-YesNo $Question) { return $true }
    Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow
    return $false
}
function Get-UserHive {
    $profile = Get-InteractiveProfile
    if ($profile.SID) { return ('Registry::HKEY_USERS\' + $profile.SID) }
    return $null
}

# ---------------------------------------------------------------------
# Tracked changes. The first original value of every setting is saved
# once, so "Undo" always returns the PC to how it was before v12.
# ---------------------------------------------------------------------
function Get-UndoState {
    if (Test-Path -LiteralPath $script:UndoFile) {
        try {
            $s = Import-Clixml -LiteralPath $script:UndoFile -ErrorAction Stop
            if ($s -is [hashtable]) {
                if (-not $s.ContainsKey('Registry')) { $s['Registry'] = @{} }
                if (-not $s.ContainsKey('Extra')) { $s['Extra'] = @{} }
                return $s
            }
        } catch {}
    }
    return @{ Registry = @{}; Extra = @{} }
}
function Save-UndoState([hashtable]$State) {
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:UndoFile) -Force | Out-Null
        $State | Export-Clixml -LiteralPath $script:UndoFile -Force -ErrorAction Stop
    } catch { Write-Note ('Could not save undo information: ' + $_.Exception.Message) }
}
function Set-UndoFlag([string]$Name, $Value) { $s = Get-UndoState; $s.Extra[$Name] = $Value; Save-UndoState $s }
function Get-UndoFlag([string]$Name) { $s = Get-UndoState; if ($s.Extra.ContainsKey($Name)) { return $s.Extra[$Name] }; return $null }
function Add-UndoListItem([string]$Name, $Item) {
    $s = Get-UndoState
    $list = @()
    if ($s.Extra.ContainsKey($Name) -and $s.Extra[$Name]) { $list = @($s.Extra[$Name]) }
    $s.Extra[$Name] = @($list + $Item)
    Save-UndoState $s
}
function Get-RegValueRaw([string]$Path, [string]$Name) {
    $r = @{ Exists = $false; Value = $null; Kind = '' }
    try {
        if (Test-Path -LiteralPath $Path) {
            $key = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($key.GetValueNames() -contains $Name) {
                $r.Exists = $true
                $r.Kind = $key.GetValueKind($Name).ToString()
                $r.Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }
    } catch {}
    return $r
}
function Save-RegOriginal([string]$Path, [string]$Name) {
    $state = Get-UndoState
    $id = $Path + '|' + $Name
    if (-not $state.Registry.ContainsKey($id)) {
        $orig = Get-RegValueRaw -Path $Path -Name $Name
        $state.Registry[$id] = @{ Path = $Path; Name = $Name; Exists = $orig.Exists; Value = $orig.Value; Kind = $orig.Kind }
        Save-UndoState $state
    }
}
function Set-TrackedReg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    try {
        Save-RegOriginal -Path $Path -Name $Name
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Note ('Could not change ' + $Name + ': ' + $_.Exception.Message)
        return $false
    }
}
function Remove-TrackedReg([string]$Path, [string]$Name) {
    try {
        Save-RegOriginal -Path $Path -Name $Name
        Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $true
    } catch { return $false }
}
function Set-TrackedServiceStart([string]$Name, [int]$Start) {
    $path = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\' + $Name
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $ok = Set-TrackedReg -Path $path -Name 'Start' -Value $Start -Type 'DWord'
    if (-not $ok) {
        $word = switch ($Start) { 2 { 'auto' } 3 { 'demand' } default { 'disabled' } }
        & sc.exe config $Name start= $word 2>&1 | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
    }
    if ($Start -eq 4) { try { Stop-Service -Name $Name -Force -ErrorAction Stop } catch {} }
    return $ok
}
function Get-TaskService {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    return $svc
}
function Disable-TrackedTasks([string]$FolderPath, [string]$NameLike = '*') {
    $count = 0
    try { $folder = (Get-TaskService).GetFolder($FolderPath) } catch { return 0 }
    foreach ($task in @($folder.GetTasks(1))) {
        if ($task.Name -notlike $NameLike) { continue }
        try {
            if ($task.Enabled) {
                $task.Enabled = $false
                Add-UndoListItem -Name 'Tasks' -Item ([string]$task.Path)
                $count++
            }
        } catch {}
    }
    return $count
}
function Restore-RegEntry($Entry) {
    try {
        if ($Entry.Exists) {
            if (-not (Test-Path -LiteralPath $Entry.Path)) { New-Item -Path $Entry.Path -Force -ErrorAction Stop | Out-Null }
            $kind = if ($Entry.Kind) { [string]$Entry.Kind } else { 'String' }
            $value = $Entry.Value
            if ($kind -eq 'Binary') { $value = [byte[]]@($value) }
            elseif ($kind -eq 'MultiString') { $value = [string[]]@($value) }
            New-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -Value $value -PropertyType $kind -Force -ErrorAction Stop | Out-Null
        } elseif (Test-Path -LiteralPath $Entry.Path) {
            Remove-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -ErrorAction SilentlyContinue
        }
        return $true
    } catch { return $false }
}
function Restore-Tracked([scriptblock]$Match) {
    # $Match receives "registryPath|valueName" or "task|\Task\Path"; $null restores everything.
    $state = Get-UndoState
    $ok = 0; $fail = 0
    foreach ($id in @($state.Registry.Keys)) {
        if ($Match -and -not (& $Match $id)) { continue }
        if (Restore-RegEntry $state.Registry[$id]) { $state.Registry.Remove($id); $ok++ } else { $fail++ }
    }
    $keep = @()
    $root = $null
    try { $root = (Get-TaskService).GetFolder('\') } catch {}
    foreach ($taskPath in @($state.Extra['Tasks'])) {
        if (-not $taskPath) { continue }
        if ($Match -and -not (& $Match ('task|' + $taskPath))) { $keep += $taskPath; continue }
        try { $root.GetTask([string]$taskPath).Enabled = $true; $ok++ } catch { $fail++ }
    }
    $state.Extra['Tasks'] = @($keep | Select-Object -Unique)
    Save-UndoState $state
    return [pscustomobject]@{ Ok = $ok; Fail = $fail }
}

# ---------------------------------------------------------------------
# Installed copy + scheduled tasks (Auto Care and SYSTEM one-shot jobs)
# ---------------------------------------------------------------------
function Install-ToolkitCopy {
    New-Item -ItemType Directory -Path $script:ToolRoot -Force | Out-Null
    # Only Administrators and SYSTEM may change the copy that runs as SYSTEM.
    & icacls.exe $script:ToolRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1 | Out-Null
    $source = [string]$env:PCTOOLKIT_FILE
    if ($source -and (Test-Path -LiteralPath $source) -and ($source -ne $script:InstalledBat)) {
        Copy-Item -LiteralPath $source -Destination $script:InstalledBat -Force
    }
    return (Test-Path -LiteralPath $script:InstalledBat)
}
function New-ToolkitTaskDefinition($Service, [string]$Mode) {
    $def = $Service.NewTask(0)
    $def.RegistrationInfo.Description = 'Office PC Care Toolkit: keeps this office PC clean and its settings in place.'
    $def.Settings.Enabled = $true
    $def.Settings.StartWhenAvailable = $true
    $def.Settings.DisallowStartIfOnBatteries = $false
    $def.Settings.StopIfGoingOnBatteries = $false
    $def.Settings.ExecutionTimeLimit = 'PT1H'
    $def.Settings.MultipleInstances = 2
    $def.Principal.RunLevel = 1
    $action = $def.Actions.Create(0)
    $action.Path = Join-Path $env:WINDIR 'System32\cmd.exe'
    $action.Arguments = '/d /c ""' + $script:InstalledBat + '" ' + $Mode + '"'
    return $def
}
function Register-AutoCareTask {
    if (-not (Install-ToolkitCopy)) { Write-Skip 'Could not copy the toolkit to ProgramData. Auto Care was not set up.'; return $false }
    try {
        $svc = Get-TaskService
        $def = New-ToolkitTaskDefinition -Service $svc -Mode 'auto'
        # 10 minutes after the PC starts.
        $boot = $def.Triggers.Create(8)
        $boot.Delay = 'PT10M'
        # Daily at 3:30 PM and 8:30 PM Bangladesh time. The "+06:00" offset fixes the real
        # moment, so it is the same on PCs set to UK time or BD time, and UK summer time
        # changes do not move it. The PC clock and time zone are never changed.
        $bdToday = (Get-Date).ToUniversalTime().AddHours(6).ToString('yyyy-MM-dd')
        foreach ($bdTime in @('15:30:00', '20:30:00')) {
            $daily = $def.Triggers.Create(2)
            $daily.StartBoundary = $bdToday + 'T' + $bdTime + '+06:00'
            $daily.DaysInterval = 1
        }
        [void]$svc.GetFolder('\').RegisterTaskDefinition($script:TaskName, $def, 6, 'SYSTEM', $null, 5)
        return $true
    } catch { Write-Skip ('Auto Care task could not be created: ' + $_.Exception.Message); return $false }
}
function Unregister-AutoCareTask {
    try { (Get-TaskService).GetFolder('\').DeleteTask($script:TaskName, 0) } catch {}
}
function Invoke-AsSystem([string]$Mode, [int]$TimeoutSeconds = 900) {
    # Some Windows Update parts can only be changed by the SYSTEM account.
    if (-not (Install-ToolkitCopy)) { throw 'Could not copy the toolkit to ProgramData.' }
    $svc = Get-TaskService
    $root = $svc.GetFolder('\')
    $def = New-ToolkitTaskDefinition -Service $svc -Mode $Mode
    $def.Settings.Hidden = $true
    $task = $root.RegisterTaskDefinition($script:OneShotTask, $def, 6, 'SYSTEM', $null, 5)
    [void]$task.Run($null)
    Start-Sleep -Seconds 3
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $result = $null
    while ((Get-Date) -lt $deadline) {
        $current = $root.GetTask($script:OneShotTask)
        if ($current.State -ne 4) { $result = $current.LastTaskResult; break }
        Start-Sleep -Seconds 2
    }
    try { $root.DeleteTask($script:OneShotTask, 0) } catch {}
    return $result
}

# ---------------------------------------------------------------------
# Windows Update
# ---------------------------------------------------------------------
function Set-WindowsUpdateOff {
    $policy = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    [void](Set-TrackedReg ($policy + '\AU') 'NoAutoUpdate' 1)
    [void](Set-TrackedReg ($policy + '\AU') 'AUOptions' 1)
    [void](Set-TrackedReg $policy 'DisableOSUpgrade' 1)
    [void](Set-TrackedReg $policy 'ExcludeWUDriversInQualityUpdate' 1)
    foreach ($svc in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')) { [void](Set-TrackedServiceStart -Name $svc -Start 4) }
    $n = 0
    $n += Disable-TrackedTasks '\Microsoft\Windows\WindowsUpdate'
    $n += Disable-TrackedTasks '\Microsoft\Windows\UpdateOrchestrator'
    $n += Disable-TrackedTasks '\Microsoft\Windows\WaaSMedic'
    Set-UndoFlag 'UpdatesOff' $true
    $wu = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
    if ($wu -and $wu.StartType -eq 'Disabled') { Write-Done 'Windows Update is OFF.' } else { Write-Skip 'Windows Update could not be fully turned off. Auto Care will try again.' }
}
function Test-WindowsUpdateMatch([string]$Id) {
    return ($Id -match '(?i)\\Policies\\Microsoft\\Windows\\WindowsUpdate|\\Services\\(wuauserv|UsoSvc|WaaSMedicSvc)\||^task\|\\Microsoft\\Windows\\(WindowsUpdate|UpdateOrchestrator|WaaSMedic)\\')
}
function Set-WindowsUpdateOn {
    $r = Restore-Tracked { param($id) Test-WindowsUpdateMatch $id }
    Set-UndoFlag 'UpdatesOff' $false
    try { Set-Service -Name 'wuauserv' -StartupType Manual -ErrorAction Stop } catch {}
    Write-Done ('Windows Update is back ON. Settings restored: ' + $r.Ok)
}
function Update-DefenderSignatures {
    $mp = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    if (-not (Test-Path -LiteralPath $mp)) { Write-Skip 'Microsoft Defender was not found.'; return }
    & $mp -SignatureUpdate -MMPC 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Done 'Virus definitions updated.' } else { Write-Skip 'Virus definitions could not update now (internet or VPN may be off).' }
}

# ---------------------------------------------------------------------
# Browsers: Chrome first, Firefox if Chrome is missing. Edge off.
# ---------------------------------------------------------------------
function Get-PreferredBrowser {
    $roots = @('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Clients\StartMenuInternet',
               'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Clients\StartMenuInternet')
    $hive = Get-UserHive
    if ($hive) { $roots += ($hive + '\Software\Clients\StartMenuInternet') }
    $found = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $name = $key.PSChildName
            $kind = if ($name -match '(?i)chrome') { 'Chrome' } elseif ($name -match '(?i)firefox') { 'Firefox' } else { '' }
            if (-not $kind) { continue }
            $urls = $key.PSPath + '\Capabilities\URLAssociations'
            $files = $key.PSPath + '\Capabilities\FileAssociations'
            $http = [string](Get-RegValueRaw $urls 'http').Value
            if (-not $http) { continue }
            $command = [string](Get-RegValueRaw ($key.PSPath + '\shell\open\command') '').Value
            $exe = ''
            if ($command -match '^"([^"]+)"') { $exe = $Matches[1] } elseif ($command) { $exe = ($command -split ' ')[0] }
            if ($exe -and -not (Test-Path -LiteralPath $exe)) { continue }
            $https = [string](Get-RegValueRaw $urls 'https').Value
            $html = [string](Get-RegValueRaw $files '.html').Value
            $found += [pscustomobject]@{ Kind = $kind; Http = $http; Https = $(if ($https) { $https } else { $http }); Html = $(if ($html) { $html } else { $http }); Exe = $exe }
        }
    }
    $chrome = $found | Where-Object { $_.Kind -eq 'Chrome' } | Select-Object -First 1
    if ($chrome) { return $chrome }
    return ($found | Where-Object { $_.Kind -eq 'Firefox' } | Select-Object -First 1)
}
function Set-DefaultBrowserPolicy($Browser) {
    $app = if ($Browser.Kind -eq 'Chrome') { 'Google Chrome' } else { 'Firefox' }
    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<DefaultAssociations>
  <Association Identifier=".htm" ProgId="$($Browser.Html)" ApplicationName="$app" />
  <Association Identifier=".html" ProgId="$($Browser.Html)" ApplicationName="$app" />
  <Association Identifier="http" ProgId="$($Browser.Http)" ApplicationName="$app" />
  <Association Identifier="https" ProgId="$($Browser.Https)" ApplicationName="$app" />
</DefaultAssociations>
"@
    New-Item -ItemType Directory -Path $script:ToolRoot -Force | Out-Null
    $file = Join-Path $script:ToolRoot 'DefaultBrowser.xml'
    Set-Content -LiteralPath $file -Value $xml -Encoding UTF8
    [void](Set-TrackedReg 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\System' 'DefaultAssociationsConfiguration' $file 'String')
    Write-Done ($app + ' will be the default browser from the next sign-in.')
}
function Set-EdgeOff {
    $browser = Get-PreferredBrowser
    if (-not $browser) { Write-Skip 'Edge was NOT turned off: Chrome or Firefox is not installed on this PC.'; return $false }
    Set-DefaultBrowserPolicy $browser
    $ifeo = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\msedge.exe'
    [void](Set-TrackedReg $ifeo 'Debugger' (Join-Path $env:WINDIR 'System32\systray.exe') 'String')
    $edgePolicy = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge'
    [void](Set-TrackedReg $edgePolicy 'StartupBoostEnabled' 0)
    [void](Set-TrackedReg $edgePolicy 'BackgroundModeEnabled' 0)
    foreach ($svc in @('edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')) { [void](Set-TrackedServiceStart -Name $svc -Start 4) }
    [void](Disable-TrackedTasks '\' 'MicrosoftEdgeUpdate*')
    $hive = Get-UserHive
    if ($hive) {
        $run = $hive + '\Software\Microsoft\Windows\CurrentVersion\Run'
        if (Test-Path -LiteralPath $run) {
            foreach ($n in @((Get-Item -LiteralPath $run).GetValueNames())) {
                if ($n -match '(?i)^MicrosoftEdgeAutoLaunch') { [void](Remove-TrackedReg $run $n) }
            }
        }
    }
    Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Set-UndoFlag 'EdgeOff' $true
    Write-Done 'Microsoft Edge is OFF. It will not open or run in the background.'
    return $true
}
function Test-EdgeMatch([string]$Id) {
    return ($Id -match '(?i)msedge\.exe|\\Policies\\Microsoft\\Edge|\\Services\\(edgeupdate|edgeupdatem|MicrosoftEdgeElevationService)\||DefaultAssociationsConfiguration|MicrosoftEdgeAutoLaunch|^task\|\\MicrosoftEdgeUpdate')
}
function Set-EdgeOn {
    $r = Restore-Tracked { param($id) Test-EdgeMatch $id }
    Set-UndoFlag 'EdgeOff' $false
    Write-Done ('Microsoft Edge is back ON. Settings restored: ' + $r.Ok)
}
# ---------------------------------------------------------------------
# Viber must start with Windows
# ---------------------------------------------------------------------
function Ensure-ViberStartup {
    $profile = Get-InteractiveProfile
    if (-not $profile.SID -or -not $profile.LocalPath) { Write-Skip 'Signed-in user not found. Viber startup was not checked.'; return }
    $exe = Find-ViberExe -ProfilePath $profile.LocalPath
    if (-not $exe) { Write-Skip 'Viber is not installed on this PC.'; return }
    # Viber opens from a sign-in task instead of the normal startup list: the task fires the
    # moment the user signs in (before other startup apps), with higher priority, in a full window.
    $localAppData = Join-Path $profile.LocalPath 'AppData\Local'
    $taskExe = $exe
    if ($exe.StartsWith($localAppData, [StringComparison]::OrdinalIgnoreCase)) { $taskExe = '%LOCALAPPDATA%' + $exe.Substring($localAppData.Length) }
    try {
        $svc = Get-TaskService
        $def = $svc.NewTask(0)
        $def.RegistrationInfo.Description = 'Office PC Care Toolkit: opens Viber first, in a full window, when anyone signs in.'
        $def.Settings.Enabled = $true
        $def.Settings.DisallowStartIfOnBatteries = $false
        $def.Settings.StopIfGoingOnBatteries = $false
        $def.Settings.ExecutionTimeLimit = 'PT0S'
        $def.Settings.MultipleInstances = 2
        $def.Settings.Priority = 5
        $def.Principal.GroupId = 'S-1-5-32-545'
        $def.Principal.RunLevel = 0
        [void]$def.Triggers.Create(9)
        $action = $def.Actions.Create(0)
        # Launcher: start Viber at once in a maximized window, then a hidden helper makes sure the
        # main Viber window really ends up maximized and in front (Viber may ignore the start style).
        $maxScript = Join-Path $script:ToolRoot 'viber-maximize.ps1'
        $launcher = Join-Path $script:ToolRoot 'viber-start.vbs'
        $max = @'
Add-Type -Namespace PcCare -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindowAsync(System.IntPtr h, int c); [DllImport("user32.dll")] public static extern bool IsZoomed(System.IntPtr h); [DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);'
$deadline = (Get-Date).AddSeconds(120)
$done = 0
while ((Get-Date) -lt $deadline -and $done -lt 3) {
    $p = Get-Process -Name 'Viber' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle } | Select-Object -First 1
    if ($p) {
        if (-not [PcCare.Win]::IsZoomed($p.MainWindowHandle)) { [void][PcCare.Win]::ShowWindowAsync($p.MainWindowHandle, 3); [void][PcCare.Win]::SetForegroundWindow($p.MainWindowHandle) }
        else { $done++ }
    }
    Start-Sleep -Milliseconds 700
}
'@
        Set-Content -LiteralPath $maxScript -Value $max -Encoding UTF8
        $vbs = @(
            'Set sh = CreateObject("WScript.Shell")',
            ('sh.Run """" & sh.ExpandEnvironmentStrings("' + $taskExe + '") & """", 3, False'),
            ('sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""' + $maxScript + '""", 0, False')
        )
        Set-Content -LiteralPath $launcher -Value $vbs -Encoding ASCII
        $action.Path = Join-Path $env:WINDIR 'System32\wscript.exe'
        $action.Arguments = '//B //NoLogo "' + $launcher + '"'
        [void]$svc.GetFolder('\').RegisterTaskDefinition($script:ViberTask, $def, 6, $null, $null, 4)
    } catch { Write-Skip ('Viber sign-in task could not be created: ' + $_.Exception.Message); return }
    # Remove Viber's own "start minimized" entries so only the full-window start remains.
    $run = 'Registry::HKEY_USERS\' + $profile.SID + '\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path -LiteralPath $run) {
        $key = Get-Item -LiteralPath $run
        foreach ($n in @($key.GetValueNames())) { if ([string]$key.GetValue($n) -match '(?i)viber\.exe') { [void](Remove-TrackedReg $run $n) } }
    }
    $startupFolder = Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
    foreach ($lnk in @(Get-ChildItem -LiteralPath $startupFolder -Filter '*viber*.lnk' -ErrorAction SilentlyContinue)) {
        $backup = Join-Path $script:ToolRoot ('Backup\StartupShortcuts\' + $lnk.Name)
        try {
            New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
            Move-Item -LiteralPath $lnk.FullName -Destination $backup -Force -ErrorAction Stop
            Add-UndoListItem -Name 'MovedShortcuts' -Item @{ Source = $lnk.FullName; Backup = $backup }
        } catch {}
    }
    Write-Done 'Viber opens first, in a full window, every time someone signs in.'
}

# ---------------------------------------------------------------------
# Full speed setup
# ---------------------------------------------------------------------
function Set-LightVisuals([string]$Hive) {
    [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects') 'VisualFXSetting' 3)
    [void](Set-TrackedReg ($Hive + '\Control Panel\Desktop') 'UserPreferencesMask' ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) 'Binary')
    [void](Set-TrackedReg ($Hive + '\Control Panel\Desktop') 'FontSmoothing' '2' 'String')
    [void](Set-TrackedReg ($Hive + '\Control Panel\Desktop') 'MenuShowDelay' '100' 'String')
    [void](Set-TrackedReg ($Hive + '\Control Panel\Desktop\WindowMetrics') 'MinAnimate' '0' 'String')
    [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced') 'TaskbarAnimations' 0)
    [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced') 'ListviewShadow' 0)
    [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize') 'EnableTransparency' 0)
    [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Windows\DWM') 'EnableAeroPeek' 0)
    try { & rundll32.exe user32.dll,UpdatePerUserSystemParameters | Out-Null } catch {}
}
function Set-BackgroundQuiet([string]$Hive) {
    if ($Hive) {
        [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications') 'GlobalUserDisabled' 1)
        [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Windows\CurrentVersion\Search') 'BackgroundAppGlobalToggle' 0)
        [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Windows\CurrentVersion\Search') 'BingSearchEnabled' 0)
        [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Windows\CurrentVersion\Search') 'CortanaConsent' 0)
        $cdm = $Hive + '\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        foreach ($n in @('SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled','SoftLandingEnabled','SubscribedContent-310093Enabled',
                         'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled')) {
            [void](Set-TrackedReg $cdm $n 0)
        }
        [void](Set-TrackedReg ($Hive + '\System\GameConfigStore') 'GameDVR_Enabled' 0)
        [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Windows\CurrentVersion\GameDVR') 'AppCaptureEnabled' 0)
    }
    $pol = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows'
    [void](Set-TrackedReg ($pol + '\Windows Feeds') 'EnableFeeds' 0)
    [void](Set-TrackedReg ($pol + '\Windows Search') 'DisableWebSearch' 1)
    [void](Set-TrackedReg ($pol + '\Windows Search') 'ConnectedSearchUseWeb' 0)
    [void](Set-TrackedReg ($pol + '\Windows Search') 'AllowCortana' 0)
    [void](Set-TrackedReg ($pol + '\GameDVR') 'AllowGameDVR' 0)
    [void](Set-TrackedReg ($pol + '\CloudContent') 'DisableWindowsConsumerFeatures' 1)
    [void](Set-TrackedReg ($pol + '\DataCollection') 'AllowTelemetry' 0)
    foreach ($svc in @('DiagTrack', 'dmwappushservice')) { [void](Set-TrackedServiceStart -Name $svc -Start 4) }
    # Build 4: Fast Startup is left as Windows had it (PCs are shut down nightly, so it makes power-on faster).
    # Undo the build 1-3 change that turned it off.
    [void](Restore-Tracked { param($id) $id -match 'HiberbootEnabled' })
}
function Set-PowerHighPerformance {
    $high = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    $active = [regex]::Match(((& powercfg.exe /getactivescheme) -join ' '), '[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}')
    if ($active.Success -and -not (Get-UndoFlag 'PowerScheme')) { Set-UndoFlag 'PowerScheme' $active.Value }
    if ((((& powercfg.exe /list) -join ' ')) -notmatch $high) { & powercfg.exe -duplicatescheme $high $high 2>&1 | Out-Null }
    & powercfg.exe /setactive $high 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Skip 'High performance power plan is not available on this PC.'; return }
    $settings = @(
        @('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'),  # USB selective suspend
        @('501a4d13-42af-4429-9fd1-a8218c268e20', 'ee12f906-d277-404b-b6da-e5fa1a576df5'),  # PCI Express power saving
        @('0012ee47-9041-4b5d-9b77-535fba8b1442', '6738e2c4-e8a5-4a42-b16a-e040e769756e'),  # turn off hard disk after
        @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '29f6c1db-86da-48c5-9fdb-f2b67b1f44da')   # sleep after
    )
    foreach ($s in $settings) {
        & powercfg.exe /setacvalueindex $high $s[0] $s[1] 0 2>&1 | Out-Null
        & powercfg.exe /setdcvalueindex $high $s[0] $s[1] 0 2>&1 | Out-Null
    }
    & powercfg.exe /setactive $high 2>&1 | Out-Null
    Write-Done 'High performance power plan is on. The PC will not sleep while working.'
}
function Set-FixedPagefile {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $ramMB = [math]::Round($cs.TotalPhysicalMemory / 1MB)
        if ($ramMB -gt 12288) { Write-Skip 'This PC has more than 12 GB RAM. Memory file left as it is.'; return }
        $drive = $env:SystemDrive
        $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive) -ErrorAction Stop
        if (($disk.FreeSpace / 1GB) -lt 25) { Write-Skip 'C: has less than 25 GB free. Memory file left as it is.'; return }
        if (-not (Get-UndoFlag 'Pagefile')) {
            $saved = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | ForEach-Object { @{ Name = [string]$_.Name; Initial = [int]$_.InitialSize; Maximum = [int]$_.MaximumSize } })
            Set-UndoFlag 'Pagefile' @{ Auto = [bool]$cs.AutomaticManagedPagefile; Settings = $saved }
        }
        if ($cs.AutomaticManagedPagefile) { Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop }
        $name = $drive + '\pagefile.sys'
        $pf = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $name }
        if (-not $pf) { $pf = New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = $name } -ErrorAction Stop }
        Set-CimInstance -InputObject $pf -Property @{ InitialSize = [uint32]8192; MaximumSize = [uint32]12288 } -ErrorAction Stop
        Write-Done 'Memory file on C: set to 8-12 GB, so heavy multitasking does not freeze. Needs one restart.'
    } catch { Write-Skip ('Memory file was not changed: ' + $_.Exception.Message) }
}
function Restore-Pagefile {
    $saved = Get-UndoFlag 'Pagefile'
    if (-not $saved) { return }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($saved.Auto) {
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
        } else {
            foreach ($s in @($saved.Settings)) {
                $pf = Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -ieq $s.Name }
                if ($pf) { Set-CimInstance -InputObject $pf -Property @{ InitialSize = [uint32]$s.Initial; MaximumSize = [uint32]$s.Maximum } }
            }
        }
        Set-UndoFlag 'Pagefile' $null
    } catch { Write-Skip ('Memory file could not be restored: ' + $_.Exception.Message) }
}
function Set-VMwareHostMemory {
    $files = @()
    foreach ($product in @('VMware Workstation', 'VMware Player')) {
        $dir = Join-Path $env:ProgramData ('VMware\' + $product)
        if (Test-Path -LiteralPath $dir) { $files += (Join-Path $dir 'config.ini') }
    }
    if ($files.Count -eq 0) { Write-Skip 'VMware is not installed. VM memory setting skipped.'; return }
    $saved = Get-UndoFlag 'VMwareConfig'
    if (-not ($saved -is [hashtable])) { $saved = @{} }
    $want = [ordered]@{ 'mainMem.useNamedFile' = '"FALSE"'; 'prefvmx.minVmMemPct' = '"100"' }
    foreach ($file in $files) {
        try {
            if (-not $saved.ContainsKey($file)) {
                $saved[$file] = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file) } else { '<<none>>' }
                Set-UndoFlag 'VMwareConfig' $saved
            }
            $lines = if (Test-Path -LiteralPath $file) { @(Get-Content -LiteralPath $file) } else { @() }
            foreach ($k in $want.Keys) {
                $lines = @($lines | Where-Object { $_ -notmatch ('^\s*' + [regex]::Escape($k) + '\s*=') })
                $lines += ($k + ' = ' + $want[$k])
            }
            Set-Content -LiteralPath $file -Value $lines -Encoding ASCII
        } catch { Write-Skip ('VMware setting not changed: ' + $_.Exception.Message) }
    }
    Write-Done 'VMware keeps VM memory in RAM instead of writing it to disk (from the next VM start).'
}
function Restore-VMwareHostMemory {
    $saved = Get-UndoFlag 'VMwareConfig'
    if (-not ($saved -is [hashtable])) { return }
    foreach ($file in @($saved.Keys)) {
        try {
            if ($saved[$file] -eq '<<none>>') { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
            else { [IO.File]::WriteAllText($file, [string]$saved[$file]) }
        } catch {}
    }
    Set-UndoFlag 'VMwareConfig' $null
}
function Add-VmDefenderExclusions {
    if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) { Write-Skip 'Microsoft Defender settings are not available.'; return }
    try {
        $existing = @((Get-MpPreference -ErrorAction Stop).ExclusionExtension)
        $new = @(@('vmdk', 'vmem', 'vmsn', 'vmss') | Where-Object { ($existing -notcontains $_) -and ($existing -notcontains ('.' + $_)) })
        if ($new.Count -gt 0) {
            Add-MpPreference -ExclusionExtension $new -ErrorAction Stop
            foreach ($e in $new) { Add-UndoListItem -Name 'DefenderExt' -Item $e }
        }
        Write-Done 'Defender no longer slows down the VM disk files. Everything else is still scanned.'
    } catch { Write-Skip ('Defender setting not changed: ' + $_.Exception.Message) }
}
function Disable-JunkStartup {
    $pattern = '(?i)(MicrosoftEdgeAutoLaunch|bluestacks|steam|epicgames|discord|spotify|utorrent|bittorrent|capcut|wondershare|filmora|ccleaner|opera|brave|yandex|AdobeGCInvoker|Adobe Creative Cloud|CCXProcess|AdobeAAMUpdater|iTunesHelper)'
    $removed = 0
    $runKeys = @('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')
    $hive = Get-UserHive
    if ($hive) { $runKeys += ($hive + '\Software\Microsoft\Windows\CurrentVersion\Run') }
    foreach ($run in $runKeys) {
        if (-not (Test-Path -LiteralPath $run)) { continue }
        $key = Get-Item -LiteralPath $run
        foreach ($n in @($key.GetValueNames())) {
            $text = $n + ' ' + [string]$key.GetValue($n)
            if ($text -match $pattern -and $text -notmatch '(?i)viber|vpn|vmware|outlook|defender|security') {
                if (Remove-TrackedReg $run $n) { $removed++; Write-Note ('Stopped auto-start: ' + $n) }
            }
        }
    }
    if ($removed -gt 0) { Write-Done ('Stopped ' + $removed + ' non-work app(s) from starting with Windows. They are not uninstalled.') }
    else { Write-Done 'No unneeded startup apps were found.' }
}
function Set-OfficeLightSettings([string]$Hive) {
    if (-not $Hive) { return }
    [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Office\16.0\Common\Graphics') 'DisableHardwareAcceleration' 1)
    [void](Set-TrackedReg ($Hive + '\Software\Policies\Microsoft\Office\16.0\Outlook\Options\RSS') 'Disable' 1)
    [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Office\16.0\Outlook\Options\RSS') 'SyncToSysCFL' 0)
    [void](Disable-TrackedTasks '\Microsoft\Office' 'OfficeTelemetryAgent*')
}
function Invoke-FullOptimization {
    Write-Header 'FULL SPEED SETUP'
    $hive = Get-UserHive
    Write-Step '[1/8] Lighter Windows look'
    if ($hive) { Set-LightVisuals $hive; Write-Done 'Animations, shadows and transparency reduced. Text stays smooth.' } else { Write-Skip 'Signed-in user not found.' }
    Write-Step '[2/8] Stop background apps, tips, news and game recording'
    Set-BackgroundQuiet $hive
    Write-Done 'Windows background extras are off.'
    Write-Step '[3/8] Power plan'
    Set-PowerHighPerformance
    Write-Step '[4/8] Memory file'
    Set-FixedPagefile
    Write-Step '[5/8] VMware'
    Remove-VmwareTuning
    Add-VmDefenderExclusions
    Write-Step '[6/8] Startup apps'
    Disable-JunkStartup
    Write-Step '[7/8] Office and Outlook'
    Set-OfficeLightSettings $hive
    Write-Done 'Office uses less graphics power. Outlook RSS sync is off.'
    Write-Step '[8/8] Clean temporary files'
    Invoke-DailyCare
    Set-UndoFlag 'Optimized' $true
    Write-Host ''
    Write-Host 'Full speed setup finished. Restart the PC once so every change takes effect.' -ForegroundColor Green
}

# ---------------------------------------------------------------------
# Frozen apps
# ---------------------------------------------------------------------
function Show-FrozenApps {
    Write-Header 'FIND FROZEN APPS'
    Write-Host 'Checking which apps are not responding (5 seconds)...' -ForegroundColor Cyan
    $sessionId = 0
    try { $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId } catch {}
    $first = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId -and $_.MainWindowHandle -ne 0 -and -not $_.Responding } | ForEach-Object { $_.Id })
    Start-Sleep -Seconds 5
    $frozen = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId -and $_.MainWindowHandle -ne 0 -and -not $_.Responding -and ($first -contains $_.Id) })
    if ($frozen.Count -eq 0) {
        Write-Host 'No frozen app was found. Every open window is responding.' -ForegroundColor Green
        Write-Host 'If the taskbar or desktop is stuck, go back and choose 2.' -ForegroundColor Cyan
        return
    }
    for ($i = 0; $i -lt $frozen.Count; $i++) {
        $title = [string]$frozen[$i].MainWindowTitle
        if ($title.Length -gt 50) { $title = $title.Substring(0, 47) + '...' }
        Write-Host (('{0,2}. {1,-18} {2}' -f ($i + 1), $frozen[$i].ProcessName, $title)) -ForegroundColor Yellow
    }
    Show-ActionInfo 'Closes the frozen app you choose. You can open it again normally.' 'Other apps, saved files, VPN and the VM.' 'Unsaved work in that frozen app.' 'A few seconds.'
    $raw = (Read-Host 'Type the number to close (A = close all, 0 = cancel)').Trim()
    if ($raw -eq '0' -or $raw -eq '') { Write-Host 'Cancelled. Nothing was closed.' -ForegroundColor Yellow; return }
    $targets = @()
    if ($raw -match '^(?i:A)$') { $targets = $frozen }
    else {
        $n = 0
        if (-not [int]::TryParse($raw, [ref]$n) -or $n -lt 1 -or $n -gt $frozen.Count) { Write-Host 'Invalid number. Nothing was closed.' -ForegroundColor Yellow; return }
        $targets = @($frozen[$n - 1])
    }
    foreach ($p in $targets) {
        if ($p.ProcessName -ieq 'explorer') { Invoke-ExplorerRestart; continue }
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; Write-Done ($p.ProcessName + ' was closed.') }
        catch { Write-Skip ($p.ProcessName + ' could not be closed: ' + $_.Exception.Message) }
    }
}

# ---------------------------------------------------------------------
# Word / Excel
# ---------------------------------------------------------------------
function Find-OfficeAppExe([string]$ExeName) {
    $outlook = Find-OutlookExe
    if ($outlook) {
        $p = Join-Path (Split-Path -Parent $outlook) $ExeName
        if (Test-Path -LiteralPath $p) { return $p }
    }
    foreach ($key in @("Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExeName",
                       "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\$ExeName")) {
        $v = [string](Get-RegValueRaw $key '').Value
        if ($v) { $v = $v.Trim('"'); if (Test-Path -LiteralPath $v) { return $v } }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        foreach ($sub in @('Microsoft Office\root\Office16', 'Microsoft Office\Office16')) {
            $p = Join-Path $base (Join-Path $sub $ExeName)
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    return $null
}
function Invoke-OfficeAppUnstick([string]$Process, [string]$Label, [string]$ExeName) {
    Write-Header ($Label.ToUpperInvariant() + ' IS STUCK')
    if (@(Get-CurrentSessionProcesses -ProcessName $Process).Count -eq 0) { Write-Host ($Label + ' is not running. Open it from the Start menu.') -ForegroundColor Green; return }
    if (-not (Confirm-Action ('Closes ' + $Label + ' and opens it again. ' + $Label + ' then offers to recover open files.') 'Saved files, Outlook, Viber, VPN and the VM.' ('Typing done in the last few minutes in ' + $Label + '.') 'About 1 minute.')) { return }
    if (-not (Close-AppRobust -ProcessName $Process -AppLabel $Label -ForceWarning ('Unsaved work in ' + $Label + ' may be lost.'))) { return }
    Start-Sleep -Seconds 2
    $exe = Find-OfficeAppExe $ExeName
    if ($exe) {
        try { [void](Start-UserProgram -Path $exe); Write-Done ($Label + ' opened again. Look at the "Document Recovery" panel on the left for your files.') }
        catch { Write-Skip ('Open ' + $Label + ' from the Start menu: ' + $_.Exception.Message) }
    }
}
function Open-UnsavedOfficeFiles {
    Write-Header 'FIND A FILE I DID NOT SAVE'
    $profile = Get-InteractiveProfile
    if (-not $profile.LocalPath) { Write-Skip 'Signed-in user not found.'; return }
    $folders = @(
        (Join-Path $profile.LocalPath 'AppData\Local\Microsoft\Office\UnsavedFiles'),
        (Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Word'),
        (Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Excel')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $found = @()
    foreach ($f in $folders) { $found += @(Get-ChildItem -LiteralPath $f -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '(?i)^\.(asd|xlsb|xlsx|docx|tmp|wbk|xar)$' }) }
    if ($found.Count -eq 0) { Write-Host 'No auto-saved Word or Excel file was found on this PC.' -ForegroundColor Yellow; return }
    Write-Host 'Auto-saved files (newest first):' -ForegroundColor Cyan
    $found | Sort-Object LastWriteTime -Descending | Select-Object -First 15 | ForEach-Object {
        Write-Host (('  {0:dd-MMM HH:mm}  {1}' -f $_.LastWriteTime, $_.Name)) -ForegroundColor Green
    }
    Write-Host ''
    Write-Host 'The folders are opening now. Double-click the file with the right time, then use File > Save As.' -ForegroundColor Cyan
    foreach ($f in $folders) { try { [void](Start-UserProgram -Path (Join-Path $env:WINDIR 'explorer.exe') -Arguments ('"' + $f + '"')) } catch {} }
}
function Start-OfficeSafeMode {
    Write-Header 'WORD / EXCEL CLOSES WHEN OPENING'
    $pick = (Read-Host 'Which one? Type W for Word or E for Excel').Trim()
    $map = if ($pick -match '^(?i:W)$') { @('WINWORD', 'Word', 'WINWORD.EXE') } elseif ($pick -match '^(?i:E)$') { @('EXCEL', 'Excel', 'EXCEL.EXE') } else { $null }
    if (-not $map) { Write-Host 'Please type W or E. Nothing was changed.' -ForegroundColor Yellow; return }
    if (-not (Confirm-Action ('Opens ' + $map[1] + ' in Safe Mode, without add-ins, so it does not crash.') 'All files and settings.' ('Unsaved work if ' + $map[1] + ' is already open.') 'About 1 minute.')) { return }
    if (-not (Close-AppRobust -ProcessName $map[0] -AppLabel $map[1])) { return }
    $exe = Find-OfficeAppExe $map[2]
    if (-not $exe) { Write-Skip ($map[1] + ' was not found on this PC.'); return }
    try { [void](Start-UserProgram -Path $exe -Arguments '/safe'); Write-Done ($map[1] + ' opened in Safe Mode. If it works now, use "Repair Word / Excel / Outlook" in this menu.') }
    catch { Write-Skip ('Could not start ' + $map[1] + ': ' + $_.Exception.Message) }
}
function Invoke-OfficeQuickRepair {
    Write-Header 'REPAIR WORD / EXCEL / OUTLOOK'
    if (-not (Confirm-Action 'Repairs Microsoft Office program files using files already on this PC.' 'Documents, emails, accounts and settings.' 'Unsaved work: Word, Excel and Outlook will close.' '10-20 minutes.')) { return }
    $c2r = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $c2rExe = Join-Path $env:CommonProgramFiles 'Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
    if ((Test-Path -LiteralPath $c2r) -and (Test-Path -LiteralPath $c2rExe)) {
        $platform = [string](Get-RegValueRaw $c2r 'Platform').Value
        $culture = [string](Get-RegValueRaw $c2r 'ClientCulture').Value
        if (-not $platform) { $platform = 'x86' }
        if (-not $culture) { $culture = 'en-us' }
        Start-Process -FilePath $c2rExe -ArgumentList ('scenario=Repair platform=' + $platform + ' culture=' + $culture + ' RepairType=QuickRepair forceappshutdown=True DisplayLevel=True')
        Write-Done 'Office repair started. Follow the window that opened.'
        return
    }
    foreach ($root in @('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $name = [string](Get-RegValueRaw $k.PSPath 'DisplayName').Value
            $uninstall = [string](Get-RegValueRaw $k.PSPath 'UninstallString').Value
            if ($name -match '(?i)^Microsoft Office .*2016' -and $uninstall -match '(?i)^"([^"]*setup\.exe)"\s+/uninstall\s+(\S+)') {
                foreach ($p in @('WINWORD', 'EXCEL', 'OUTLOOK', 'POWERPNT')) { [void](Close-AppRobust -ProcessName $p -AppLabel $p) }
                Start-Process -FilePath $Matches[1] -ArgumentList ('/repair ' + $Matches[2])
                Write-Done 'Office repair started. Follow the window that opened.'
                return
            }
        }
    }
    Write-Skip 'Office repair could not be started automatically on this PC.'
}

# ---------------------------------------------------------------------
# Outlook extras
# ---------------------------------------------------------------------
function Get-OutlookAddins {
    $roots = @('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Office\Outlook\Addins',
               'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Office\Outlook\Addins')
    $hive = Get-UserHive
    if ($hive) { $roots += ($hive + '\Software\Microsoft\Office\Outlook\Addins') }
    $items = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $lb = (Get-RegValueRaw $k.PSPath 'LoadBehavior').Value
            if ($lb -ne 3) { continue }
            $friendly = [string](Get-RegValueRaw $k.PSPath 'FriendlyName').Value
            if (-not $friendly -or $friendly -match '^@') { $friendly = $k.PSChildName }
            $items += [pscustomobject]@{ Name = $friendly; Path = $k.PSPath }
        }
    }
    return @($items)
}
function Invoke-OutlookFaster {
    Write-Header 'OUTLOOK IS SLOW'
    $outlookExe = Find-OutlookExe
    if (-not $outlookExe) { Write-Skip 'Classic Outlook was not found on this PC.'; return }
    if (-not (Confirm-Action 'Turns off Office graphics effects and RSS feeds that slow Outlook, then lets you turn off extra add-ins. Outlook restarts.' 'All emails, accounts, folders, signatures and rules.' 'An email you are still writing (save it as draft first).' 'About 1 minute.')) { return }
    if (-not (Close-AppRobust -ProcessName 'OUTLOOK' -AppLabel 'Outlook' -ForceWarning 'Emails you are still writing may be lost.')) { return }
    Set-OfficeLightSettings (Get-UserHive)
    Write-Done 'Graphics effects and RSS feeds are off.'
    $addins = @(Get-OutlookAddins)
    if ($addins.Count -gt 0) {
        Write-Host ''
        Write-Host 'Add-ins that load with Outlook:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $addins.Count; $i++) { Write-Host (('{0,2}. {1}' -f ($i + 1), $addins[$i].Name)) -ForegroundColor Green }
        $raw = (Read-Host 'Type number(s) to turn off (e.g. 1,3), or press Enter to keep all').Trim()
        foreach ($token in @($raw -split '[,;\s]+')) {
            $n = 0
            if ([int]::TryParse($token, [ref]$n) -and $n -ge 1 -and $n -le $addins.Count) {
                if (Set-TrackedReg $addins[$n - 1].Path 'LoadBehavior' 2) { Write-Done ('Add-in turned off: ' + $addins[$n - 1].Name) }
            }
        }
    }
    try { [void](Start-UserProgram -Path $outlookExe); Write-Done 'Outlook opened again.' } catch { Write-Skip 'Open Outlook from the Start menu.' }
}
function Clear-OutlookAttachmentCache {
    Write-Header 'ATTACHMENTS DO NOT OPEN'
    $hive = Get-UserHive
    if (-not $hive) { Write-Skip 'Signed-in user not found.'; return }
    $folder = [string](Get-RegValueRaw ($hive + '\Software\Microsoft\Office\16.0\Outlook\Security') 'OutlookSecureTempFolder').Value
    if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { Write-Skip 'Outlook attachment folder was not found. Nothing to clean.'; return }
    if (-not (Confirm-Action 'Empties the temporary folder Outlook uses to open attachments. Outlook restarts.' 'All emails and their attachments stay inside Outlook.' 'Attachments you opened and edited without saving them somewhere else.' 'About 1 minute.')) { return }
    if (-not (Close-AppRobust -ProcessName 'OUTLOOK' -AppLabel 'Outlook')) { return }
    $count = 0
    foreach ($item in @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue)) {
        try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop; $count++ } catch {}
    }
    Write-Done ('Attachment folder cleaned (' + $count + ' items).')
    $exe = Find-OutlookExe
    if ($exe) { try { [void](Start-UserProgram -Path $exe) } catch {} }
}
function Invoke-SearchRebuild {
    Write-Header 'SEARCH DOES NOT FIND EMAILS'
    if (-not (Confirm-Action 'Rebuilds the search list Outlook uses to find emails.' 'All emails. Nothing is deleted.' 'Search may miss some emails for a few hours while it rebuilds.' '1 minute to start; it finishes by itself in the background.')) { return }
    try {
        Set-Service -Name 'WSearch' -StartupType Automatic -ErrorAction SilentlyContinue
        Stop-Service -Name 'WSearch' -Force -ErrorAction Stop
        Set-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Search' -Name 'SetupCompletedSuccessfully' -Value 0 -Type DWord -ErrorAction Stop
        Start-Service -Name 'WSearch' -ErrorAction Stop
        Write-Done 'Search rebuild started. Keep the PC on; it finishes in the background.'
    } catch { Write-Skip ('Search rebuild could not start: ' + $_.Exception.Message) }
}
function Invoke-OutlookCleanReminders {
    Write-Header 'OLD REMINDERS KEEP POPPING UP'
    $exe = Find-OutlookExe
    if (-not $exe) { Write-Skip 'Classic Outlook was not found on this PC.'; return }
    if (-not (Confirm-Action 'Clears old reminder pop-ups. Outlook restarts.' 'Emails, calendar items and tasks.' 'Reminder pop-ups for old items (the items themselves stay).' 'About 1 minute.')) { return }
    if (-not (Close-AppRobust -ProcessName 'OUTLOOK' -AppLabel 'Outlook')) { return }
    Start-Sleep -Seconds 2
    try { [void](Start-UserProgram -Path $exe -Arguments '/cleanreminders'); Write-Done 'Reminders cleaned. Outlook is opening.' } catch { Write-Skip $_.Exception.Message }
}

# ---------------------------------------------------------------------
# Report for IT (hardware, Windows, installed software, health)
# ---------------------------------------------------------------------
function Get-UserDesktopPath($Profile) {
    try {
        $v = [string](Get-RegValueRaw ('Registry::HKEY_USERS\' + $Profile.SID + '\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders') 'Desktop').Value
        if ($v) {
            if ($v -like '%USERPROFILE%*') { $v = $Profile.LocalPath + $v.Substring(13) }
            $v = [Environment]::ExpandEnvironmentVariables($v)
            if (Test-Path -LiteralPath $v) { return $v }
        }
    } catch {}
    return (Join-Path $Profile.LocalPath 'Desktop')
}
function Get-InstalledSoftware {
    $roots = @('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
               'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    $hive = Get-UserHive
    if ($hive) { $roots += ($hive + '\Software\Microsoft\Windows\CurrentVersion\Uninstall') }
    $list = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop
                if (-not $p.DisplayName) { continue }
                if ($p.SystemComponent -eq 1 -or $p.ParentKeyName) { continue }
                $list += [pscustomobject]@{ Name = [string]$p.DisplayName; Version = [string]$p.DisplayVersion; Publisher = [string]$p.Publisher; Installed = [string]$p.InstallDate }
            } catch {}
        }
    }
    return @($list | Sort-Object Name, Version -Unique)
}
function New-ITReport([string]$OutDir = '') {
    $profile = Get-InteractiveProfile
    if (-not $OutDir) {
        if ($profile.LocalPath) { $OutDir = Get-UserDesktopPath $profile } else { $OutDir = Join-Path $script:ToolRoot 'Reports' }
    }
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $file = Join-Path $OutDir ('PC-Report-{0}-{1:yyyyMMdd-HHmm}.txt' -f $env:COMPUTERNAME, (Get-Date))
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('OFFICE PC REPORT'); $L.Add(('PC: {0}   User: {1}   Created: {2:yyyy-MM-dd HH:mm}' -f $env:COMPUTERNAME, $profile.UserName, (Get-Date))); $L.Add('')
    try {
        $cs = Get-CimInstance Win32_ComputerSystem; $os = Get-CimInstance Win32_OperatingSystem
        $cpu = @(Get-CimInstance Win32_Processor)[0]; $bb = Get-CimInstance Win32_BaseBoard; $bios = Get-CimInstance Win32_BIOS
        $L.Add('== HARDWARE ==')
        $L.Add(('CPU         : {0} ({1} cores / {2} threads)' -f ([string]$cpu.Name).Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors))
        $L.Add(('Motherboard : {0} {1}' -f $bb.Manufacturer, $bb.Product))
        $L.Add(('BIOS        : {0} ({1:yyyy-MM-dd})' -f $bios.SMBIOSBIOSVersion, $bios.ReleaseDate))
        $L.Add(('PC model    : {0} {1}' -f $cs.Manufacturer, $cs.Model))
        $slots = 0; try { $slots = (@(Get-CimInstance Win32_PhysicalMemoryArray) | Measure-Object -Property MemoryDevices -Sum).Sum } catch {}
        $sticks = @(Get-CimInstance Win32_PhysicalMemory)
        $L.Add(('RAM         : {0:N1} GB total, {1} stick(s) in {2} slot(s)' -f ($cs.TotalPhysicalMemory / 1GB), $sticks.Count, $slots))
        foreach ($m in $sticks) { $L.Add(('              {0}: {1:N0} GB {2} MHz {3} {4}' -f $m.BankLabel, ($m.Capacity / 1GB), $m.Speed, ([string]$m.Manufacturer).Trim(), ([string]$m.PartNumber).Trim())) }
        try { foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) { $L.Add(('Disk        : {0} | {1} | {2:N0} GB | Health: {3}' -f $d.FriendlyName, $d.MediaType, ($d.Size / 1GB), $d.HealthStatus)) } }
        catch { foreach ($d in @(Get-CimInstance Win32_DiskDrive)) { $L.Add(('Disk        : {0} | {1:N0} GB | Status: {2}' -f $d.Model, ($d.Size / 1GB), $d.Status)) } }
        foreach ($v in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) { $L.Add(('Drive {0}    : {1:N1} GB free of {2:N1} GB' -f $v.DeviceID, ($v.FreeSpace / 1GB), ($v.Size / 1GB))) }
        foreach ($g in @(Get-CimInstance Win32_VideoController)) { $L.Add(('Graphics    : {0}' -f $g.Name)) }
        $L.Add('')
        $L.Add('== WINDOWS ==')
        $ubr = (Get-RegValueRaw 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'UBR').Value
        $L.Add(('Windows     : {0} {1} (build {2}.{3})' -f $os.Caption, $os.Version, $os.BuildNumber, $ubr))
        $L.Add(('Installed   : {0:yyyy-MM-dd}' -f $os.InstallDate))
        $up = (Get-Date) - $os.LastBootUpTime
        $L.Add(('Last start  : {0:yyyy-MM-dd HH:mm} (running {1} days {2} hours)' -f $os.LastBootUpTime, $up.Days, $up.Hours))
        try {
            $lic = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop)[0]
            $status = switch ([int]$lic.LicenseStatus) { 1 { 'Activated' } 0 { 'Not activated' } default { 'Status ' + $lic.LicenseStatus } }
            $L.Add(('Activation  : {0}' -f $status))
        } catch {}
        $L.Add(('Memory now  : {0:N1} GB free of {1:N1} GB | Commit {2:N1} / {3:N1} GB' -f ($os.FreePhysicalMemory / 1MB), ($os.TotalVisibleMemorySize / 1MB), (($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB), ($os.TotalVirtualMemorySize / 1MB)))
        foreach ($pf in @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)) { $L.Add(('Page file   : {0} | {1} MB size | {2} MB peak use' -f $pf.Name, $pf.AllocatedBaseSize, $pf.PeakUsage)) }
        $wu = Get-Service wuauserv -ErrorAction SilentlyContinue
        $L.Add(('Win Update  : {0}' -f $(if ($wu) { $wu.StartType } else { 'not found' })))
        $L.Add(('Edge blocked: {0}' -f [bool](Get-RegValueRaw 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\msedge.exe' 'Debugger').Exists))
        $L.Add(('Toolkit     : setup {0} | Auto Care task {1}' -f $(if (Test-Path -LiteralPath $script:SetupMarker) { 'done' } else { 'not done' }), $(try { [void](Get-TaskService).GetFolder('\').GetTask($script:TaskName); 'present' } catch { 'missing' })))
    } catch { $L.Add('Hardware/Windows details could not be read: ' + $_.Exception.Message) }
    $L.Add('')
    $L.Add('== TOP 15 APPS BY MEMORY ==')
    Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 | ForEach-Object { $L.Add(('{0,-30} {1,7:N0} MB' -f $_.ProcessName, ($_.WorkingSet64 / 1MB))) }
    $L.Add('')
    $L.Add('== APPS THAT START WITH WINDOWS ==')
    $runKeys = @('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')
    $hive = Get-UserHive
    if ($hive) { $runKeys += ($hive + '\Software\Microsoft\Windows\CurrentVersion\Run') }
    foreach ($run in $runKeys) { if (Test-Path -LiteralPath $run) { $k = Get-Item -LiteralPath $run; foreach ($n in $k.GetValueNames()) { $L.Add(('{0,-30} {1}' -f $n, [string]$k.GetValue($n))) } } }
    if ($profile.LocalPath) { foreach ($s in @(Get-ChildItem -LiteralPath (Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup') -ErrorAction SilentlyContinue)) { $L.Add(('{0,-30} (Startup folder)' -f $s.Name)) } }
    $L.Add('')
    $L.Add('== NETWORK ==')
    try {
        foreach ($a in @(Get-NetAdapter -ErrorAction Stop | Sort-Object Status)) {
            $ip = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress }) -join ', '
            $L.Add(('{0,-28} {1,-12} {2,-10} {3} {4}' -f $a.Name, $a.Status, $a.LinkSpeed, $ip, $a.InterfaceDescription))
        }
        $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses } | ForEach-Object { $_.InterfaceAlias + '=' + ($_.ServerAddresses -join '/') }) -join '; '
        $L.Add('DNS: ' + $dns)
    } catch { $L.Add('Network details could not be read.') }
    $L.Add('')
    $L.Add('== OFFICE / OUTLOOK ==')
    $ol = Find-OutlookExe
    if ($ol) { $L.Add(('Outlook     : {0} (version {1})' -f $ol, (Get-Item -LiteralPath $ol).VersionInfo.ProductVersion)) } else { $L.Add('Outlook     : not found') }
    if ($profile.LocalPath) {
        $dataFolders = @((Join-Path $profile.LocalPath 'AppData\Local\Microsoft\Outlook'), (Join-Path $profile.LocalPath 'Documents\Outlook Files'))
        foreach ($f in $dataFolders) { foreach ($d in @(Get-ChildItem -LiteralPath $f -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '(?i)^\.(ost|pst)$' })) { $L.Add(('Mail file   : {0,-45} {1,8:N0} MB' -f $d.Name, ($d.Length / 1MB))) } }
    }
    $L.Add('')
    $L.Add('== CRASHES AND HANGS, LAST 7 DAYS ==')
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1002; StartTime = (Get-Date).AddDays(-7) } -ErrorAction Stop)
        $events | Group-Object { [string]$_.Properties[0].Value } | Sort-Object Count -Descending | ForEach-Object { $L.Add(('{0,-30} {1} time(s)' -f $_.Name, $_.Count)) }
    } catch { $L.Add('None recorded.') }
    $L.Add('')
    $sw = @(Get-InstalledSoftware)
    $L.Add(('== INSTALLED SOFTWARE ({0}) ==' -f $sw.Count))
    foreach ($s in $sw) { $L.Add(('{0,-55} {1,-18} {2,-28} {3}' -f $s.Name, $s.Version, $s.Publisher, $s.Installed)) }
    $L.Add('')
    $L.Add('== BLUE SCREENS AND SUDDEN RESTARTS, LAST 30 DAYS ==')
    try {
        $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 1001; StartTime = (Get-Date).AddDays(-30) } -ErrorAction Stop |
            Where-Object { $_.Id -eq 41 -or $_.ProviderName -match 'WER-SystemErrorReporting|BugCheck' })
        foreach ($c in @($crashes | Select-Object -First 20)) {
            $msg = ([string]$c.Message -split "`r?`n")[0]
            if ($msg.Length -gt 150) { $msg = $msg.Substring(0, 150) }
            $L.Add(('{0:yyyy-MM-dd HH:mm}  Event {1}  {2}' -f $c.TimeCreated, $c.Id, $msg))
        }
        if ($crashes.Count -eq 0) { $L.Add('None recorded.') }
    } catch { $L.Add('None recorded.') }
    foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $env:WINDIR 'Minidump') -Filter '*.dmp' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10)) { $L.Add(('Crash dump: {0}  {1:yyyy-MM-dd HH:mm}' -f $d.Name, $d.LastWriteTime)) }
    $L.Add('')
    $L.Add('== CHROME EXTENSIONS ON THIS PC ==')
    foreach ($id in @(Get-InstalledChromeExtensions)) { $L.Add($id) }
    $L.Add('')
    $L.Add('== TOOLKIT LOGS (latest 5) ==')
    Get-ChildItem -LiteralPath $script:LogRoot -File -Filter 'PC-Care_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object { $L.Add($_.FullName) }
    [IO.File]::WriteAllLines($file, $L, (New-Object System.Text.UTF8Encoding($true)))
    return $file
}
# ---------------------------------------------------------------------
# Daily report to the IT dashboard (https://office-pc-care.vercel.app/dashboard)
# ---------------------------------------------------------------------
$script:ReportUrl = 'https://office-pc-care.vercel.app/api/report'
$script:ReportDateFile = Join-Path $script:ToolRoot 'last-report-date.txt'
function Get-BdDate { return [DateTime]::UtcNow.AddHours(6).ToString('yyyy-MM-dd') }
function Get-PcReportData {
    $profile = Get-InteractiveProfile
    $r = [ordered]@{ kind = 'office-pc-care-report'; pc = $env:COMPUTERNAME; user = [string]$profile.UserName; reportDate = (Get-BdDate); time = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); build = (Get-InstalledBuild) }
    # Helps IT tell whose PC it is: Windows account full name, IP address, PC time zone.
    $r.userFullName = ''
    try {
        $short = ([string]$profile.UserName).Split('\')[-1]
        if ($short) { $r.userFullName = [string]([ADSI]('WinNT://' + $env:COMPUTERNAME + '/' + $short + ',user')).FullName }
    } catch {}
    try { $r.ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias -notmatch '(?i)vmware|virtual|vEthernet|loopback|vpn|tap|wintun' } | ForEach-Object { [string]$_.IPAddress }) } catch { $r.ipv4 = @() }
    try { $r.timeZone = [string](Get-TimeZone).Id } catch { $r.timeZone = '' }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem; $os = Get-CimInstance Win32_OperatingSystem
        $cpu = @(Get-CimInstance Win32_Processor)[0]; $bb = Get-CimInstance Win32_BaseBoard
        $slots = 0; try { $slots = [int](@(Get-CimInstance Win32_PhysicalMemoryArray) | Measure-Object -Property MemoryDevices -Sum).Sum } catch {}
        $disks = @()
        try { $disks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object { [ordered]@{ name = [string]$_.FriendlyName; type = [string]$_.MediaType; gb = [int]($_.Size / 1GB); health = [string]$_.HealthStatus } }) }
        catch { $disks = @(Get-CimInstance Win32_DiskDrive | ForEach-Object { [ordered]@{ name = [string]$_.Model; type = ''; gb = [int]($_.Size / 1GB); health = [string]$_.Status } }) }
        $r.hardware = [ordered]@{
            cpu = ([string]$cpu.Name).Trim(); cores = [int]$cpu.NumberOfCores; threads = [int]$cpu.NumberOfLogicalProcessors
            board = ([string]$bb.Manufacturer + ' ' + [string]$bb.Product).Trim(); model = ([string]$cs.Manufacturer + ' ' + [string]$cs.Model).Trim()
            ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1); ramSlots = $slots
            ramSticks = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object { [ordered]@{ slot = [string]$_.BankLabel; gb = [int]($_.Capacity / 1GB); mhz = [int]$_.Speed; part = ([string]$_.PartNumber).Trim() } })
            disks = $disks
            drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { [ordered]@{ id = [string]$_.DeviceID; freeGB = [math]::Round($_.FreeSpace / 1GB, 1); sizeGB = [math]::Round($_.Size / 1GB, 1) } })
            gpu = (@(Get-CimInstance Win32_VideoController | ForEach-Object { [string]$_.Name }) -join ', ')
        }
        $r.windows = [ordered]@{ name = [string]$os.Caption; version = [string]$os.Version; build = [string]$os.BuildNumber; installDate = $os.InstallDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); lastBoot = $os.LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); uptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1) }
        $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
        $r.memory = [ordered]@{ totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1); freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1); commitUsedGB = [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB, 1); commitTotalGB = [math]::Round($os.TotalVirtualMemorySize / 1MB, 1); pagefileMB = [int](($pf | Measure-Object -Property AllocatedBaseSize -Sum).Sum) }
    } catch {}
    $r.topApps = @(Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName | ForEach-Object { [ordered]@{ name = $_.Name; mb = [int](($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB); count = $_.Count } } | Sort-Object { $_.mb } -Descending | Select-Object -First 12)
    $startup = @()
    $runKeys = @('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')
    if ($profile.SID) { $runKeys += ('Registry::HKEY_USERS\' + $profile.SID + '\Software\Microsoft\Windows\CurrentVersion\Run') }
    foreach ($k in $runKeys) { if (Test-Path -LiteralPath $k) { $startup += @((Get-Item -LiteralPath $k).GetValueNames()) } }
    $r.startupNow = @($startup | Where-Object { $_ } | Select-Object -Unique)
    $r.slowStart = @(Get-SlowStartList | ForEach-Object { [string]$_.name })
    $r.software = @(Get-InstalledSoftware | ForEach-Object { [ordered]@{ name = $_.Name; version = $_.Version; publisher = $_.Publisher } })
    $bs = @()
    try { $bs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 1001; StartTime = (Get-Date).AddDays(-30) } -ErrorAction Stop | Where-Object { $_.Id -eq 41 -or $_.ProviderName -match 'WER-SystemErrorReporting|BugCheck' }) } catch {}
    $apps = @()
    try { $apps = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1002; StartTime = (Get-Date).AddDays(-7) } -ErrorAction Stop | Group-Object { [string]$_.Properties[0].Value } | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { [ordered]@{ app = $_.Name; count = $_.Count } }) } catch {}
    $r.crashes = [ordered]@{
        blueScreens30d = $bs.Count
        lastBlueScreens = @($bs | Select-Object -First 5 | ForEach-Object { $msg = ([string]$_.Message -split "`r?`n")[0]; if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) }; [ordered]@{ time = $_.TimeCreated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); id = $_.Id; msg = $msg } })
        appCrashes7d = $apps
    }
    $mail = @()
    if ($profile.LocalPath) {
        foreach ($f in @((Join-Path $profile.LocalPath 'AppData\Local\Microsoft\Outlook'), (Join-Path $profile.LocalPath 'Documents\Outlook Files'))) {
            $mail += @(Get-ChildItem -LiteralPath $f -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '(?i)^\.(ost|pst)$' } | ForEach-Object { [ordered]@{ name = $_.Name; mb = [int]($_.Length / 1MB) } })
        }
    }
    $olExe = Find-OutlookExe
    $r.outlook = [ordered]@{ version = $(if ($olExe) { [string](Get-Item -LiteralPath $olExe).VersionInfo.ProductVersion } else { '' }); mailFiles = $mail; totalMB = [int](($mail | ForEach-Object { $_.mb } | Measure-Object -Sum).Sum) }
    try { $r.vpn = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.InterfaceDescription -match '(?i)vpn|tap-|wintun|wireguard|nord|express|lightway' } | ForEach-Object { [ordered]@{ name = [string]$_.Name; status = [string]$_.Status } }) } catch { $r.vpn = @() }
    $vmx = @(Get-Process -Name 'vmware-vmx' -ErrorAction SilentlyContinue)
    $r.vm = [ordered]@{ running = ($vmx.Count -gt 0); memMB = [int](($vmx | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }
    $root = $null; try { $root = (Get-TaskService).GetFolder('\') } catch {}
    $hasTask = { param($n) try { [void]$root.GetTask($n); $true } catch { $false } }
    $wu = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
    $r.settings = [ordered]@{
        setupDone = (Test-Path -LiteralPath $script:SetupMarker); updatesOff = [bool](Get-UndoFlag 'UpdatesOff'); edgeOff = [bool](Get-UndoFlag 'EdgeOff')
        wuStart = $(if ($wu) { [string]$wu.StartType } else { 'missing' })
        autoCareTask = (& $hasTask $script:TaskName); viberTask = (& $hasTask $script:ViberTask); slowStartTask = (& $hasTask $script:SlowStartTask)
    }
    $r.chromeExtensions = @(Get-InstalledChromeExtensions)
    return $r
}
function Send-PcReport([switch]$Force) {
    if (-not $Force -and (Test-Path -LiteralPath $script:ReportDateFile) -and ((Get-Content -LiteralPath $script:ReportDateFile -Raw).Trim() -eq (Get-BdDate))) { return }
    try {
        $json = (Get-PcReportData) | ConvertTo-Json -Depth 6 -Compress
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
        $wc = New-Object Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers['Content-Type'] = 'application/json; charset=utf-8'
        try { [void]$wc.UploadString($script:ReportUrl, 'POST', $json) } finally { $wc.Dispose() }
        Set-Content -LiteralPath $script:ReportDateFile -Value (Get-BdDate) -Encoding ASCII
        Write-Done 'PC report sent to the IT dashboard.'
    } catch { Write-Skip ('PC report not sent now (will retry at the next Auto Care): ' + $_.Exception.Message) }
}
function Invoke-SendReportToIT {
    Write-Header 'SEND REPORT TO IT'
    Show-ActionInfo 'Sends PC info to the IT dashboard and saves a copy on the desktop: hardware, Windows, installed apps, recent errors.' 'No personal files, passwords, emails, chats or browsing history are included.' 'Nothing. This only reads information.' 'About 30 seconds.'
    Write-Host 'Collecting information...' -ForegroundColor Cyan
    Send-PcReport -Force
    $file = New-ITReport
    Write-Done ('Report saved: ' + $file)
    Write-Host 'IT can already see it on the dashboard. The folder is opening now.' -ForegroundColor Cyan
    try { [void](Start-UserProgram -Path (Join-Path $env:WINDIR 'explorer.exe') -Arguments ('/select,"' + $file + '"')) } catch {}
}

# ---------------------------------------------------------------------
# One-time setup, Auto Care and Undo
# ---------------------------------------------------------------------
function Invoke-UndoAllSystemPart {
    # Runs as SYSTEM so protected Windows Update settings can be restored too.
    $r = Restore-Tracked $null
    Write-Done ('Settings restored: ' + $r.Ok + '   Not restored: ' + $r.Fail)
}
function Invoke-UndoAll {
    # IT only, not in the staff menu. Run from an admin Command Prompt:  Office-PC-Care-Toolkit-v12.bat undo
    Write-Header 'UNDO ALL CHANGES'
    Unregister-AutoCareTask
    try { (Get-TaskService).GetFolder('\').DeleteTask($script:ViberTask, 0) } catch {}
    try { (Get-TaskService).GetFolder('\').DeleteTask($script:EarlyTask, 0) } catch {}
    Restore-SlowStart
    Remove-Item -LiteralPath $script:ShortcutFile -Force -ErrorAction SilentlyContinue
    foreach ($v in @(Get-UndoFlag 'VmxBackups')) {
        if ($v -and (Test-Path -LiteralPath $v.Backup) -and @(Get-Process -Name 'vmware-vmx' -ErrorAction SilentlyContinue).Count -eq 0) { try { Copy-Item -LiteralPath $v.Backup -Destination $v.Vmx -Force } catch {} }
    }
    $dp = Get-UndoFlag 'DefenderPrefs'
    if ($dp) { try { Set-MpPreference -ScanAvgCPULoadFactor $dp.Cpu -EnableLowCpuPriority $dp.LowCpu -ScanScheduleDay $dp.Day -ErrorAction Stop } catch {}; Set-UndoFlag 'DefenderPrefs' $null }
    foreach ($m in @(Get-UndoFlag 'MovedShortcuts')) {
        if ($m -and $m.Backup -and (Test-Path -LiteralPath $m.Backup) -and -not (Test-Path -LiteralPath $m.Source)) { try { Move-Item -LiteralPath $m.Backup -Destination $m.Source } catch {} }
    }
    Set-UndoFlag 'MovedShortcuts' @()
    $ran = $false
    try { [void](Invoke-AsSystem 'undo-system'); $ran = $true } catch { Write-Note ('SYSTEM restore step failed, trying as administrator: ' + $_.Exception.Message) }
    if (-not $ran) { Invoke-UndoAllSystemPart }
    Restore-Pagefile
    Restore-VMwareHostMemory
    foreach ($e in @(Get-UndoFlag 'DefenderExt')) { if ($e) { try { Remove-MpPreference -ExclusionExtension $e -ErrorAction Stop } catch {} } }
    Set-UndoFlag 'DefenderExt' @()
    $scheme = Get-UndoFlag 'PowerScheme'
    if ($scheme) { & powercfg.exe /setactive $scheme 2>&1 | Out-Null; Set-UndoFlag 'PowerScheme' $null }
    Remove-Item -LiteralPath $script:SetupMarker -Force -ErrorAction SilentlyContinue
    Set-UndoFlag 'UpdatesOff' $false; Set-UndoFlag 'EdgeOff' $false; Set-UndoFlag 'Optimized' $false
    Write-Host ''
    Write-Host 'Everything this toolkit changed has been put back. Restart the PC to finish.' -ForegroundColor Green
}


# =====================================================================
# v13: central config, signed self-update, slow start, VM internet,
# Outlook 6 months + add-ins off, Chrome balanced + extension control,
# services, Defender light, Office start, blue-screen report.
# =====================================================================
$script:BuildStamp     = '7'
$script:ToolkitBuild   = 0
if ($script:BuildStamp -match '^\d+$') { $script:ToolkitBuild = [int]$script:BuildStamp }
$script:UpdateBaseUrl  = 'https://raw.githubusercontent.com/SM1022-dot/office-pc-care/main/toolkit/'
$script:UpdatePublicKey = '<RSAKeyValue><Modulus>sZ82Bi+zBO+qVDSK9WmDDZb9yy0sVlehw7SryXujw63qOTu55A7XSHkMHn+WmnKJiqmJYxFdbXDxiaXFrg0l9zhxgbvfIwf9mnFu9buGT6e9E8njLxGtH5xCVNYR6Ai7Yr1alZpb84aEbMdSJiVVtWssV27veRyhPyuOGF6nxbxr1eIEGs59Vr5OT+/5z52lDAVDYJfynXgXyajSykyA7V+/Z2nawI7mKKI5Fm5GRDQ1T/DzdYjdo0zLmiL5oQ8Q2lAQl9n0qgklRwAhCYQZdsQ/EqyLJrCyykqEwqdka38X2qO7ahzlL2KEzsB210+fjX3WKOKoPkI9efSjWCOciJmmGWQr94R+UOnrToNiDkOO/UwvEbtUxtRijPHGfmnzMprYxAg/0vimqLNrpb1u7duL+v/zFuBMwE9DJgoM+p7L2/bWIFpGypP87o459zDUAo2pgaAKk3J1Lq1APFI0gCY6yfvyuLuEpKKj2neysSIBHjHkFqJVKrAsbbcBdmPR</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'
$script:ConfigFile     = Join-Path $script:ToolRoot 'config.json'
$script:BuildFile      = Join-Path $script:ToolRoot 'installed-build.txt'
$script:SlowStartFile  = Join-Path $script:ToolRoot 'slow-start.json'
$script:SlowStartScript = Join-Path $script:ToolRoot 'slow-start.ps1'
$script:SlowStartLauncher = Join-Path $script:ToolRoot 'slow-start.vbs'
$script:SlowStartTask  = 'Office PC Care Toolkit - Slow Start'
$script:EarlyTask      = 'Office PC Care Toolkit - Early Boot'
$script:ShortcutFile   = Join-Path $env:PUBLIC 'Desktop\PC Care.lnk'
$script:ExtraArg       = ([string]$env:PCTOOLKIT_ARG).Trim()

$script:DefaultConfig = [ordered]@{
    chromeMemorySaverLevel    = 1
    chromeNeverRest           = @('web.whatsapp.com')
    blockNewChromeExtensions  = $true
    chromeExtensionAllowlist  = @()
    servicesOff               = @('Spooler', 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc', 'MapsBroker', 'Fax', 'RetailDemo')
    servicesManual            = @('WerSvc')
    slowStartDelaySeconds     = 180
    slowStartGapSeconds       = 25
    outlookOfflineMonths      = 6
    outlookDisableAllAddins   = $true
    defenderQuickScanBdTime   = '20:45'
    defenderCpuLimitPercent   = 20
}
function Get-Cfg([string]$Name) {
    $value = $script:DefaultConfig[$Name]
    try {
        if (Test-Path -LiteralPath $script:ConfigFile) {
            $cfg = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.PSObject.Properties.Name -contains $Name) { $value = $cfg.$Name }
        }
    } catch {}
    return $value
}
function Save-DefaultConfigIfMissing {
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) {
        New-Item -ItemType Directory -Path $script:ToolRoot -Force | Out-Null
        ($script:DefaultConfig | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8
    }
}
function Get-InstalledBuild {
    try { if (Test-Path -LiteralPath $script:BuildFile) { return [int](Get-Content -LiteralPath $script:BuildFile -Raw).Trim() } } catch {}
    return 0
}
function Set-InstalledBuild([int]$Build) { Set-Content -LiteralPath $script:BuildFile -Value $Build -Encoding ASCII }

# ---------------------------------------------------------------------
# Signed self-update from the IT room (GitHub)
# ---------------------------------------------------------------------
function Test-UpdateSignature([byte[]]$Data, [string]$SignatureBase64) {
    if ($script:UpdatePublicKey -like '__*') { return $false }
    try {
        $rsa = [Security.Cryptography.RSA]::Create()
        $rsa.FromXmlString($script:UpdatePublicKey)
        return $rsa.VerifyData($Data, [Convert]::FromBase64String($SignatureBase64.Trim()), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } catch { return $false }
}
function Get-WebBytes([string]$Url) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $wc = New-Object Net.WebClient
    $wc.Headers['Cache-Control'] = 'no-cache'
    try { return $wc.DownloadData($Url + '?t=' + [DateTime]::UtcNow.Ticks) } finally { $wc.Dispose() }
}
function Invoke-SelfUpdate {
    $allowed = @('PC-Care-Toolkit.bat', 'config.json')
    try {
        $manifestBytes = Get-WebBytes ($script:UpdateBaseUrl + 'manifest.json')
        $signature = [Text.Encoding]::ASCII.GetString((Get-WebBytes ($script:UpdateBaseUrl + 'manifest.sig')))
    } catch { Write-Skip ('Update check skipped (no internet or GitHub not reachable): ' + $_.Exception.Message); return }
    if (-not (Test-UpdateSignature $manifestBytes $signature)) { Write-Skip 'Update REJECTED: the signature is not valid. Nothing was installed.'; return }
    $manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
    $current = Get-InstalledBuild
    if ([int]$manifest.build -le $current) { Write-Done ('Toolkit is up to date (build ' + $current + ').'); return }
    $staging = Join-Path $script:ToolRoot 'Staging'
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    foreach ($f in @($manifest.files)) {
        if ($allowed -notcontains [string]$f.name) { Write-Skip ('Update REJECTED: unexpected file ' + $f.name); return }
        $bytes = Get-WebBytes ($script:UpdateBaseUrl + $f.name)
        $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        if ($sha -ne ([string]$f.sha256).ToLowerInvariant()) { Write-Skip ('Update REJECTED: ' + $f.name + ' does not match the signed list.'); return }
        [IO.File]::WriteAllBytes((Join-Path $staging $f.name), $bytes)
    }
    foreach ($f in @($manifest.files)) { Copy-Item -LiteralPath (Join-Path $staging $f.name) -Destination (Join-Path $script:ToolRoot $f.name) -Force }
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Set-InstalledBuild ([int]$manifest.build)
    Write-Done ('Toolkit updated from build ' + $current + ' to build ' + $manifest.build + '.')
    return $true
}

# ---------------------------------------------------------------------
# Services, heavy Windows tasks, memory, Defender
# ---------------------------------------------------------------------
function Set-ServicesFromConfig {
    foreach ($s in @(Get-Cfg 'servicesOff')) { if ($s) { [void](Set-TrackedServiceStart -Name ([string]$s) -Start 4) } }
    foreach ($s in @(Get-Cfg 'servicesManual')) { if ($s) { [void](Set-TrackedServiceStart -Name ([string]$s) -Start 3) } }
    Write-Done 'Services that these PCs do not need are off (printer, Xbox, maps, fax).'
}
function Disable-HeavyWindowsTasks {
    $n = 0
    $n += Disable-TrackedTasks '\Microsoft\Windows\Application Experience'
    $n += Disable-TrackedTasks '\Microsoft\Windows\Customer Experience Improvement Program'
    $n += Disable-TrackedTasks '\Microsoft\Windows\Maps'
    $n += Disable-TrackedTasks '\Microsoft\Windows\DiskDiagnostic'
    $n += Disable-TrackedTasks '\Microsoft\Windows\Feedback\Siuf'
    Write-Done 'Heavy background Windows jobs that run during work hours are off.'
}
function Enable-MemorySavers {
    try { Enable-MMAgent -MemoryCompression -ErrorAction Stop } catch {}
    try { Enable-MMAgent -PageCombining -ErrorAction Stop } catch {}
    Write-Done 'Windows memory compression and page combining are on.'
}
function Set-DefenderLight {
    if (-not (Get-Command Set-MpPreference -ErrorAction SilentlyContinue)) { return }
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        if (-not (Get-UndoFlag 'DefenderPrefs')) {
            Set-UndoFlag 'DefenderPrefs' @{ Cpu = [int]$pref.ScanAvgCPULoadFactor; LowCpu = [bool]$pref.EnableLowCpuPriority; Day = [int]$pref.ScanScheduleDay; Quick = [string]$pref.ScanScheduleQuickScanTime }
        }
        $bd = [string](Get-Cfg 'defenderQuickScanBdTime')
        $parts = $bd.Split(':')
        $bdNow = [DateTime]::UtcNow.AddHours(6)
        $utc = (New-Object DateTime ($bdNow.Year, $bdNow.Month, $bdNow.Day, [int]$parts[0], [int]$parts[1], 0, [DateTimeKind]::Utc)).AddHours(-6)
        $local = [TimeZoneInfo]::ConvertTimeFromUtc($utc, [TimeZoneInfo]::Local)
        Set-MpPreference -ScanAvgCPULoadFactor ([int](Get-Cfg 'defenderCpuLimitPercent')) -EnableLowCpuPriority $true -ScanScheduleDay 0 -ScanScheduleQuickScanTime $local.ToString('HH:mm:00') -ErrorAction Stop
        Write-Done ('Defender uses less CPU; daily quick scan at ' + $bd + ' Bangladesh time (' + $local.ToString('HH:mm') + ' on this PC).')
    } catch { Write-Skip ('Defender settings not changed: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------------
# Chrome: balanced memory saver, never-rest sites, flexible extensions
# ---------------------------------------------------------------------
function Set-TrackedPolicyList([string]$Path, [object[]]$Items) {
    $items = @($Items | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    for ($i = 0; $i -lt $items.Count; $i++) { [void](Set-TrackedReg $Path ([string]($i + 1)) $items[$i] 'String') }
    if (Test-Path -LiteralPath $Path) {
        foreach ($n in @((Get-Item -LiteralPath $Path).GetValueNames())) {
            $num = 0
            if ([int]::TryParse($n, [ref]$num) -and $num -gt $items.Count) { [void](Remove-TrackedReg $Path $n) }
        }
    }
}
function Get-InstalledChromeExtensions {
    $ids = @()
    foreach ($userDir in @(Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue)) {
        $data = Join-Path $userDir.FullName 'AppData\Local\Google\Chrome\User Data'
        if (-not (Test-Path -LiteralPath $data)) { continue }
        foreach ($profileDir in @(Get-ChildItem -LiteralPath $data -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            $ext = Join-Path $profileDir.FullName 'Extensions'
            foreach ($e in @(Get-ChildItem -LiteralPath $ext -Directory -ErrorAction SilentlyContinue)) {
                if ($e.Name -match '^[a-p]{32}$') { $ids += $e.Name }
            }
        }
    }
    return @($ids | Select-Object -Unique)
}
function Set-ChromePolicies {
    $browser = Get-PreferredBrowser
    if (-not $browser -or $browser.Kind -ne 'Chrome') { Write-Skip 'Chrome is not installed. Chrome settings skipped.'; return }
    $p = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome'
    [void](Set-TrackedReg $p 'HighEfficiencyModeEnabled' 1)
    [void](Set-TrackedReg $p 'MemorySaverModeSavings' ([int](Get-Cfg 'chromeMemorySaverLevel')))
    [void](Set-TrackedReg $p 'BackgroundModeEnabled' 0)
    Set-TrackedPolicyList ($p + '\TabDiscardingExceptions') @(Get-Cfg 'chromeNeverRest')
    if (Get-Cfg 'blockNewChromeExtensions') {
        $baseline = @(Get-UndoFlag 'ChromeExtBaseline')
        if (-not (Get-UndoFlag 'ChromeExtBaselineDone')) {
            $baseline = @(Get-InstalledChromeExtensions)
            Set-UndoFlag 'ChromeExtBaseline' $baseline
            Set-UndoFlag 'ChromeExtBaselineDone' $true
        }
        $allow = @($baseline) + @(Get-Cfg 'chromeExtensionAllowlist') + @(Get-UndoFlag 'ChromeExtLocalAllow')
        Set-TrackedPolicyList ($p + '\ExtensionInstallAllowlist') $allow
        Set-TrackedPolicyList ($p + '\ExtensionInstallBlocklist') @('*')
        Write-Done ('Chrome: tabs rest only when unused for a while, WhatsApp Web stays awake, ' + @($allow | Select-Object -Unique).Count + ' extension(s) allowed, new ones blocked.')
    } else {
        Write-Done 'Chrome: tabs rest only when unused for a while, WhatsApp Web stays awake.'
    }
}
function Add-LocalChromeExtension([string]$Id) {
    if ($Id -notmatch '^[a-p]{32}$') { Write-Skip 'That is not a Chrome extension ID (32 letters a-p).'; return }
    Add-UndoListItem -Name 'ChromeExtLocalAllow' -Item $Id
    Set-ChromePolicies
    Write-Done ('Extension allowed on this PC: ' + $Id + '. Restart Chrome.')
}

# ---------------------------------------------------------------------
# Outlook: all add-ins off, keep only N months offline (IMAP)
# ---------------------------------------------------------------------
function Disable-AllOutlookAddins {
    $n = 0
    foreach ($a in @(Get-OutlookAddins)) { if (Set-TrackedReg $a.Path 'LoadBehavior' 2) { $n++ } }
    if ($n -gt 0) { Write-Done ('Outlook add-ins turned off: ' + $n + ' (applies when Outlook restarts).') } else { Write-Done 'No Outlook add-ins are loading.' }
}
function Set-OutlookOfflineMonths {
    $months = [int](Get-Cfg 'outlookOfflineMonths')
    $hive = Get-UserHive
    if (-not $hive -or $months -lt 1) { return }
    $root = $hive + '\Software\Microsoft\Office\16.0\Outlook\Profiles'
    if (-not (Test-Path -LiteralPath $root)) { Write-Skip 'No Outlook 2016 profile found.'; return }
    $n = 0
    foreach ($profileKey in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $accounts = $profileKey.PSPath + '\9375CFF0413111d3B88A00104B2A6676'
        foreach ($acct in @(Get-ChildItem -LiteralPath $accounts -ErrorAction SilentlyContinue)) {
            if (-not (Get-RegValueRaw $acct.PSPath 'IMAP Server').Exists) { continue }
            $now = Get-RegValueRaw $acct.PSPath 'IMAP months to sync'
            if ($now.Exists -and [int]$now.Value -eq $months) { continue }
            if (Set-TrackedReg $acct.PSPath 'IMAP months to sync' $months 'DWord') { $n++ }
        }
    }
    Write-Done ('Outlook keeps the last ' + $months + ' months of mail on this PC (' + $n + ' account(s) changed now; older mail stays on the server).')
}
function Set-OfficeStartOptions([string]$Hive) {
    if (-not $Hive) { return }
    [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Office\16.0\Word\Options') 'DisableBootToOfficeStart' 1)
    [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Office\16.0\Excel\Options') 'DisableBootToOfficeStart' 1)
    [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Office\16.0\Common\Graphics') 'DisableAnimations' 1)
    [void](Set-TrackedReg ($Hive + '\Software\Microsoft\Office\16.0\Common\Feedback') 'Enabled' 0)
    # Keep the taskbar jump list (recent Word / Excel files): make sure recent-file tracking is on.
    $adv = $Hive + '\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $track = Get-RegValueRaw $adv 'Start_TrackDocs'
    if ($track.Exists -and [int]$track.Value -eq 0) { [void](Set-TrackedReg $adv 'Start_TrackDocs' 1) }
    Write-Done 'Word and Excel open straight to work, without the start screen. Recent files on the taskbar stay.'
}

# ---------------------------------------------------------------------
# Slow start: only Viber at sign-in, everything else after a few minutes
# ---------------------------------------------------------------------
function Get-SlowStartList {
    try { if (Test-Path -LiteralPath $script:SlowStartFile) { return @((Get-Content -LiteralPath $script:SlowStartFile -Raw -Encoding UTF8 | ConvertFrom-Json).items) } } catch {}
    return @()
}
function Test-StartupDisabledByUser([string]$ApprovedKey, [string]$Name) {
    $a = Get-RegValueRaw $ApprovedKey $Name
    return ($a.Exists -and ($a.Value -is [byte[]]) -and ($a.Value[0] -band 1))
}
function Update-SlowStart {
    $items = @(Get-SlowStartList)
    $profile = Get-InteractiveProfile
    $keep = '(?i)viber|SecurityHealth|ctfmon'
    $sources = @(
        @{ Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Sid = ''; Approved = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        @{ Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Sid = ''; Approved = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
    )
    if ($profile.SID) {
        $h = 'Registry::HKEY_USERS\' + $profile.SID
        $sources += @{ Path = ($h + '\Software\Microsoft\Windows\CurrentVersion\Run'); Sid = $profile.SID; Approved = ($h + '\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run') }
    }
    $added = 0
    foreach ($src in $sources) {
        if (-not (Test-Path -LiteralPath $src.Path)) { continue }
        $key = Get-Item -LiteralPath $src.Path
        foreach ($n in @($key.GetValueNames())) {
            $cmd = [string]$key.GetValue($n)
            if (-not $cmd -or ($n + ' ' + $cmd) -match $keep) { continue }
            if (Test-StartupDisabledByUser $src.Approved $n) { continue }
            $items += [pscustomobject]@{ name = $n; sid = $src.Sid; command = $cmd }
            [void](Remove-TrackedReg $src.Path $n)
            $added++
        }
    }
    $folders = @(@{ Path = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'); Sid = ''; Sub = 'all' })
    if ($profile.LocalPath) { $folders += @{ Path = (Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'); Sid = $profile.SID; Sub = $profile.SID } }
    foreach ($fd in $folders) {
        foreach ($f in @(Get-ChildItem -LiteralPath $fd.Path -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '(?i)^\.(lnk|url|exe|bat|cmd)$' })) {
            if ($f.Name -match $keep) { continue }
            $dest = Join-Path $script:ToolRoot ('SlowStart\' + $fd.Sub + '\' + $f.Name)
            try {
                New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
                Move-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop
                Add-UndoListItem -Name 'MovedShortcuts' -Item @{ Source = $f.FullName; Backup = $dest }
                $items += [pscustomobject]@{ name = $f.BaseName; sid = $fd.Sid; command = ('"' + $dest + '"') }
                $added++
            } catch {}
        }
    }
    $items = @($items | Group-Object { ([string]$_.sid) + '|' + ([string]$_.command) } | ForEach-Object { $_.Group[0] })
    $doc = [ordered]@{ gapSeconds = [int](Get-Cfg 'slowStartGapSeconds'); items = @($items) }
    New-Item -ItemType Directory -Path $script:ToolRoot -Force | Out-Null
    ($doc | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $script:SlowStartFile -Encoding UTF8
    $runner = @'
$ErrorActionPreference = 'SilentlyContinue'
$doc = Get-Content -LiteralPath 'C:\ProgramData\Office-PC-Care-Toolkit\slow-start.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$shell = New-Object -ComObject WScript.Shell
foreach ($item in @($doc.items)) {
    if ($item.sid -and $item.sid -ne $me) { continue }
    try { [void]$shell.Run([string]$item.command, 7, $false) } catch {}
    Start-Sleep -Seconds ([int]$doc.gapSeconds)
}
'@
    Set-Content -LiteralPath $script:SlowStartScript -Value ($runner.Replace('C:\ProgramData', $env:ProgramData)) -Encoding UTF8
    # wscript starts PowerShell fully hidden (window style 0), so staff never see a console flash.
    $vbs = 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""' + $script:SlowStartScript + '""", 0, False'
    Set-Content -LiteralPath $script:SlowStartLauncher -Value $vbs -Encoding ASCII
    Register-SlowStartTask
    Write-Done ('Only Viber opens at sign-in. ' + @($items).Count + ' other startup app(s) open one by one after ' + [int](Get-Cfg 'slowStartDelaySeconds') + ' seconds' + $(if ($added) { ' (' + $added + ' newly moved)' } else { '' }) + '.')
}
function Register-SlowStartTask {
    try {
        $svc = Get-TaskService
        $def = $svc.NewTask(0)
        $def.RegistrationInfo.Description = 'Office PC Care Toolkit: opens startup apps slowly, one by one, after Viber.'
        $def.Settings.Enabled = $true
        $def.Settings.DisallowStartIfOnBatteries = $false
        $def.Settings.StopIfGoingOnBatteries = $false
        $def.Settings.ExecutionTimeLimit = 'PT30M'
        # Normal priority: apps started by this task (VPN, Avro keyboard...) inherit it. The Task Scheduler
        # default (7 = below normal) made them lag whenever the CPU was busy.
        $def.Settings.Priority = 5
        $def.Settings.MultipleInstances = 2
        $def.Principal.GroupId = 'S-1-5-32-545'
        $def.Principal.RunLevel = 0
        $t = $def.Triggers.Create(9)
        $t.Delay = 'PT' + [int](Get-Cfg 'slowStartDelaySeconds') + 'S'
        $a = $def.Actions.Create(0)
        $a.Path = Join-Path $env:WINDIR 'System32\wscript.exe'
        $a.Arguments = '//B //NoLogo "' + $script:SlowStartLauncher + '"'
        [void]$svc.GetFolder('\').RegisterTaskDefinition($script:SlowStartTask, $def, 6, $null, $null, 4)
    } catch { Write-Skip ('Slow start task could not be created: ' + $_.Exception.Message) }
}
function Restore-SlowStart {
    try { (Get-TaskService).GetFolder('\').DeleteTask($script:SlowStartTask, 0) } catch {}
    Remove-Item -LiteralPath $script:SlowStartFile, $script:SlowStartScript, $script:SlowStartLauncher -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------
# VMware: services for VM internet, .vmx memory settings at early boot
# ---------------------------------------------------------------------
function Ensure-VmwareServices([switch]$Restart) {
    $names = @('VMnetDHCP', 'VMware NAT Service', 'VMAuthdService', 'VMUSBArbService')
    $found = 0
    foreach ($n in $names) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        $found++
        if ($svc.StartType -ne 'Automatic') { try { Set-Service -Name $n -StartupType Automatic -ErrorAction Stop } catch { & sc.exe config "$n" start= auto 2>&1 | Out-Null } }
        try {
            if ($Restart) { Restart-Service -Name $n -Force -ErrorAction Stop }
            elseif ($svc.Status -ne 'Running') { Start-Service -Name $n -ErrorAction Stop }
        } catch {}
    }
    try { Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.InterfaceDescription -match '(?i)VMware Virtual Ethernet Adapter' -and $_.Status -eq 'Disabled' } | Enable-NetAdapter -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    return $found
}
function Invoke-VmInternetFix {
    Write-Header 'INTERNET WORKS ON THE PC BUT NOT INSIDE THE VM'
    if (-not (Confirm-Action 'Restarts the VMware network services (NAT, DHCP) on this PC and turns on the VMware network adapters.' 'The VM keeps running. VPN, files and everything inside the VM.' 'VM internet pauses for a few seconds.' 'About 30 seconds.')) { return }
    $found = Ensure-VmwareServices -Restart
    if ($found -eq 0) { Write-Skip 'VMware services were not found on this PC.'; return }
    & ipconfig.exe /flushdns | Out-Null
    Write-Done 'VMware network services restarted. Wait 30 seconds, then try the internet inside the VM again.'
    Write-Host 'If it still does not work, disconnect and connect the VPN once, then try again.' -ForegroundColor Cyan
}
function Get-VmxFiles {
    $files = @()
    foreach ($userDir in @(Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue)) {
        $vmDir = Join-Path $userDir.FullName 'AppData\Roaming\VMware'
        foreach ($name in @('inventory.vmls', 'preferences.ini')) {
            $f = Join-Path $vmDir $name
            if (-not (Test-Path -LiteralPath $f)) { continue }
            foreach ($line in @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
                if ($line -match '(?i)^\s*(vmlist\d+\.config|pref\.mruVM\d+\.filename)\s*=\s*"([^"]+\.vmx)"') { $files += $Matches[2] }
            }
        }
    }
    return @($files | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
}
function Set-VmxMemorySettings {
    if (@(Get-Process -Name 'vmware-vmx' -ErrorAction SilentlyContinue).Count -gt 0) { Write-Skip 'A VM is running. VM settings will be applied at the next PC start.'; return }
    $want = [ordered]@{ 'MemTrimRate' = '"0"'; 'sched.mem.pshare.enable' = '"FALSE"'; 'mainMem.useNamedFile' = '"FALSE"' }
    $n = 0
    foreach ($vmx in @(Get-VmxFiles)) {
        try {
            if (Test-Path -LiteralPath ($vmx + '.lck')) { continue }
            $backup = Join-Path $script:ToolRoot ('Backup\vmx\' + ([BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($vmx.ToLowerInvariant()))).Replace('-', '')) + '.vmx')
            if (-not (Test-Path -LiteralPath $backup)) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
                Copy-Item -LiteralPath $vmx -Destination $backup -Force
                Add-UndoListItem -Name 'VmxBackups' -Item @{ Vmx = $vmx; Backup = $backup }
            }
            $lines = @(Get-Content -LiteralPath $vmx)
            $changed = $false
            foreach ($k in $want.Keys) {
                $line = $k + ' = ' + $want[$k]
                if ($lines -contains $line) { continue }
                $lines = @($lines | Where-Object { $_ -notmatch ('^\s*' + [regex]::Escape($k) + '\s*=') }) + $line
                $changed = $true
            }
            if ($changed) { [IO.File]::WriteAllLines($vmx, [string[]]$lines); $n++ }
        } catch { Write-Skip ('VM settings not changed for ' + $vmx + ': ' + $_.Exception.Message) }
    }
    Write-Done ('VM memory settings checked (' + $n + ' VM file(s) updated).')
}
function Register-EarlyBootTask {
    if (-not (Install-ToolkitCopy)) { return }
    try {
        $svc = Get-TaskService
        $def = New-ToolkitTaskDefinition -Service $svc -Mode 'early'
        [void]$def.Triggers.Create(8)
        [void]$svc.GetFolder('\').RegisterTaskDefinition($script:EarlyTask, $def, 6, 'SYSTEM', $null, 5)
    } catch { Write-Skip ('Early boot task could not be created: ' + $_.Exception.Message) }
}
function Remove-VmwareTuning {
    # Build 3: VMware memory tuning (MemTrimRate 0, minVmMemPct 100, useNamedFile FALSE) kept VM memory
    # locked in RAM and starved Outlook/Viber on 8 GB PCs. Remove exactly those lines, nothing else.
    $ours = '^\s*(MemTrimRate\s*=\s*"0"|sched\.mem\.pshare\.enable\s*=\s*"FALSE"|mainMem\.useNamedFile\s*=\s*"FALSE"|prefvmx\.minVmMemPct\s*=\s*"100")\s*$'
    $targets = @()
    foreach ($product in @('VMware Workstation', 'VMware Player')) { $targets += (Join-Path $env:ProgramData ('VMware\' + $product + '\config.ini')) }
    $vmRunning = @(Get-Process -Name 'vmware-vmx' -ErrorAction SilentlyContinue).Count -gt 0
    if (-not $vmRunning) { $targets += @(Get-VmxFiles) }
    $n = 0
    foreach ($file in $targets) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        if ($file -like '*.vmx' -and (Test-Path -LiteralPath ($file + '.lck'))) { continue }
        try {
            $lines = @(Get-Content -LiteralPath $file)
            $kept = @($lines | Where-Object { $_ -notmatch $ours })
            if ($kept.Count -ne $lines.Count) { [IO.File]::WriteAllLines($file, [string[]]$kept); $n++ }
        } catch {}
    }
    Set-UndoFlag 'VMwareConfig' $null
    if ($n -gt 0) { Write-Done ('VMware memory settings returned to normal in ' + $n + ' file(s).') }
}
function Invoke-EarlyBoot {
    Write-Header ('EARLY BOOT ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
    [void](Ensure-VmwareServices)
    Remove-VmwareTuning
}

# ---------------------------------------------------------------------
# Shortcut, apply-all, setup, auto care
# ---------------------------------------------------------------------
function New-PcCareShortcut {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($script:ShortcutFile)
        $lnk.TargetPath = $script:InstalledBat
        $lnk.WorkingDirectory = $script:ToolRoot
        $lnk.IconLocation = (Join-Path $env:WINDIR 'System32\shell32.dll') + ',238'
        $lnk.Description = 'Fix common PC problems'
        $lnk.Save()
        Write-Done 'A "PC Care" shortcut is on every desktop.'
    } catch { Write-Skip ('Desktop shortcut not created: ' + $_.Exception.Message) }
}
function Invoke-ApplyAll {
    $hive = Get-UserHive
    Set-ServicesFromConfig
    Disable-HeavyWindowsTasks
    Enable-MemorySavers
    Set-DefenderLight
    Set-ChromePolicies
    if (Get-Cfg 'outlookDisableAllAddins') { Disable-AllOutlookAddins }
    Set-OutlookOfflineMonths
    Set-OfficeStartOptions $hive
    Ensure-ViberStartup
    Update-SlowStart
    [void](Ensure-VmwareServices)
    Remove-VmwareTuning
    [void](Restore-Tracked { param($id) $id -match 'HiberbootEnabled' })
}
function Invoke-OneTimeSetup {
    Write-Header 'PC SETUP'
    Show-ActionInfo 'Sets this PC up for office work: faster Windows, only Viber at sign-in and other apps slowly after, Windows Update off, Edge off, lighter Chrome and Outlook, daily automatic care and updates from IT. Once a day it sends PC info (hardware, apps, errors) to the IT dashboard.' 'Files, emails, Viber chats, VPN apps, the VM, browser passwords, bookmarks and extensions already installed.' 'Nothing. Some changes need one restart.' 'About 3-5 minutes.'
    Write-MajorWarning 'Windows Update will be OFF: Windows will not get new security updates. Virus definitions still update every day.'
    if (-not (Ask-YesNo 'Set up this PC now?')) { Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow; return }
    Write-Step '[1/7] Installing the toolkit'
    if (Install-ToolkitCopy) {
        Save-DefaultConfigIfMissing
        if ((Get-InstalledBuild) -lt $script:ToolkitBuild) { Set-InstalledBuild $script:ToolkitBuild }
        Write-Done ('Toolkit installed: ' + $script:InstalledBat)
        New-PcCareShortcut
    } else { Write-Skip 'Toolkit copy failed.' }
    Write-Step '[2/7] Full speed setup'
    Invoke-FullOptimization
    Write-Step '[3/7] Apps, Outlook, Chrome, services'
    Invoke-ApplyAll
    Write-Step '[4/7] Microsoft Edge'
    [void](Set-EdgeOff)
    Write-Step '[5/7] Windows Update'
    try { [void](Invoke-AsSystem 'wu-off'); if ((Get-Service wuauserv -ErrorAction SilentlyContinue).StartType -eq 'Disabled') { Write-Done 'Windows Update is OFF.' } else { Write-Skip 'Windows Update could not be fully turned off. Auto Care will try again.' } }
    catch { Write-Skip ('Windows Update step failed: ' + $_.Exception.Message) }
    Write-Step '[6/7] VM settings'
    Remove-VmwareTuning
    Write-Step '[7/7] Automatic care and updates'
    if (Register-AutoCareTask) { Write-Done 'Auto Care runs 10 minutes after the PC starts, and every day at 3:30 PM and 8:30 PM Bangladesh time. It also installs updates sent by IT.' }
    Register-EarlyBootTask
    Set-Content -LiteralPath $script:SetupMarker -Value (Get-Date -Format 's') -Encoding ASCII
    Write-Host ''
    Write-Host 'PC setup finished. Restart the PC once to finish.' -ForegroundColor Green
    Write-MajorWarning 'Restarting closes all apps and the VM. Save your work first.'
    if (Ask-YesNo 'Restart the PC now?') { & shutdown.exe /r /t 15 /c 'Office PC Care Toolkit: restarting to finish setup.' }
}
function Invoke-AutoCare {
    Write-Header ('AUTO CARE ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ' (build ' + (Get-InstalledBuild) + ')')
    $updated = Invoke-SelfUpdate
    if ($updated -eq $true -and -not $env:PCTOOLKIT_CHAINED -and (Test-Path -LiteralPath $script:InstalledBat)) {
        # Run the rest of Auto Care with the NEW build right away, so fixes apply now, not hours later.
        $env:PCTOOLKIT_CHAINED = '1'
        Write-Note 'Running Auto Care again with the new build.'
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') -ArgumentList ('/d /c ""' + $script:InstalledBat + '" auto"') -WindowStyle Hidden -Wait
        return
    }
    if (-not (Test-Path -LiteralPath $script:SetupMarker)) { Write-Skip 'PC setup has not been run. Auto Care only cleans temporary files.'; Invoke-DailyCare; return }
    Invoke-DailyCare
    Invoke-ApplyAll
    if (Get-UndoFlag 'UpdatesOff') { Set-WindowsUpdateOff }
    if (Get-UndoFlag 'EdgeOff') { [void](Set-EdgeOff) }
    Update-DefenderSignatures
    Send-PcReport
}
function Show-InternetMenu {
    while ($true) {
        Clear-Host
        Write-Header 'INTERNET NOT WORKING'
        Write-Host '  1. Fix internet connection                 [1 min]' -ForegroundColor Green
        Write-Host '  2. Internet works on PC but NOT inside the VM [30 sec]' -ForegroundColor Green
        Write-Host '  3. Reset all network settings              [Only if 1 did not help - restart needed]' -ForegroundColor Yellow
        Write-Host '  0. Back'
        switch (Read-MenuChoice) {
            '1' { Invoke-InternetOneClickFix; Wait-Back }
            '2' { Invoke-VmInternetFix; Wait-Back }
            '3' { Show-ActionInfo 'Resets Windows network settings to default.' 'Files, apps and VPN apps.' 'Custom IP or DNS settings. Restart needed.' 'About 2 minutes + restart.'; Invoke-NetworkToolsReset; Wait-Back }
            '0' { return }
            default { Write-Host 'Choose a number from the list.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}

# ---------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------
function Read-MenuChoice { return ([string](Read-Host 'Type a number and press Enter')).Trim() }
function Show-SlowMenu {
    while ($true) {
        Clear-Host
        Write-Header 'MY PC IS SLOW'
        Write-Host '  1. Quick clean-up            [Old temporary files - 1 min]' -ForegroundColor Green
        Write-Host '  2. Full speed setup          [Makes Windows lighter - 3 min, restart]' -ForegroundColor Green
        Write-Host '  3. Close heavy apps          [See which apps use most memory]'
        Write-Host '  4. Choose startup apps       [Pick what opens with Windows]'
        Write-Host '  0. Back'
        switch (Read-MenuChoice) {
            '1' { Show-ActionInfo 'Deletes old temporary and error-report files.' 'Your files, Downloads, browser data, emails and chats.' 'Nothing.' 'About 1 minute.'; Invoke-DailyCare; Wait-Back }
            '2' { if (Confirm-Action 'Makes Windows lighter: fewer effects, no background extras, high performance power, bigger memory file, VMware memory in RAM, non-work startup apps off, temp clean-up.' 'Files, emails, chats, VPN, the VM and every work app.' 'Nothing. Restart once to finish.' 'About 3 minutes.') { Invoke-FullOptimization }; Wait-Back }
            '3' { Show-RamRelief; Wait-Back }
            '4' { Show-StartupMenu }
            '0' { return }
            default { Write-Host 'Choose a number from the list.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}
function Show-FrozenMenu {
    while ($true) {
        Clear-Host
        Write-Header 'AN APP IS FROZEN / NOT RESPONDING'
        Write-Host '  1. An app window is stuck     [Find and close frozen apps]' -ForegroundColor Green
        Write-Host '  2. Taskbar or desktop stuck   [Restart File Explorer]' -ForegroundColor Green
        Write-Host '  0. Back'
        switch (Read-MenuChoice) {
            '1' { Show-FrozenApps; Wait-Back }
            '2' { Show-ActionInfo 'Restarts the taskbar and desktop.' 'All apps, files, VPN and the VM keep running.' 'Open File Explorer windows close.' 'About 10 seconds.'; Invoke-ExplorerRestart; Wait-Back }
            '0' { return }
            default { Write-Host 'Choose a number from the list.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}
function Show-OutlookMenu {
    while ($true) {
        Clear-Host
        Write-Header 'OUTLOOK PROBLEM'
        Write-Host '  1. Mail not sending / receiving  [Restart + sync - 1 min]' -ForegroundColor Green
        Write-Host '  2. Outlook is slow               [Lighter settings - 1 min]' -ForegroundColor Green
        Write-Host '  3. Outlook does not open         [Safe start without add-ins]' -ForegroundColor Green
        Write-Host '  4. Attachments do not open       [Clean attachment folder]' -ForegroundColor Green
        Write-Host '  5. Search does not find emails   [Rebuild search - finishes later]' -ForegroundColor Green
        Write-Host '  6. Folders on the left look wrong [Reset the folder panel]' -ForegroundColor Green
        Write-Host '  7. Old reminders keep popping up [Clear reminders]' -ForegroundColor Green
        Write-Host '  8. Outlook shows a data file error [Repair mail file - 10-60 min]' -ForegroundColor Yellow
        Write-Host '  0. Back'
        switch (Read-MenuChoice) {
            '1' { Invoke-OutlookFullFix; Wait-Back }
            '2' { Invoke-OutlookFaster; Wait-Back }
            '3' { Show-ActionInfo 'Starts Outlook without add-ins to find what stops it from opening.' 'All emails and accounts.' 'An email you are still writing.' 'About 1 minute.'; Invoke-OutlookSafeMode; Wait-Back }
            '4' { Clear-OutlookAttachmentCache; Wait-Back }
            '5' { Invoke-SearchRebuild; Wait-Back }
            '6' { Show-ActionInfo 'Resets the folder panel on the left side of Outlook.' 'All emails, folders and accounts.' 'Your custom folder order and Favorites list.' 'About 1 minute.'; Invoke-OutlookAction 'Nav'; Wait-Back }
            '7' { Invoke-OutlookCleanReminders; Wait-Back }
            '8' { Show-ActionInfo 'Backs up and repairs the Outlook mail file.' 'A backup copy is made first. Emails on the server stay.' 'Outlook cannot be used while it runs.' '10-60 minutes.'; Invoke-OutlookDataFileRepair; Wait-Back }
            '0' { return }
            default { Write-Host 'Choose a number from the list.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}
function Show-OfficeMenu {
    while ($true) {
        Clear-Host
        Write-Header 'WORD / EXCEL PROBLEM'
        Write-Host '  1. Word is stuck / not responding'  -ForegroundColor Green
        Write-Host '  2. Excel is stuck / not responding' -ForegroundColor Green
        Write-Host '  3. Find a file I did not save'      -ForegroundColor Green
        Write-Host '  4. Word or Excel closes when opening [Safe Mode]' -ForegroundColor Green
        Write-Host '  5. Repair Word / Excel / Outlook     [10-20 min]' -ForegroundColor Yellow
        Write-Host '  0. Back'
        switch (Read-MenuChoice) {
            '1' { Invoke-OfficeAppUnstick 'WINWORD' 'Word' 'WINWORD.EXE'; Wait-Back }
            '2' { Invoke-OfficeAppUnstick 'EXCEL' 'Excel' 'EXCEL.EXE'; Wait-Back }
            '3' { Open-UnsavedOfficeFiles; Wait-Back }
            '4' { Start-OfficeSafeMode; Wait-Back }
            '5' { Invoke-OfficeQuickRepair; Wait-Back }
            '0' { return }
            default { Write-Host 'Choose a number from the list.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}
function Show-DeepRepairMenu {
    while ($true) {
        Clear-Host
        Write-Header 'DEEP WINDOWS REPAIR'
        Write-Host '  Use these when the PC keeps having problems after a restart.' -ForegroundColor DarkGray
        Write-Host '  1. Repair Windows files   [30-60 min, PC stays usable but slow]' -ForegroundColor Yellow
        Write-Host '  2. Optimize drives        [10-60 min]' -ForegroundColor Yellow
        Write-Host '  0. Back'
        switch (Read-MenuChoice) {
            '1' { Show-ActionInfo 'Checks and repairs damaged Windows system files.' 'Files, emails, apps and settings.' 'Nothing, but the PC is slow while it runs.' '30-60 minutes.'; Invoke-AdvancedWindowsRepairCleanup; Wait-Back }
            '2' { Show-ActionInfo 'Optimizes the SSD and hard disk.' 'Files and apps.' 'Nothing, but the PC is slow while it runs.' '10-60 minutes.'; Invoke-DriveCare; Wait-Back }
            '0' { return }
            default { Write-Host 'Choose a number from the list.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}
# ---------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------
switch ($script:Mode) {
    'auto'   { Invoke-AutoCare; try { Stop-Transcript | Out-Null } catch {}; exit 0 }
    'wu-off' { Set-WindowsUpdateOff; try { Stop-Transcript | Out-Null } catch {}; exit 0 }
    'wu-on'  { Set-WindowsUpdateOn; try { Stop-Transcript | Out-Null } catch {}; exit 0 }
    'undo-system' { Invoke-UndoAllSystemPart; try { Stop-Transcript | Out-Null } catch {}; exit 0 }
    # IT-only manual commands (admin Command Prompt):  Office-PC-Care-Toolkit-v12.bat undo | edge-on | update-on
    'undo'      { Invoke-UndoAll; [void](Read-Host 'Press Enter to close'); exit 0 }
    'edge-on'   { Set-EdgeOn; [void](Read-Host 'Press Enter to close'); exit 0 }
    'update-on' { try { [void](Invoke-AsSystem 'wu-on') } catch { Set-WindowsUpdateOn }; [void](Read-Host 'Press Enter to close'); exit 0 }
    'early'  { Invoke-EarlyBoot; try { Stop-Transcript | Out-Null } catch {}; exit 0 }
    'allow-extension' { Add-LocalChromeExtension $script:ExtraArg; [void](Read-Host 'Press Enter to close'); exit 0 }
    'test'   { return }
}

if (-not (Test-Path -LiteralPath $script:SetupMarker)) {
    Clear-Host
    Write-Host 'This PC has not been set up by the Office PC Care Toolkit yet.' -ForegroundColor Cyan
    Invoke-SafeAction { Invoke-OneTimeSetup; Wait-Back }
}

$exitToolkit = $false
while (-not $exitToolkit) {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host '              OFFICE PC CARE TOOLKIT v13' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ("  PC: {0}   build {1}      What is the problem?" -f $env:COMPUTERNAME, (Get-InstalledBuild)) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   1. My PC is slow' -ForegroundColor Green
    Write-Host '   2. An app is frozen / not responding' -ForegroundColor Green
    Write-Host '   3. Outlook problem' -ForegroundColor Green
    Write-Host '   4. Word / Excel problem' -ForegroundColor Green
    Write-Host '   5. Viber problem' -ForegroundColor Green
    Write-Host '   6. Internet not working' -ForegroundColor Green
    Write-Host '   7. VPN not connecting' -ForegroundColor Green
    Write-Host '   8. Deep Windows repair      [30-60 min]' -ForegroundColor Yellow
    Write-Host '   9. Send report to IT' -ForegroundColor Cyan
    Write-Host '  10. Run PC setup again       [3-5 min]' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '   0. Exit'
    Write-Host ''
    switch (Read-MenuChoice) {
        '1'  { Invoke-SafeAction { Show-SlowMenu } }
        '2'  { Invoke-SafeAction { Show-FrozenMenu } }
        '3'  { Invoke-SafeAction { Show-OutlookMenu } }
        '4'  { Invoke-SafeAction { Show-OfficeMenu } }
        '5'  { Invoke-SafeAction { Show-ActionInfo 'Closes Viber, clears its stuck screen files and opens it again.' 'Chats, photos, contacts and your Viber account.' 'A call that is going on right now.' 'About 1 minute.'; Invoke-ViberFix 'Full'; Ensure-ViberStartup; Wait-Back } }
        '6'  { Invoke-SafeAction { Show-InternetMenu } }
        '7'  { Invoke-SafeAction { Show-VpnMenu } }
        '8'  { Invoke-SafeAction { Show-DeepRepairMenu } }
        '9'  { Invoke-SafeAction { Invoke-SendReportToIT; Wait-Back } }
        '10' { Invoke-SafeAction { Invoke-OneTimeSetup; Wait-Back } }
        '0'  { $exitToolkit = $true }
        default { Write-Host 'Choose a number from 0 to 10.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
    }
}

Write-Host ''
Write-Host 'Toolkit v13 closed.' -ForegroundColor Green
if (Test-Path -LiteralPath $script:LogFile) { Write-Host ('Log: ' + $script:LogFile) -ForegroundColor DarkGray }
