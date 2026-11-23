#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
  Interactively switch existing startup entries and scheduled tasks to run via ptyw.exe.

.DESCRIPTION
  Finds console-subsystem programs (the ones that pop up a console window) in:
    - scheduled tasks (Exec actions; \Microsoft\* tasks are left out unless -IncludeMicrosoft)
    - Run keys: HKCU, HKLM and HKLM\WOW6432Node  ...\CurrentVersion\Run
    - Startup folders (per-user and all-users): .lnk shortcuts
  and offers, one at a time, to change   "prog args"   into   "ptyw.exe" "prog" args .
  The original program is always written as a full path, so the wrapper never picks a
  different program off PATH.  Already-wrapped and GUI programs are left alone.

  Every change is recorded (before/after) in BAK\ptyw-update-<stamp>.json next to this
  script; -Undo <file> puts everything back.  The newest 4 such files are kept.

.PARAMETER PtywPath      ptyw.exe to use (default: %LOCALAPPDATA%\Microsoft\WindowsApps\ptyw.exe, else PATH).
                         Tasks that run as SYSTEM / another user need a system-wide copy
                         (make install DEST=/cygdrive/c/Windows), since they can't see your profile.
.PARAMETER List          Only list what would be offered; change nothing.
.PARAMETER DryRun        Walk through everything, but don't apply (no prompts).
.PARAMETER IncludeMicrosoft  Also consider \Microsoft\* scheduled tasks.
.PARAMETER Undo          Restore the changes recorded in the given backup file.

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File ptyw-update-startup.ps1 -List
  powershell.exe -ExecutionPolicy Bypass -File ptyw-update-startup.ps1
  powershell.exe -ExecutionPolicy Bypass -File ptyw-update-startup.ps1 -Undo BAK\ptyw-update-20261122-190000.json
#>
[CmdletBinding()]
param(
    [string]$PtywPath,
    [switch]$List,
    [switch]$DryRun,
    [switch]$IncludeMicrosoft,
    [string]$Undo
)
$ErrorActionPreference = 'Stop'

$script:RunLocations = @(
    @{ Hive = 'HKCU'; Sub = 'Software\Microsoft\Windows\CurrentVersion\Run';             Admin = $false },
    @{ Hive = 'HKLM'; Sub = 'Software\Microsoft\Windows\CurrentVersion\Run';             Admin = $true  },
    @{ Hive = 'HKLM'; Sub = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Admin = $true  }
)
$script:StartupFolders = @(
    @{ Path = [Environment]::GetFolderPath('Startup');       Admin = $false },
    @{ Path = [Environment]::GetFolderPath('CommonStartup'); Admin = $true  }
)
$script:Ptyw = $null
$script:Log  = New-Object System.Collections.ArrayList
$script:LogFile = $null

# ---------------------------------------------------------------- helpers

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# PE "Subsystem" field: 2 = GUI, 3 = console, 0 = not a PE / unreadable
function Get-PeSubsystem([string]$Path) {
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { $buf = New-Object byte[] 4096; $n = $fs.Read($buf, 0, 4096) } finally { $fs.Dispose() }
        if ($n -lt 0x40 -or $buf[0] -ne 0x4D -or $buf[1] -ne 0x5A) { return 0 }
        $pe = [BitConverter]::ToInt32($buf, 0x3C)
        if ($pe -lt 0 -or $pe + 24 + 70 -gt $n) { return 0 }
        if ([BitConverter]::ToUInt32($buf, $pe) -ne 0x00004550) { return 0 }
        return [int][BitConverter]::ToUInt16($buf, $pe + 24 + 68)     # same offset for PE32 and PE32+
    } catch { return 0 }
}

# Name or path (env vars allowed) -> full path of an existing file, or $null
function Resolve-Exe([string]$Name, [string]$WorkDir) {
    $n = [Environment]::ExpandEnvironmentVariables($Name.Trim().Trim('"'))
    if (-not $n) { return $null }
    $cands = @()
    if ([IO.Path]::IsPathRooted($n)) {
        $cands += $n
    } else {
        if ($WorkDir) { $cands += (Join-Path ([Environment]::ExpandEnvironmentVariables($WorkDir)) $n) }
        $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { $cands += $c.Source }
    }
    foreach ($c in $cands) {
        foreach ($p in @($c, "$c.exe")) {
            if (Test-Path -LiteralPath $p -PathType Leaf) { return (Resolve-Path -LiteralPath $p).ProviderPath }
        }
    }
    return $null
}

function Test-ConsoleProgram([string]$Path) {
    $ext = [IO.Path]::GetExtension($Path).ToLower()
    if ($ext -eq '.cmd' -or $ext -eq '.bat') { return $true }
    if ($ext -eq '.exe' -or $ext -eq '.com') { return ((Get-PeSubsystem $Path) -eq 3) }
    return $false
}

# ptyw.exe itself, or one of its <prog>w.exe copies/links
function Test-IsWrapper([string]$Path) {
    $name = [IO.Path]::GetFileName($Path).ToLower()
    if ($name -eq 'ptyw.exe') { return $true }
    if (-not $name.EndsWith('w.exe') -or -not $script:Ptyw) { return $false }
    try {
        if ((Get-Item -LiteralPath $Path).Length -ne (Get-Item -LiteralPath $script:Ptyw).Length) { return $false }
        return ((Get-FileHash -LiteralPath $Path).Hash -eq (Get-FileHash -LiteralPath $script:Ptyw).Hash)
    } catch { return $false }
}

# "C:\Program Files\x\app.exe" /s   or   C:\Program Files\x\app.exe /s   -> exe + arguments
function Split-CommandLine([string]$Cmd) {
    $s = [Environment]::ExpandEnvironmentVariables($Cmd.Trim())
    if ($s.StartsWith('"')) {
        $i = $s.IndexOf('"', 1)
        if ($i -gt 0) { return @{ Exe = $s.Substring(1, $i - 1); Arguments = $s.Substring($i + 1).Trim() } }
    }
    $cuts = @(); for ($i = 0; $i -lt $s.Length; $i++) { if ($s[$i] -eq ' ') { $cuts += $i } }; $cuts += $s.Length
    foreach ($i in $cuts) {                       # shortest prefix that names an existing program
        $try = $s.Substring(0, $i)
        if (Resolve-Exe $try $null) { return @{ Exe = $try; Arguments = $s.Substring($i).Trim() } }
    }
    $parts = $s -split '\s+', 2
    return @{ Exe = $parts[0]; Arguments = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) }
}

function Join-Args([string]$First, [string]$Rest) {
    $r = '"' + $First + '"'
    if ($Rest) { $r += ' ' + $Rest }
    return $r
}

function Test-InUserProfile([string]$Path) {
    $Path.StartsWith($env:USERPROFILE + '\', [StringComparison]::OrdinalIgnoreCase)
}

# ---------------------------------------------------------------- apply / restore

function Set-TaskAction($Path, $Name, [int]$Index, $Exec, $Arguments, $WorkDir) {
    $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name
    $new = @()
    for ($i = 0; $i -lt @($t.Actions).Count; $i++) {
        if ($i -eq $Index) {
            $p = @{ Execute = $Exec }
            if ($Arguments) { $p.Argument = $Arguments }
            if ($WorkDir)   { $p.WorkingDirectory = $WorkDir }
            $new += New-ScheduledTaskAction @p
        } else {
            $new += @($t.Actions)[$i]
        }
    }
    Set-ScheduledTask -TaskPath $Path -TaskName $Name -Action $new | Out-Null
}

function Open-RunKey([string]$Hive, [string]$Sub, [bool]$Write) {
    $root = if ($Hive -eq 'HKCU') { [Microsoft.Win32.Registry]::CurrentUser } else { [Microsoft.Win32.Registry]::LocalMachine }
    $root.OpenSubKey($Sub, $Write)
}

function Set-RunValue($Hive, $Sub, $Name, $Value, $Kind) {
    $k = Open-RunKey $Hive $Sub $true
    if (-not $k) { throw "cannot open $Hive\$Sub for writing" }
    try { $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind) } finally { $k.Close() }
}

function Set-Shortcut($Link, $Target, $Arguments, $WorkDir, $Icon) {
    $sh = New-Object -ComObject WScript.Shell
    $l = $sh.CreateShortcut($Link)
    $l.TargetPath = $Target
    $l.Arguments = $Arguments
    if ($WorkDir) { $l.WorkingDirectory = $WorkDir }
    if ($Icon)    { $l.IconLocation = $Icon }
    $l.Save()
}

function Invoke-Change($Kind, $S) {          # $S = before-state or after-state
    switch ($Kind) {
        'task' { Set-TaskAction $S.TaskPath $S.TaskName $S.Index $S.Execute $S.Arguments $S.WorkingDirectory }
        'run'  { Set-RunValue $S.Hive $S.Sub $S.Name $S.Value $S.Kind }
        'lnk'  { Set-Shortcut $S.Link $S.Target $S.Arguments $S.WorkingDirectory $S.IconLocation }
    }
}

# ---------------------------------------------------------------- collectors
# Each candidate: Kind, Label, Info, BeforeText, AfterText, Before, After, Skip (reason or $null)

function New-Candidate($Kind, $Label, $Info, $BeforeText, $AfterText, $Before, $After, $Skip) {
    [pscustomobject]@{ Kind = $Kind; Label = $Label; Info = $Info; BeforeText = $BeforeText
                       AfterText = $AfterText; Before = $Before; After = $After; Skip = $Skip }
}

function Get-TaskCandidates {
    $admin = Test-Admin
    foreach ($t in Get-ScheduledTask) {
        if (-not $IncludeMicrosoft -and $t.TaskPath -like '\Microsoft\*') { continue }
        $uid = [string]$t.Principal.UserId
        $mine = $uid -and (($uid -split '\\')[-1] -ieq $env:USERNAME)
        $trig = (@($t.Triggers) | ForEach-Object { $_.CimClass.CimClassName -replace '^MSFT_Task|Trigger$', '' }) -join ','
        $info = "user: $(if ($uid) { $uid } else { '-' }); trigger: $(if ($trig) { $trig } else { 'none' }); state: $($t.State)"
        $i = -1
        foreach ($a in @($t.Actions)) {
            $i++
            if (-not $a.Execute) { continue }
            $exe = Resolve-Exe $a.Execute $a.WorkingDirectory
            if (-not $exe -or (Test-IsWrapper $exe) -or -not (Test-ConsoleProgram $exe)) { continue }
            $before = @{ TaskPath = $t.TaskPath; TaskName = $t.TaskName; Index = $i; Execute = $a.Execute
                         Arguments = [string]$a.Arguments; WorkingDirectory = [string]$a.WorkingDirectory }
            $after = @{ TaskPath = $t.TaskPath; TaskName = $t.TaskName; Index = $i; Execute = $script:Ptyw
                        Arguments = (Join-Args $exe ([string]$a.Arguments)); WorkingDirectory = [string]$a.WorkingDirectory }
            $skip = $null
            if ([string]$t.Principal.LogonType -eq 'Password') {
                $skip = 'stored-password task: Set-ScheduledTask would need the password; edit it by hand'
            } elseif (-not $mine -and -not $admin) {
                $skip = "runs as $uid; rerun from an elevated shell"
            } elseif (-not $mine -and (Test-InUserProfile $script:Ptyw)) {
                $skip = "runs as $uid, which can't use $script:Ptyw; install ptyw system-wide and give -PtywPath"
            }
            New-Candidate 'task' "Scheduled task  $($t.TaskPath)$($t.TaskName)  (action $($i + 1))" $info `
                ("$($a.Execute) $($a.Arguments)".Trim()) ("$($after.Execute) $($after.Arguments)") $before $after $skip
        }
    }
}

function Get-RunCandidates {
    $admin = Test-Admin
    foreach ($loc in $script:RunLocations) {
        $k = Open-RunKey $loc.Hive $loc.Sub $false
        if (-not $k) { continue }
        try {
            foreach ($n in $k.GetValueNames()) {
                if (-not $n) { continue }
                $raw  = [string]$k.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
                $kind = [string]$k.GetValueKind($n)
                if ($kind -ne 'String' -and $kind -ne 'ExpandString') { continue }
                $sp  = Split-CommandLine $raw
                $exe = Resolve-Exe $sp.Exe $null
                if (-not $exe -or (Test-IsWrapper $exe) -or -not (Test-ConsoleProgram $exe)) { continue }
                $newVal = (Join-Args $script:Ptyw ('"' + $exe + '"' + $(if ($sp.Arguments) { ' ' + $sp.Arguments } else { '' })))
                $before = @{ Hive = $loc.Hive; Sub = $loc.Sub; Name = $n; Value = $raw; Kind = $kind }
                $after  = @{ Hive = $loc.Hive; Sub = $loc.Sub; Name = $n; Value = $newVal; Kind = $kind }
                $skip = $null
                if ($loc.Admin -and -not $admin) { $skip = 'needs an elevated shell' }
                New-Candidate 'run' "Run key  $($loc.Hive)\$($loc.Sub)  value '$n'" '' $raw $newVal $before $after $skip
            }
        } finally { $k.Close() }
    }
}

function Get-ShortcutCandidates {
    $admin = Test-Admin
    $sh = New-Object -ComObject WScript.Shell
    foreach ($f in $script:StartupFolders) {
        if (-not $f.Path -or -not (Test-Path -LiteralPath $f.Path)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $f.Path -Filter *.lnk -File) {
            $l = $sh.CreateShortcut($file.FullName)
            $exe = Resolve-Exe $l.TargetPath $l.WorkingDirectory
            if (-not $exe -or (Test-IsWrapper $exe) -or -not (Test-ConsoleProgram $exe)) { continue }
            $icon = [string]$l.IconLocation
            $newIcon = if (-not $icon -or $icon.StartsWith(',')) { "$exe,0" } else { $icon }   # keep the original icon
            $before = @{ Link = $file.FullName; Target = $l.TargetPath; Arguments = [string]$l.Arguments
                         WorkingDirectory = [string]$l.WorkingDirectory; IconLocation = $icon }
            $after  = @{ Link = $file.FullName; Target = $script:Ptyw; Arguments = (Join-Args $exe ([string]$l.Arguments))
                         WorkingDirectory = [string]$l.WorkingDirectory; IconLocation = $newIcon }
            $skip = $null
            if ($f.Admin -and -not $admin) { $skip = 'needs an elevated shell' }
            New-Candidate 'lnk' "Startup shortcut  $($file.FullName)" '' ("$($l.TargetPath) $($l.Arguments)".Trim()) `
                ("$($after.Target) $($after.Arguments)") $before $after $skip
        }
        foreach ($file in Get-ChildItem -LiteralPath $f.Path -File | Where-Object { $_.Extension -in '.bat', '.cmd' }) {
            Write-Host "note: $($file.FullName) is a batch file in a Startup folder; not handled (wrap it by hand: ptyw.exe `"$($file.FullName)`")" -ForegroundColor DarkGray
        }
    }
}

# ---------------------------------------------------------------- backup log

function Save-Log {
    if (-not $script:LogFile) {
        $dir = Join-Path $PSScriptRoot 'BAK'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $script:LogFile = Join-Path $dir ("ptyw-update-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    ConvertTo-Json -InputObject @($script:Log) -Depth 6 | Set-Content -LiteralPath $script:LogFile -Encoding UTF8
}

function Remove-OldLogs {      # keep this run's file + the 3 previous ones
    $dir = Join-Path $PSScriptRoot 'BAK'
    Get-ChildItem -LiteralPath $dir -Filter 'ptyw-update-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 4 |
        ForEach-Object { Write-Host "removing old backup log $($_.Name)" -ForegroundColor DarkGray; Remove-Item -LiteralPath $_.FullName }
}

function Invoke-Undo([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { throw "no such backup file: $File" }
    $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $File -Raw)
    $recs = @($parsed | ForEach-Object { $_ })       # flatten (5.1 returns the array as one object)
    [array]::Reverse($recs)
    foreach ($r in $recs) {
        Write-Host "restoring  $($r.Label)"
        try { Invoke-Change $r.Kind $r.Before } catch { Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

# ---------------------------------------------------------------- main

function Invoke-Main {
    if ($Undo) { Invoke-Undo $Undo; return }

    if ($PtywPath) { $p = $PtywPath }
    else {
        $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\ptyw.exe'
        if (-not (Test-Path -LiteralPath $p)) {
            $c = Get-Command ptyw.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($c) { $p = $c.Source }
        }
    }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "ptyw.exe not found (tried '$p'). Run 'make install' in Windows/ptyw first, or give -PtywPath."
    }
    $script:Ptyw = (Resolve-Path -LiteralPath $p).ProviderPath
    Write-Host "Wrapper: $script:Ptyw    (admin: $(Test-Admin))"

    $cands = @(Get-TaskCandidates) + @(Get-RunCandidates) + @(Get-ShortcutCandidates)
    if (-not $cands.Count) { Write-Host 'Nothing to update: no console-subsystem startup entries or scheduled tasks found.'; return }
    Write-Host "$($cands.Count) candidate(s): console programs that would show a window."

    $all = $false; $n = 0; $done = 0
    foreach ($c in $cands) {
        $n++
        Write-Host ''
        Write-Host "[$n/$($cands.Count)] $($c.Label)" -ForegroundColor Cyan
        if ($c.Info) { Write-Host "  $($c.Info)" -ForegroundColor DarkGray }
        Write-Host "  now    : $($c.BeforeText)"
        Write-Host "  becomes: $($c.AfterText)"
        if ($c.Skip) { Write-Host "  skipped: $($c.Skip)" -ForegroundColor Yellow; continue }
        if ($List -or $DryRun) { continue }
        if (-not $all) {
            $ans = (Read-Host '  Update? [y]es / [N]o / [a]ll remaining / [q]uit').Trim().ToLower()
            if ($ans.StartsWith('q')) { break }
            if ($ans.StartsWith('a')) { $all = $true }
            elseif (-not $ans.StartsWith('y')) { continue }
        }
        try {
            Invoke-Change $c.Kind $c.After
            [void]$script:Log.Add([pscustomobject]@{ Kind = $c.Kind; Label = $c.Label; Before = $c.Before; After = $c.After
                                                    Time = (Get-Date).ToString('s') })
            Save-Log
            $done++
            Write-Host '  updated.' -ForegroundColor Green
        } catch {
            Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host ''
    if ($done) {
        Remove-OldLogs
        Write-Host "$done change(s) made. To revert:  -Undo `"$script:LogFile`"" -ForegroundColor Green
    } elseif (-not ($List -or $DryRun)) {
        Write-Host 'No changes made.'
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }
