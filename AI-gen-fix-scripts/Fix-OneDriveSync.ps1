<#
.SYNOPSIS
    Investigates, diagnoses, and remedies a stuck OneDrive Personal sync.

.DESCRIPTION
    OneDrive does not expose a real-time sync-status API, so this script infers
    health from: the OneDrive process, log-file activity, disk space, network
    reachability, Windows Event Logs, configuration flags, and the most common 
    concrete blockers (locked/open Office files, illegal filenames, over-length paths). 
    It then offers graduated remediation:

        1. Graceful restart of OneDrive   (safe, clears most stuck queues)
        2. OneDrive /reset                 (aggressive, re-establishes sync;
                                            does NOT delete your files)

    The classic symptom "Moving files, 0 files and 0.0 KB remaining (0%)" that
    never clears is a jammed queue — a restart resolves it the large majority
    of the time; /reset is the fallback.

.PARAMETER DiagnoseOnly
    Run all checks and print the report, but make no changes.

.PARAMETER AutoFix
    Apply the chosen remedy without interactive confirmation.

.PARAMETER Reset
    Use the aggressive 'OneDrive.exe /reset' remedy instead of a plain restart.

.PARAMETER DeepScan
    Recursively scan the sync folder (or -Path) for illegal names, over-length
    paths, and locked files. Skipped by default because it can be slow on a
    large library. Online-only (Files On-Demand) placeholders are NOT hydrated.

.PARAMETER Path
    Focus the deep scan on a specific subfolder, e.g. the move destination
    "!CP+MH". Defaults to the whole OneDrive Personal root.

.EXAMPLE
    .\Fix-OneDriveSync.ps1
    Diagnose, then prompt to restart OneDrive.

.EXAMPLE
    .\Fix-OneDriveSync.ps1 -DeepScan -Path "!CP+MH"
    Diagnose + scan the move destination for blockers, then prompt to restart.

.EXAMPLE
    .\Fix-OneDriveSync.ps1 -Reset -AutoFix
    Diagnose and perform a full /reset without prompting.

.NOTES
    Windows PowerShell 5.1+ compatible. No admin rights required.
#>

[CmdletBinding()]
param(
    [switch]$DiagnoseOnly,
    [switch]$AutoFix,
    [switch]$Reset,
    [switch]$DeepScan,
    [string]$Path
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Section { param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
}
function Write-OK    { param($m) Write-Host "  [ OK ] $m"   -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "  [WARN] $m"   -ForegroundColor Yellow }
function Write-Bad   { param($m) Write-Host "  [FAIL] $m"   -ForegroundColor Red }
function Write-Info  { param($m) Write-Host "  [INFO] $m"   -ForegroundColor Gray }

 $findings = New-Object System.Collections.Generic.List[string]
function Add-Finding { param($m) $findings.Add($m) }

# ---------------------------------------------------------------------------
# Locate OneDrive Personal folder + executable
# ---------------------------------------------------------------------------
function Get-OneDrivePersonalPath {
    # Prefer the registry record of the Personal account's local folder.
    $regKeys = @(
        'HKCU:\Software\Microsoft\OneDrive\Accounts\Personal'
    )
    foreach ($k in $regKeys) {
        try {
            $uf = (Get-ItemProperty -Path $k -ErrorAction Stop).UserFolder
            if ($uf -and (Test-Path $uf)) { return $uf }
        } catch { }
    }
    # Fall back to environment variables OneDrive sets at sign-in.
    foreach ($v in @($env:OneDriveConsumer, $env:OneDrive)) {
        if ($v -and (Test-Path $v)) { return $v }
    }
    return $null
}

function Get-OneDriveExe {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive\OneDrive.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------
function Test-FileLocked { param([string]$FilePath)
    # True if another process holds the file open for exclusive access.
    try {
        $fs = [System.IO.File]::Open($FilePath, 'Open', 'ReadWrite', 'None')
        $fs.Close(); $fs.Dispose()
        return $false
    } catch [System.IO.IOException] {
        return $true
    } catch {
        return $false   # permission/other error: not the lock we care about
    }
}

function Get-IllegalNameReason { param([string]$Name)
    $reasons = @()
    if ($Name -match '[\"\*\:\<\>\?\|]')          { $reasons += 'illegal character (" * : < > ? |)' }
    if ($Name -ne $Name.Trim())                    { $reasons += 'leading/trailing space' }
    if ($Name.EndsWith('.'))                       { $reasons += 'trailing period' }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    if ($base -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { $reasons += 'reserved Windows name' }
    return ($reasons -join '; ')
}

# ===========================================================================
#  START
# ===========================================================================
Write-Host ""
Write-Host "  OneDrive Personal Sync Doctor" -ForegroundColor White
Write-Host "  Run: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray

 $odPath = Get-OneDrivePersonalPath
 $odExe  = Get-OneDriveExe

if (-not $odPath) {
    Write-Bad "Could not locate your OneDrive Personal folder. Is OneDrive signed in?"
}
if (-not $odExe) {
    Write-Bad "Could not find OneDrive.exe. Remediation steps will be unavailable."
}

# ---------------------------------------------------------------------------
Write-Section "1. Process & version"
 $proc = Get-Process OneDrive -ErrorAction SilentlyContinue
if ($proc) {
    $startedAgo = (New-TimeSpan -Start $proc[0].StartTime -End (Get-Date))
    Write-OK ("OneDrive is running (PID {0}, up {1:%h}h {1:%m}m)." -f $proc[0].Id, $startedAgo)
    if ($odExe) {
        try {
            $ver = (Get-Item $odExe).VersionInfo.ProductVersion
            Write-Info "Version: $ver"
        } catch { }
    }
} else {
    Write-Warn "OneDrive process is NOT running."
    Add-Finding "OneDrive process not running -> launching it may resolve the stall."
}

# Check for ongoing OneDrive updates
 $setupProc = Get-Process OneDriveSetup -ErrorAction SilentlyContinue
if ($setupProc) {
    Write-Warn "OneDriveSetup.exe is running — an update or install may be in progress."
    Add-Finding "OneDrive update in progress -> wait for it to finish, or it may block sync actions."
}

# ---------------------------------------------------------------------------
Write-Section "2. Network reachability"
try {
    $net = Test-NetConnection -ComputerName 'onedrive.live.com' -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop
    if ($net.TcpTestSucceeded) {
        Write-OK "Reached onedrive.live.com:443 (TCP)."
    } else {
        Write-Bad "Cannot reach onedrive.live.com:443."
        Add-Finding "Network path to OneDrive is blocked -> sync cannot progress."
    }
} catch {
    Write-Warn "Connectivity test inconclusive: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
Write-Section "3. Disk space"
if ($odPath) {
    try {
        $di = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($odPath))
        $freeGB  = [math]::Round($di.AvailableFreeSpace / 1GB, 2)
        $totalGB = [math]::Round($di.TotalSize / 1GB, 2)
        if ($freeGB -lt 1) {
            Write-Bad "Only $freeGB GB free on $($di.Name) — too low for sync."
            Add-Finding "Critically low disk space ($freeGB GB) -> free space and retry."
        } elseif ($freeGB -lt 5) {
            Write-Warn "$freeGB GB free of $totalGB GB on $($di.Name) — getting tight."
        } else {
            Write-OK "$freeGB GB free of $totalGB GB on $($di.Name)."
        }
    } catch { Write-Warn "Could not read disk space: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
Write-Section "4. Recent sync-engine activity (log timestamps)"
 $logDir = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\logs'
if (Test-Path $logDir) {
    $recent = Get-ChildItem $logDir -Recurse -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($recent) {
        $idle = New-TimeSpan -Start $recent.LastWriteTime -End (Get-Date)
        $msg  = "Newest log '{0}' last written {1:%h}h {1:%m}m {1:%s}s ago." -f $recent.Name, $idle
        if ($idle.TotalMinutes -gt 10) {
            Write-Warn $msg
            Write-Warn "The engine looks idle while the UI still claims it is moving files."
            Add-Finding "Log activity is stale while UI shows 'Moving files' -> classic jammed queue."
        } else {
            Write-OK $msg
        }
    } else { Write-Info "No log files found." }
} else { Write-Info "Log directory not present: $logDir" }

# ---------------------------------------------------------------------------
Write-Section "5. Windows Event Log (OneDrive errors/warnings)"
try {
    $onedriveEvents = Get-WinEvent -FilterHashtable @{
        LogName      = 'Application'
        ProviderName = 'OneDrive'
        Level        = 2, 3  # Error, Warning
        StartTime    = (Get-Date).AddDays(-2)
    } -MaxEvents 5 -ErrorAction Stop

    Write-Warn "Found recent OneDrive warning/error event(s) in the Application log:"
    foreach ($ev in $onedriveEvents) {
        $lvl = if ($ev.Level -eq 2) { "ERROR" } else { "WARN " }
        $msg = $ev.Message -replace "`n", " "
        if ($msg.Length -gt 150) { $msg = $msg.Substring(0, 150) + "..." }
        Write-Host "         [$lvl] $(Get-Date $ev.TimeCreated -Format 'yyyy-MM-dd HH:mm:ss') - $msg" -ForegroundColor Yellow
    }
    Add-Finding "Recent OneDrive errors logged in Windows Event Log. Check Event Viewer for details."
} catch {
    # Error message for no events found is typically "No events were found that match the specified selection criteria."
    if ($_.Exception.Message -match "No events were found") {
        Write-OK "No recent OneDrive errors or warnings in the Application log."
    } else {
        Write-Warn "Could not query Event Log: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
Write-Section "6. Configuration & Known Folder Move"
if (-not $odPath) {
    Write-Info "OneDrive path not found, skipping configuration checks."
} else {
    $regBase = 'HKCU:\Software\Microsoft\OneDrive'
    if (Test-Path $regBase) {
        # Files On-Demand
        $fod = (Get-ItemProperty -Path $regBase -Name 'FilesOnDemandEnabled' -ErrorAction SilentlyContinue).FilesOnDemandEnabled
        if ($fod -eq 1) {
            Write-OK "Files On-Demand is enabled (recommended)."
        } else {
            Write-Warn "Files On-Demand is disabled. This can cause sync issues if disk space is low or files are large."
            Add-Finding "Enable Files On-Demand in OneDrive Settings to prevent disk-space related sync failures."
        }

        # Office file collaboration
        $officeSync = (Get-ItemProperty -Path $regBase -Name 'EnableAllOcsiClients' -ErrorAction SilentlyContinue).EnableAllOcsiClients
        if ($officeSync -eq 1) {
            Write-Info "Office file collaboration is enabled. This can sometimes lock files if Office apps hang."
        }
    } else {
        Write-Info "Could not read OneDrive registry settings."
    }

    # Known Folder Move (Backup)
    $specialFolders = @(
        @{Name='Desktop'; Path=[Environment]::GetFolderPath('Desktop')},
        @{Name='Documents'; Path=[Environment]::GetFolderPath('MyDocuments')},
        @{Name='Pictures'; Path=[Environment]::GetFolderPath('MyPictures')}
    )
    $activeKFM = $specialFolders | Where-Object { $_.Path -and $_.Path.StartsWith($odPath) }
    if ($activeKFM) {
        $kfmNames = ($activeKFM | ForEach-Object { $_.Name }) -join ', '
        Write-Info "Known Folder Move (Backup) is active for: $kfmNames"
        Write-Info "  (If the UI shows 'Moving files', it may be KFM trying to relocate these folders.)"
    }
}

# ---------------------------------------------------------------------------
Write-Section "7. Blockers in the move destination"
# Always do a light check of the focus folder for the tell-tale Office lock
# files (~$Name.xlsx), which appear when a workbook is open and will block a move.
 $scanRoot = $null
if ($odPath) {
    if ($Path) {
        $candidate = if (Test-Path $Path) { (Resolve-Path $Path).Path } else { Join-Path $odPath $Path }
        if (Test-Path $candidate) { $scanRoot = $candidate }
        else { Write-Warn "Focus path not found: $candidate (falling back to OneDrive root)"; $scanRoot = $odPath }
    } else {
        $scanRoot = $odPath
    }
}

if ($scanRoot) {
    Write-Info "Focus folder: $scanRoot"

    # Office lock files (cheap, metadata-only).
    $lockFiles = Get-ChildItem $scanRoot -Recurse -Force -Filter '~$*' -File -ErrorAction SilentlyContinue
    if ($lockFiles) {
        Write-Warn "Found $($lockFiles.Count) open-Office lock file(s) — the source/destination doc may still be open:"
        $lockFiles | Select-Object -First 10 | ForEach-Object { Write-Host "         $($_.FullName)" -ForegroundColor Yellow }
        Add-Finding "Open Office documents detected -> close Excel/Word so OneDrive can move the file(s)."
    } else {
        Write-OK "No open-Office lock files in the focus folder."
    }
}

# ---------------------------------------------------------------------------
if ($DeepScan -and $scanRoot) {
    Write-Section "8. Deep scan: illegal names, long paths, locked files"
    Write-Info "Scanning $scanRoot (this can take a while; placeholders are not downloaded)..."

    $badNames = New-Object System.Collections.Generic.List[string]
    $longPaths = New-Object System.Collections.Generic.List[string]
    $locked    = New-Object System.Collections.Generic.List[string]

    Get-ChildItem $scanRoot -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $item = $_

        # Illegal leaf name?
        $reason = Get-IllegalNameReason $item.Name
        if ($reason) { $badNames.Add(("{0}  --> {1}" -f $item.FullName, $reason)) }

        # Over-length path? (OneDrive hard limit is 400 chars; MAX_PATH is 260.)
        if ($item.FullName.Length -gt 256) {
            $longPaths.Add(("{0} chars: {1}" -f $item.FullName.Length, $item.FullName))
        }

        # Locked? Only for real, locally-present files (skip online-only
        # placeholders so we never trigger a download).
        if (-not $item.PSIsContainer) {
            $isOnlineOnly = ($item.Attributes -band [System.IO.FileAttributes]::Offline)
            if (-not $isOnlineOnly -and (Test-FileLocked $item.FullName)) {
                $locked.Add($item.FullName)
            }
        }
    }

    if ($badNames.Count) {
        Write-Bad "$($badNames.Count) file(s)/folder(s) with names OneDrive cannot sync:"
        $badNames | Select-Object -First 20 | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
        Add-Finding "Rename the flagged item(s) to remove illegal characters."
    } else { Write-OK "No illegal names found." }

    if ($longPaths.Count) {
        Write-Warn "$($longPaths.Count) path(s) over 256 chars (risk; hard fail above 400):"
        $longPaths | Select-Object -First 20 | ForEach-Object { Write-Host "         $_" -ForegroundColor Yellow }
        Add-Finding "Shorten deep folder paths/long filenames."
    } else { Write-OK "No over-length paths found." }

    if ($locked.Count) {
        Write-Warn "$($locked.Count) file(s) currently locked by another process:"
        $locked | Select-Object -First 20 | ForEach-Object { Write-Host "         $_" -ForegroundColor Yellow }
        Add-Finding "Close the apps holding the locked file(s)."
    } else { Write-OK "No locked, locally-present files found." }
} elseif (-not $DeepScan) {
    Write-Info "Skipping deep scan. Re-run with -DeepScan (optionally -Path `"!CP+MH`") for a full pass."
}

# ---------------------------------------------------------------------------
Write-Section "Diagnosis summary"
if ($findings.Count -eq 0) {
    Write-Host "  No concrete blocker found. The most likely cause is a jammed" -ForegroundColor White
    Write-Host "  internal queue — a graceful restart usually clears it." -ForegroundColor White
} else {
    Write-Host "  Issues worth acting on:" -ForegroundColor White
    $i = 1
    foreach ($f in $findings) { Write-Host "   $i. $f" -ForegroundColor White; $i++ }
}

# ---------------------------------------------------------------------------
#  REMEDIATION
# ---------------------------------------------------------------------------
function Restart-OneDriveClient { param([string]$Exe)
    Write-Info "Stopping OneDrive..."
    Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    if ($Exe -and (Test-Path $Exe)) {
        Write-Info "Relaunching OneDrive..."
        Start-Process $Exe
        Write-OK "OneDrive restarted. Watch the tray icon — the queue should clear within a minute."
    } else {
        Write-Bad "OneDrive.exe not found; please relaunch OneDrive manually from the Start menu."
    }
}

function Reset-OneDriveClient { param([string]$Exe)
    if (-not ($Exe -and (Test-Path $Exe))) {
        Write-Bad "OneDrive.exe not found; cannot run /reset."
        return
    }
    Write-Info "Running OneDrive /reset (re-establishes sync; your files are not deleted)..."
    & $Exe /reset
    Start-Sleep -Seconds 8
    if (-not (Get-Process OneDrive -ErrorAction SilentlyContinue)) {
        Write-Info "Relaunching OneDrive after reset..."
        Start-Process $Exe
    }
    Write-OK "Reset issued. OneDrive will re-index and reconcile; give it several minutes."
}

if ($DiagnoseOnly) {
    Write-Section "Done (diagnose-only)"
    Write-Info "No changes made. Re-run without -DiagnoseOnly to apply a remedy."
} else {
    Write-Section "Remediation"
    if ($Reset) {
        $go = $true
        if (-not $AutoFix) {
            $ans = Read-Host "  Perform the aggressive OneDrive /reset now? (y/N)"
            $go = ($ans -match '^(y|yes)$')
        }
        if ($go) { Reset-OneDriveClient -Exe $odExe } else { Write-Info "Skipped reset." }
    } else {
        $go = $true
        if (-not $AutoFix) {
            $ans = Read-Host "  Gracefully restart OneDrive now? (Y/n)"
            $go = -not ($ans -match '^(n|no)$')
        }
        if ($go) {
            Restart-OneDriveClient -Exe $odExe
            Write-Host ""
            Write-Info "If the 'Moving files' banner returns and sticks again, re-run with -Reset."
        } else {
            Write-Info "Skipped restart."
        }
    }

    Write-Section "Further steps (if the issue persists)"
    Write-Host "  If restarting or resetting OneDrive does not resolve the issue:" -ForegroundColor White
    Write-Host "   1. Unlink and Relink your PC:" -ForegroundColor Gray
    Write-Host "      Right-click OneDrive icon > Settings > Account > Unlink this PC." -ForegroundColor DarkGray
    Write-Host "      Sign back in and choose the same folder location." -ForegroundColor DarkGray
    Write-Host "   2. Verify Files On-Demand is ON:" -ForegroundColor Gray
    Write-Host "      Right-click OneDrive icon > Settings > Sync and backup > Advanced > Files On-Demand." -ForegroundColor DarkGray
    Write-Host "   3. Repair Office:" -ForegroundColor Gray
    Write-Host "      If Office files are constantly locking, run an Online Repair from Settings > Apps." -ForegroundColor DarkGray
    Write-Host "   4. Check for Windows Updates:" -ForegroundColor Gray
    Write-Host "      Ensure your OS is fully patched, as OS updates can resolve OneDrive shell issues." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  Finished." -ForegroundColor White