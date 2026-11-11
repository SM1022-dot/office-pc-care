
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
        updateTask = (& $hasTask 'Office PC Care Toolkit - Update Check')
    }
    $r.chromeExtensions = @(Get-InstalledChromeExtensions)
    return $r
}
function Send-PcReport([switch]$Force) {
    # Once a day, plus right after the toolkit build changes (so the dashboard shows the update at once).
    $stamp = (Get-BdDate) + '|' + (Get-InstalledBuild)
    if (-not $Force -and (Test-Path -LiteralPath $script:ReportDateFile) -and ((Get-Content -LiteralPath $script:ReportDateFile -Raw).Trim() -eq $stamp)) { return }
    try {
        $json = (Get-PcReportData) | ConvertTo-Json -Depth 6 -Compress
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
        $wc = New-Object Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers['Content-Type'] = 'application/json; charset=utf-8'
        try { [void]$wc.UploadString($script:ReportUrl, 'POST', $json) } finally { $wc.Dispose() }
        Set-Content -LiteralPath $script:ReportDateFile -Value $stamp -Encoding ASCII
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
    try { (Get-TaskService).GetFolder('\').DeleteTask('Office PC Care Toolkit - Update Check', 0) } catch {}
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
$script:BuildStamp     = '__TOOLKIT_BUILD__'
$script:ToolkitBuild   = 0
if ($script:BuildStamp -match '^\d+$') { $script:ToolkitBuild = [int]$script:BuildStamp }
$script:UpdateBaseUrl  = 'https://raw.githubusercontent.com/SM1022-dot/office-pc-care/main/toolkit/'
$script:UpdatePublicKey = '__UPDATE_PUBLIC_KEY__'
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
$script:UpdateTask = 'Office PC Care Toolkit - Update Check'
function Register-UpdateCheckTask {
    # Every 15 minutes, silently (SYSTEM, no window): download the small signed manifest; only when IT has
    # published a newer build, install it and run Auto Care with the new code. Nothing is shown to staff.
    if (-not (Install-ToolkitCopy)) { return }
    try {
        $svc = Get-TaskService
        $def = New-ToolkitTaskDefinition -Service $svc -Mode 'update'
        $def.Settings.ExecutionTimeLimit = 'PT30M'
        $def.Settings.Hidden = $true
        $t = $def.Triggers.Create(1)
        $t.StartBoundary = (Get-Date).AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ss')
        $t.Repetition.Interval = 'PT15M'
        [void]$svc.GetFolder('\').RegisterTaskDefinition($script:UpdateTask, $def, 6, 'SYSTEM', $null, 5)
    } catch { Write-Skip ('Update check task could not be created: ' + $_.Exception.Message) }
}
function Invoke-UpdateCheck {
    $updated = Invoke-SelfUpdate
    if ($updated -eq $true -and (Test-Path -LiteralPath $script:InstalledBat)) {
        $env:PCTOOLKIT_CHAINED = '1'
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') -ArgumentList ('/d /c ""' + $script:InstalledBat + '" auto"') -WindowStyle Hidden -Wait
        return $true
    }
    return $false
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
    if (Test-Path -LiteralPath $script:SetupMarker) { Register-UpdateCheckTask }
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
    Register-UpdateCheckTask
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
    'update' {
        $changed = Invoke-UpdateCheck
        try { Stop-Transcript | Out-Null } catch {}
        # Nothing new: do not keep a log file every 15 minutes.
        if (-not $changed) { Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue }
        exit 0
    }
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
