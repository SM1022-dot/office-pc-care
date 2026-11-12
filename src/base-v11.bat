@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Office PC Care Toolkit v11.0
set "PCTOOLKIT_FILE=%~f0"

rem Always run the toolkit in an elevated CMD window.
fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting Administrator permission...
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$f=$env:PCTOOLKIT_FILE; $arg='/d /c '+[char]34+[char]34+$f+[char]34+[char]34; Start-Process -FilePath $env:ComSpec -ArgumentList $arg -WorkingDirectory (Split-Path -LiteralPath $f -Parent) -Verb RunAs"
    exit /b
)

rem Run the PowerShell payload stored below. The unique marker avoids matching this command itself.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$f=$env:PCTOOLKIT_FILE; try { [Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false) } catch {}; $lines=[IO.File]::ReadAllLines($f); $marker='#<OFFICE_PC_CARE_PAYLOAD_20261105_V11_0>'; $i=[Array]::IndexOf($lines,$marker); if($i -lt 0){ Write-Host 'Toolkit payload was not found.' -ForegroundColor Red; exit 2 }; $body=[string]::Join([Environment]::NewLine,$lines[($i+1)..($lines.Length-1)]); & ([scriptblock]::Create($body))"
if errorlevel 1 (
    echo.
    echo The toolkit stopped because of an error.
    pause
)
endlocal
exit /b

#<OFFICE_PC_CARE_PAYLOAD_20261105_V11_0>
# Office PC Care Toolkit v11.0 - Windows PowerShell 5.1 compatible.
# Offline-first. Does not download tools or change VMware/VPN services.
$ErrorActionPreference = 'Continue'
# Designed for Windows PowerShell 5.1 on Windows 10/11. Unsupported components are skipped safely.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
try { $Host.UI.RawUI.WindowTitle = 'Office PC Care Toolkit v11.0' } catch {}

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
    $freed = [int64]0
    foreach ($target in $targets) {
        $result = Remove-OldFiles -Path $target.Path -OlderThanDays $target.Days -Label $target.Label
        $freed += $result.Bytes
    }
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
    Write-MajorWarning 'IT ONLY - AT YOUR OWN RISK. Use only when Outlook reports a data-file error.'
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
    Write-MajorWarning 'IT ONLY - AT YOUR OWN RISK. Use only when Outlook will not open or keeps crashing.'
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
function Show-OutlookMenu {
    while ($true) {
        Clear-Host
        Write-Header 'OUTLOOK FIX - MAIL / DATA / STARTUP'
        Write-Host '  1. One-Click Outlook Fix   [Mail + sync + restart]' -ForegroundColor Green
        Write-Host '  2. Outlook Data File Repair [OST / PST backup + repair]' -ForegroundColor Red
        Write-Host '     IT ONLY - AT YOUR OWN RISK' -ForegroundColor Red
        Write-Host '  3. Outlook Not Opening?    [Safe Mode / add-in test]' -ForegroundColor Red
        Write-Host '     IT ONLY - AT YOUR OWN RISK' -ForegroundColor Red
        Write-Host '  0. Back'
        $pick = Read-Host 'Choose a number'
        switch ($pick) {
            '1' { Invoke-OutlookFullFix; Wait-Back }
            '2' { Invoke-OutlookDataFileRepair; Wait-Back }
            '3' { Invoke-OutlookSafeMode; Wait-Back }
            '0' { return }
            default { Write-Host 'Choose 0, 1, 2 or 3.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
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
    Write-MajorWarning 'ONLY FOR IT STAFF - AT YOUR OWN RISK.'
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
function Show-InternetMenu {
    while ($true) {
        Clear-Host
        Write-Header 'INTERNET FIX - CONNECTION PROBLEMS'
        Write-Host '  1. Internet Problem Fix  [DNS + IP renew]'
        Write-Host '  2. Reset Network Tools   [IT ONLY - AT YOUR OWN RISK]' -ForegroundColor Red
        Write-Host '  0. Back'
        $pick = Read-Host 'Choose a number'
        switch ($pick) {
            '1' { Invoke-InternetOneClickFix; Wait-Back }
            '2' { Invoke-NetworkToolsReset; Wait-Back }
            '0' { return }
            default { Write-Host 'Choose 0, 1 or 2.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
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
        # v13: use the toolkit launcher when present, so Viber opens maximized and at above-normal priority.
        $launcher = Join-Path $env:ProgramData 'Office-PC-Care-Toolkit\viber-start.vbs'
        if (Test-Path -LiteralPath $launcher) { [void](Start-UserProgram -Path (Join-Path $env:WINDIR 'System32\wscript.exe') -Arguments ('//B //NoLogo "' + $launcher + '"')) }
        else { Start-UserProgram -Path $ViberExe }
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
    Write-MajorWarning 'ONLY FOR IT STAFF - USE AT YOUR OWN RISK.'
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
                    $protected = ($combined -match '(?i)(viber|outlook|express.?vpn|nordvpn|\bvpn\b|vmware|browser.?lock|lock.?browser|defender|antivirus|securityhealth|realtek|audio|touchpad|synaptics|intel|nvidia|amd)')
                    $entries += [pscustomobject]@{ Kind='Registry'; Name=[string]$name; Value=[string]$value; ValueKind=$kind; Path=$runPath; Protected=$protected; Detail=[string]$value }
                } catch {}
            }
        } catch { Write-Host ('Could not read user startup settings: ' + $_.Exception.Message) -ForegroundColor Yellow }
    }

    $startupFolder = Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
    if (Test-Path -LiteralPath $startupFolder) {
        try {
            foreach ($file in (Get-ChildItem -LiteralPath $startupFolder -File -Filter '*.lnk' -Force -ErrorAction Stop)) {
                $protected = ($file.Name -match '(?i)(viber|outlook|express.?vpn|nordvpn|vpn|vmware|browser.?lock|lock.?browser|defender|antivirus|security|realtek|audio|touchpad|synaptics|intel|nvidia|amd)')
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
        Write-MajorWarning 'IT ONLY - AT YOUR OWN RISK. Do not disable apps you do not recognise.'
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
    Write-MajorWarning 'ONLY FOR IT STAFF - USE AT YOUR OWN RISK.'
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
    Write-MajorWarning 'ONLY FOR IT STAFF - USE AT YOUR OWN RISK.'
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

function Show-PCSpeedMenu {
    while ($true) {
        Clear-Host
        Write-Header 'PC SPEED TOOLS - LOW-END PC'
        Write-Host '  1. One-Click Speed Optimization  [Visual + startup]' -ForegroundColor Green
        Write-Host '  2. RAM Relief                    [IT ONLY - AT YOUR OWN RISK]' -ForegroundColor Red
        Write-Host '  3. VMware Safety                 [IT ONLY - AT YOUR OWN RISK]' -ForegroundColor Red
        Write-Host '  4. Restart Explorer              [IT ONLY - AT YOUR OWN RISK]' -ForegroundColor Red
        Write-Host '  0. Back'
        $pick = Read-Host 'Choose a number'
        switch ($pick) {
            '1' { Invoke-OneClickSpeedOptimization; Wait-Back }
            '2' { Write-MajorWarning 'ONLY FOR IT STAFF - USE AT YOUR OWN RISK.'; Show-RamRelief; Wait-Back }
            '3' { Write-MajorWarning 'ONLY FOR IT STAFF - USE AT YOUR OWN RISK.'; Show-VMwareCare; Wait-Back }
            '4' { Write-MajorWarning 'ONLY FOR IT STAFF - USE AT YOUR OWN RISK.'; Invoke-ExplorerRestart; Wait-Back }
            '0' { return }
            default { Write-Host 'Choose 0, 1, 2, 3 or 4.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}
function Invoke-WindowsFileRepair {
    Write-Header 'REPAIR WINDOWS FILES'
    Write-MajorWarning 'ONLY FOR IT STAFF - USE AT YOUR OWN RISK.'
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
    Write-MajorWarning 'IT ONLY - AT YOUR OWN RISK.'
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
    Write-MajorWarning 'ONLY FOR IT STAFF - USE AT YOUR OWN RISK.'
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
    Write-MajorWarning 'ONLY FOR IT STAFF - USE AT YOUR OWN RISK.'
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
function Show-SystemCareMenu {
    while ($true) {
        Clear-Host
        Write-Header 'ADVANCED SYSTEM CARE'
        Write-MajorWarning 'IT ONLY - AT YOUR OWN RISK.'
        Write-MajorWarning 'Heavy jobs can take time and use CPU/disk. Run outside busy office hours.'
        Write-Host '  1. Windows Repair + Cleanup [DISM + SFC + component cleanup]' -ForegroundColor Red
        Write-Host '  2. Optimize Drives           [SSD / HDD care]' -ForegroundColor Red
        Write-Host '  3. Advanced Startup Control  [review / disable / restore]' -ForegroundColor Red
        Write-Host '  0. Back'
        $pick = Read-Host 'Choose a number'
        switch ($pick) {
            '1' { Invoke-AdvancedWindowsRepairCleanup; Wait-Back }
            '2' { Invoke-DriveCare; Wait-Back }
            '3' { Show-StartupMenu; Wait-Back }
            '0' { return }
            default { Write-Host 'Choose 0, 1, 2 or 3.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
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

$exitToolkit = $false
while (-not $exitToolkit) {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host '              OFFICE PC CARE TOOLKIT v11.0' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ("  PC: {0}" -f $env:COMPUTERNAME) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  1. Daily PC Care          [Auto clean]' -ForegroundColor Green
    Write-Host '  2. Outlook Fix            [Mail + data recovery]'
    Write-Host '  3. Viber Fix              [One-click hang repair]' -ForegroundColor Green
    Write-Host '  4. Internet Problem Fix   [DNS + IP]'
    Write-Host '  5. VPN Fix                [Nord / Express reconnect]'
    Write-Host '  6. PC Speed Optimization  [Startup + performance]'
    Write-Host '  7. Advanced System Care   [IT ONLY - AT YOUR OWN RISK]' -ForegroundColor Red
    Write-Host ''
    Write-Host '  0. Exit'
    Write-Host ''
    $choice = Read-Host 'Choose a number'
    switch ($choice) {
        '1' { Invoke-SafeAction { Invoke-DailyCare; Wait-Back } }
        '2' { Invoke-SafeAction { Show-OutlookMenu } }
        '3' { Invoke-SafeAction { Invoke-ViberFix 'Full'; Wait-Back } }
        '4' { Invoke-SafeAction { Show-InternetMenu } }
        '5' { Invoke-SafeAction { Show-VpnMenu } }
        '6' { Invoke-SafeAction { Show-PCSpeedMenu } }
        '7' { Invoke-SafeAction { Show-SystemCareMenu } }
        '0' { $exitToolkit = $true }
        default { Write-Host 'Choose a number from 0 to 7.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
    }
}

Write-Host ''
Write-Host 'Toolkit v11.0 closed.' -ForegroundColor Green
if (Test-Path -LiteralPath $script:LogFile) { Write-Host ('Log: ' + $script:LogFile) -ForegroundColor DarkGray }
try { Stop-Transcript | Out-Null } catch {}
