# Sunshine Doctor for Windows PowerShell 5.1 and PowerShell 7.
# Diagnose: powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1
# Repair:   powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1 -Fix
# Preview:  powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1 -Fix -WhatIf
[CmdletBinding()]
param([switch]$Fix, [switch]$WhatIf)

$ErrorActionPreference = 'Stop'
$sunshineData = Join-Path $env:APPDATA 'Sunshine'
$bridgeRoot = Join-Path $env:LOCALAPPDATA 'Sunshine\ltk-bridge'
$bridgeMutex = 'Local\SunshineOfficialLtkBridge'
$installerUrl = 'https://github.com/LeagueToolkit/ltk-manager/releases/download/v1.33.0/LTK.Manager_1.33.0_x64-setup.exe'
$installerHash = 'd615a752940061e683e032506c432851df79e8b39f3732a9576fbedfdc6b5920'
$hostHash = '27de1bfdbf37129e42c12b18cc7b4f75c15d39bcd7afefe65c4c33d0e99fe856'
$legacyDllHash = '0b024a3a839f55ff7cf7ee93d9ed2078bcbb07d3b7f320463d678f8a6209e5ff'
$managerVersions = @{
    'db83114d1bd95bd207ffd79c14b5f701c9583a2287bf9e330943963c1c4b08de' = '1.32.0'
    '67a668db37f66dccc25beb273ff87b66172c134c650f299c6b55f26319d437a6' = '1.33.0'
}
$processNames = @(
    'League of Legends', 'LeagueClient', 'LeagueClientUx', 'LeagueClientUxRender',
    'RiotClientServices', 'RiotClientUx', 'RiotClientUxRender', 'ltk-manager',
    'ltk_patcher_host', 'Sunshine'
)
$compatTargets = @($processNames | ForEach-Object { "$_.exe" })
$layerKey = 'Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
$registryViews = if ([Environment]::Is64BitOperatingSystem) { @('Registry64', 'Registry32') } else { @('Default') }
$sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = [Security.Principal.WindowsPrincipal]::new($identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$runAsAdmin = '(?i)(?<!\S)RUNASADMIN(?!\S)'

function Write-Status($status, $message) {
    $colors = @{ OK = 'Green'; INFO = 'Cyan'; WARN = 'Yellow'; ERROR = 'Red'; FIXED = 'Green' }
    Write-Host "[$status] $message" -ForegroundColor $colors[$status]
}

function Test-Repair($message) {
    if (!$Fix) { return $false }
    if ($WhatIf) {
        Write-Status INFO "Would $message"
        return $false
    }
    return $true
}

function Get-FileDigest($path) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Test-FileSignature($path) {
    return (Get-AuthenticodeSignature -LiteralPath $path).Status -eq 'Valid'
}

function Get-CompatEntries {
    foreach ($hive in 'CurrentUser', 'LocalMachine') {
        foreach ($view in $registryViews) {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
            try {
                $key = $base.OpenSubKey($layerKey)
                if (!$key) { continue }
                try {
                    foreach ($name in $key.GetValueNames()) {
                        if ($name -notmatch '^[A-Za-z]:[\\/]') { continue }
                        if ([IO.Path]::GetFileName($name) -notin $compatTargets) { continue }
                        $value = $key.GetValue($name)
                        if ($value -is [string] -and $value -match $runAsAdmin) {
                            [pscustomobject]@{ Hive = $hive; View = $view; Path = $name }
                        }
                    }
                } finally { $key.Dispose() }
            } finally { $base.Dispose() }
        }
    }
}

function Remove-AdminLayer($entry) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($entry.Hive, $entry.View)
    try {
        $key = $base.OpenSubKey($layerKey, $true)
        if (!$key) { return $false }
        try {
            # Read again so the repair preserves layers added after the scan.
            $value = $key.GetValue($entry.Path)
            if ($value -isnot [string] -or $value -notmatch $runAsAdmin) { return $false }
            $remaining = ($value -replace $runAsAdmin, '').Trim()
            if ($remaining -match '^[~#\s]*$') {
                $key.DeleteValue($entry.Path, $false)
            } else {
                $key.SetValue($entry.Path, $remaining, $key.GetValueKind($entry.Path))
            }
            return $true
        } finally { $key.Dispose() }
    } finally { $base.Dispose() }
}

function Find-LtkManager {
    if ($env:SUNSHINE_LTK_MANAGER) { return $env:SUNSHINE_LTK_MANAGER }
    foreach ($hive in 'CurrentUser', 'LocalMachine') {
        foreach ($view in $registryViews) {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
            try {
                $key = $base.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall\LTK Manager')
                if (!$key) { continue }
                try {
                    $location = ([string]$key.GetValue('InstallLocation')).Trim().Trim('"')
                    if ($location -notmatch '^[A-Za-z]:[\\/]') { continue }
                    $path = [IO.Path]::Combine($location, 'ltk-manager.exe')
                    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
                } finally { $key.Dispose() }
            } finally { $base.Dispose() }
        }
    }
    foreach ($base in $env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA,
        (Join-Path $env:LOCALAPPDATA 'Programs')) {
        if (!$base) { continue }
        $path = Join-Path $base 'LTK Manager\ltk-manager.exe'
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
}

function Test-LeagueGameOpen {
    return $null -ne (Get-Process -Name 'League of Legends' -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-SessionProcesses {
    Get-Process -Name $processNames -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId }
}

function Show-ProcessElevation($processes) {
    if (!$processes.Count) { return }
    try {
        if (!('SunshineDoctorToken' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class SunshineDoctorToken
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(IntPtr token, int infoClass, out int data, int size, out int length);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    public static int Read(int id)
    {
        const uint QueryLimitedInformation = 0x1000;
        const uint TokenQuery = 8;
        const int TokenElevation = 20;
        IntPtr process = OpenProcess(QueryLimitedInformation, false, id);
        if (process == IntPtr.Zero) return -1;
        try {
            IntPtr token;
            if (!OpenProcessToken(process, TokenQuery, out token)) return -1;
            try {
                int elevated, length;
                return GetTokenInformation(token, TokenElevation, out elevated, 4, out length) ? elevated : -1;
            } finally { CloseHandle(token); }
        } finally { CloseHandle(process); }
    }
}
'@
        }
        foreach ($process in $processes) {
            $status = [SunshineDoctorToken]::Read($process.Id)
            if ($status -eq 1) {
                Write-Status WARN "$($process.ProcessName) is running as administrator (PID $($process.Id)). Exit it and reopen normally."
            } elseif ($status -lt 0 -and !$process.HasExited) {
                Write-Status INFO "Could not check the permissions of $($process.ProcessName) (PID $($process.Id))."
            }
        }
    } catch { Write-Status WARN 'Could not check which running programs have administrator permissions.' }
}

function Install-OfficialManager {
    $stage = Join-Path $env:TEMP ('sunshine-doctor-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $stage
    $setup = Join-Path $stage 'LTK.Manager_1.33.0_x64-setup.exe'
    $tls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $tls -bor [Net.SecurityProtocolType]::Tls12
        Write-Status INFO 'Downloading official LTK Manager 1.33.0.'
        Invoke-WebRequest -Uri $installerUrl -UseBasicParsing -TimeoutSec 120 -OutFile $setup
        if ((Get-Item -LiteralPath $setup).Length -ne 24696744 -or (Get-FileDigest $setup) -ne $installerHash) {
            throw 'The official installer did not match the expected size and SHA-256.'
        }
        if (!(Test-FileSignature $setup)) {
            throw 'Windows could not validate the official installer signature.'
        }
        if (Test-LeagueGameOpen) { throw 'A League match opened during the download. Close it and retry.' }
        $process = Start-Process -FilePath $setup -Verb RunAs -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "LTK setup exited with code $($process.ExitCode)." }
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $tls
        Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stage -ErrorAction SilentlyContinue
    }
}

function Get-RecentSunshineLog {
    $log = Join-Path $sunshineData 'logs\sunshine.log'
    if (!(Test-Path -LiteralPath $log -PathType Leaf)) { return }
    Get-Content -LiteralPath $log -Tail 3000
}

function Close-VerifiedManager($managerPath, $process) {
    $started = $process.StartTime
    $null = $process.Handle
    if (!$process.Path -or $process.Path -ne $managerPath -or
        !$managerVersions.ContainsKey([string](Get-FileDigest $process.Path))) {
        throw 'The running Manager does not match the verified installation.'
    }
    if (!(Test-FileSignature $process.Path)) {
        throw 'Windows could not validate the running Manager signature.'
    }
    if (Test-LeagueGameOpen) { throw 'A League match is open.' }
    if (!(Get-SessionProcesses | Where-Object { $_.Id -eq $process.Id -and $_.StartTime -eq $started })) {
        throw 'The Manager process changed during the check.'
    }
    $null = $process.CloseMainWindow()
    if (!$process.WaitForExit(5000)) {
        if (Test-LeagueGameOpen) { throw 'A League match opened while waiting for Manager.' }
        $process.Kill()
        if (!$process.WaitForExit(5000)) { throw 'Manager is still running. Exit it from the tray.' }
    }
}

Write-Host 'Sunshine Doctor'
if ($WhatIf) { Write-Status INFO 'Repair preview.' }
elseif ($Fix) { Write-Status INFO 'Repair mode.' }
else { Write-Status INFO 'Read-only diagnosis. Use -Fix to apply the available repairs.' }

$layers = @(Get-CompatEntries)
if (!$layers.Count) { Write-Status OK 'No Run as administrator compatibility flags found for League, Riot, Sunshine or LTK.' }
$flagsChanged = $false
foreach ($entry in $layers) {
    Write-Status WARN "Run as administrator flag ($($entry.Hive), $($entry.View)) for $($entry.Path)"
    if (!$Fix) { continue }
    if ($entry.Hive -eq 'LocalMachine' -and !$isAdmin) {
        Write-Status WARN 'Run this same -Fix command in an administrator PowerShell to change this machine-wide flag.'
        continue
    }
    if (Test-Repair "remove RUNASADMIN for $($entry.Path).") {
        try {
            if (Remove-AdminLayer $entry) {
                $flagsChanged = $true
                Write-Status FIXED "Removed the administrator flag for $($entry.Path)."
            }
        } catch { Write-Status ERROR "Could not change this flag. $($_.Exception.Message)" }
    }
}
if ($flagsChanged) {
    Write-Status INFO 'Exit Riot Client, Sunshine and LTK Manager from the system tray, then reopen Riot Client and Sunshine normally.'
}
foreach ($scope in 'Process', 'User', 'Machine') {
    if ([Environment]::GetEnvironmentVariable('__COMPAT_LAYER', $scope) -match $runAsAdmin) {
        Write-Status WARN "The $scope __COMPAT_LAYER environment variable contains RUNASADMIN. Check how Riot Client and Sunshine were launched."
    }
}

$configPath = Join-Path $sunshineData 'config.json'
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        $league = (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).paths.league_dir
        $gameDir = if ($league -and (Split-Path $league -Leaf) -eq 'Game') { $league }
                   elseif ($league) { Join-Path $league 'Game' }
        if ($gameDir -and (Test-Path -LiteralPath (Join-Path $gameDir 'League of Legends.exe') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $gameDir 'DATA\FINAL') -PathType Container)) {
            Write-Status OK 'The League folder selected in Sunshine has the game and archive files.'
        } else {
            Write-Status WARN 'The League folder in Sunshine is missing or incomplete. Select the correct folder in Settings > Game setup.'
        }
    } catch { Write-Status WARN 'Sunshine could not read the saved game folder. Check Settings > Game setup.' }
}

$gameOpen = Test-LeagueGameOpen
if ($gameOpen) { Write-Status WARN 'A League match is open. Close the game window before using Apply or repairing LTK.' }
$manager = Find-LtkManager
if (!$manager) {
    Write-Status WARN 'LTK Manager is missing. -Fix can run the verified official 1.33.0 installer.'
    if (!$gameOpen -and (Test-Repair 'download and install verified LTK Manager 1.33.0.')) {
        try {
            Install-OfficialManager
            $manager = Find-LtkManager
            if (!$manager) { throw 'Sunshine could not locate the installed Manager. Open Settings and use Check tool updates.' }
            Write-Status FIXED 'LTK Manager was installed.'
        } catch { Write-Status ERROR "LTK setup did not finish. $($_.Exception.Message)" }
    }
}
$verified = $false
$needsRepair = $false
if ($manager) {
    try {
        $manager = [IO.Path]::GetFullPath($manager)
        $version = $managerVersions[[string](Get-FileDigest $manager)]
        if (!$version) {
            $needsRepair = $true
            Write-Status WARN 'This LTK Manager build is outside the Sunshine 0.17.2 compatibility list. Update Sunshine or install the official LTK Manager 1.33.0 release.'
        } elseif ((Get-FileDigest (Join-Path (Split-Path $manager) 'ltk_patcher_host.exe')) -ne $hostHash -or
            ($version -eq '1.32.0' -and (Get-FileDigest (Join-Path (Split-Path $manager) 'ltk_patcher_dll.dll')) -ne $legacyDllHash)) {
            $needsRepair = $true
            Write-Status WARN 'An official LTK component is missing or has changed. Repair the installation with the official LTK installer.'
        } elseif (!(Test-FileSignature $manager)) {
            $needsRepair = $true
            Write-Status WARN 'Windows could not validate the LTK Manager signature.'
        } else {
            $verified = $true
            Write-Status OK "LTK Manager $version files and Manager signature verified."
        }
    } catch { Write-Status ERROR "Could not verify the LTK installation. $($_.Exception.Message)" }
}
if ($needsRepair -and $Fix) {
    $busy = @(Get-SessionProcesses | Where-Object { $_.ProcessName -like 'Sunshine*' -or
        $_.ProcessName -in @('ltk-manager', 'ltk_patcher_host') })
    if ($gameOpen -or $busy.Count) {
        Write-Status WARN 'Exit Sunshine and LTK from the tray and close the game before repairing the LTK installation.'
    } elseif ($env:SUNSHINE_LTK_MANAGER) {
        Write-Status WARN 'SUNSHINE_LTK_MANAGER selects a custom path. Correct that override before using the standard installer.'
    } elseif (Test-Repair 'run the verified LTK Manager 1.33.0 installer to repair the installation.') {
        try {
            Install-OfficialManager
            $manager = Find-LtkManager
            if (!$manager -or !$managerVersions.ContainsKey([string](Get-FileDigest $manager)) -or
                (Get-FileDigest (Join-Path (Split-Path $manager) 'ltk_patcher_host.exe')) -ne $hostHash -or
                !(Test-FileSignature $manager)) {
                throw 'The installation still differs from the release supported by Sunshine.'
            }
            $verified = $true
            Write-Status FIXED 'LTK Manager installation repaired and verified.'
        } catch { Write-Status ERROR "LTK repair did not finish. $($_.Exception.Message)" }
    }
}

$recentLog = @(Get-RecentSunshineLog)
$lastApply = $recentLog | Where-Object {
    $_ -match 'persistent Manager accepted Apply|sunshine::skins:.*error=|Official Manager patcher ready in|official bridge stderr:|cslol bootstrap failed.*(?:Another bridge owns Manager|LTK Manager could not close)'
} | Select-Object -Last 1
$conflict = $lastApply -match 'Another bridge owns Manager|Manager cleanup incomplete|LTK Manager could not close|Previous bridge supervisor is still active|Manager did not finish stopping'
if ($lastApply -match 'LEAGUE_ELEVATED|MANAGER_ELEVATED') {
    $code = $Matches[0]
    Write-Status INFO "The latest recorded Apply failed with $code. Check the flags above and reopen the affected programs normally."
} elseif ($conflict) {
    Write-Status INFO 'The latest recorded Apply reported an LTK ownership or shutdown error.'
} elseif ($lastApply -match 'patcher ready in (\d+) ms' -and [long]$Matches[1] -ge 30000) {
    Write-Status INFO "The last recorded LTK preparation took $([Math]::Round([long]$Matches[1] / 1000)) seconds. Wait for Apply to be ready before starting a match."
}
if ($recentLog -match 'plugin:dialog\|confirm not allowed by ACL') {
    Write-Status INFO 'A recent Sunshine confirmation dialog was blocked. Include the Sunshine support log if the dialog still fails.'
}

$recovery = @('bridge-session.json', 'settings.runtime.previous.json', 'settings.previous.bin') | Where-Object {
    Test-Path -LiteralPath (Join-Path $bridgeRoot $_) -PathType Leaf
}
if ($recovery) {
    Write-Status INFO 'Sunshine has an LTK session or settings recovery record. Exit Sunshine normally and retry Apply so Sunshine can recover its settings.'
}
$processes = @(Get-SessionProcesses)
Show-ProcessElevation $processes
$runningManager = @($processes | Where-Object ProcessName -EQ 'ltk-manager')
$runningSunshine = @($processes | Where-Object { $_.ProcessName -like 'Sunshine*' })
if (($conflict -or $recovery) -and $processes.ProcessName -contains 'ltk_patcher_host' -and !$runningManager.Count) {
    Write-Status WARN 'An LTK patcher is still running without its Manager. Restart Windows if it does not exit on its own.'
}
if (($conflict -or $recovery) -and ($runningManager.Count -or $runningSunshine.Count)) {
    if ($runningSunshine.Count) {
        Write-Status WARN 'Sunshine is still open. Quit it from the tray so the bridge can release Manager.'
    } elseif ($runningManager.Count -ne 1 -or !$verified) {
        Write-Status WARN 'Exit LTK Manager from the tray before retrying Apply.'
    } elseif (!$gameOpen) {
        Write-Status WARN 'A verified Manager is still running after an LTK conflict. -Fix can close it.'
        if (Test-Repair 'close the verified conflicting LTK Manager process.') {
            $mutex = [Threading.Mutex]::new($false, $bridgeMutex)
            $acquired = $false
            try {
                try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
                if (!$acquired) { throw 'A Sunshine bridge session still owns Manager. Quit Sunshine and wait for it to close.' }
                if (Get-SessionProcesses | Where-Object { $_.ProcessName -like 'Sunshine*' -or $_.ProcessName -eq 'ltk_patcher_host' }) {
                    throw 'Sunshine or the LTK patcher is still active. Exit from the tray before retrying.'
                }
                Close-VerifiedManager $manager $runningManager[0]
                Write-Status FIXED 'Closed the conflicting LTK Manager. Open Sunshine and retry Apply.'
            } catch { Write-Status WARN $_.Exception.Message }
            finally {
                if ($acquired) { $mutex.ReleaseMutex() }
                $mutex.Dispose()
            }
        }
    }
}
