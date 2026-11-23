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

  Interpreters that ship a windowless twin (python -> pythonw, py -> pyw, java -> javaw,
  cscript -> wscript, php -> php-win, perl -> wperl, ruby -> rubyw) get a second choice:
  swap in that GUI-subsystem sibling (found next to the original, and checked to really be
  a GUI program) instead of wrapping.  It is lighter, but the script then has no console:
  stdout/stdin are absent and cscript's WScript.Echo becomes message boxes.  Wrapping with
  ptyw keeps console semantics, so it is the default choice ("y"/"p"); "g" picks the sibling.

  Every change is recorded (before/after) in BAK\ptyw-update-<stamp>.json next to this
  script; -Undo <file> puts everything back.  The newest 4 such files are kept.

.PARAMETER PtywPath      ptyw.exe to use.  Default: the *installed* one -- %WINDIR%\ptyw.exe, else
                         %LOCALAPPDATA%\Microsoft\WindowsApps\ptyw.exe, else on PATH -- never the copy
                         beside this script.  Tasks that run as SYSTEM / another user need a system-wide
                         copy (make install, answer y when elevated), since they can't see your profile.
                         The installed <prog>w.exe aliases are used when they exist and running <prog>
                         by name would find the very same program (bash.exe -> bashw.exe); otherwise
                         the entry is rewritten as   ptyw.exe "full\path\prog.exe" args .
.PARAMETER List          Only list what would be offered; change nothing.
.PARAMETER DryRun        Walk through everything, but don't apply (no prompts).
.PARAMETER Associations  Also handle entries that launch a *document* by file association, e.g. a task, Run
                         value or shortcut whose target is foo.py: the open command registered for .py
                         (as Windows itself would use) is looked up, and if it is a console program the
                         entry becomes   ptyw.exe "C:\...\python.exe" "foo.py" args .  Associations that
                         open a GUI program (e.g. .ps1 -> Notepad) are left alone.
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
    [switch]$Associations,
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

# Where CreateProcess would find "<name>" when started by a program living in $AppDir
# (app dir, System32, System, Windows, then PATH); the user's cwd is deliberately not searched.
function Find-OnSearchPath([string]$FileName, [string]$AppDir) {
    $dirs = @($AppDir, [Environment]::SystemDirectory, (Join-Path $env:WINDIR 'System'), $env:WINDIR) +
            @($env:PATH -split ';')
    foreach ($d in $dirs) {
        if (-not $d) { continue }
        $p = Join-Path $d $FileName
        if (Test-Path -LiteralPath $p -PathType Leaf) { return (Resolve-Path -LiteralPath $p).ProviderPath }
    }
    return $null
}

# How to run console program $Tg (@{Exe; Arguments}) through the wrapper -> @{ Exe; Arguments; Note }.
# Preferred: the installed alias next to ptyw.exe (bash.exe -> bashw.exe), but ONLY when running
# "bash" by name would really find this same bash.exe -- otherwise (e.g. Cygwin bash vs the WSL
# C:\Windows\System32\bash.exe) fall back to  ptyw.exe "<full path>" args  and say why.
function Get-WrapForm($Tg) {
    $generic = @{ Exe = $script:Ptyw; Arguments = (Join-Args $Tg.Exe $Tg.Arguments); Note = $null }
    if ([IO.Path]::GetExtension($Tg.Exe).ToLower() -ne '.exe') { return $generic }      # .bat/.cmd: no alias
    $name  = [IO.Path]::GetFileNameWithoutExtension($Tg.Exe)
    $dir   = Split-Path -Parent $script:Ptyw
    $alias = Join-Path $dir "${name}w.exe"
    # must really be a copy/link of ptyw (pyw.exe, for instance, is the Python launcher)
    if (-not (Test-Path -LiteralPath $alias -PathType Leaf) -or -not (Test-IsWrapper $alias)) { return $generic }
    $hit = Find-OnSearchPath "$name.exe" $dir
    if ($hit -and ([IO.Path]::GetFullPath($hit) -ieq [IO.Path]::GetFullPath($Tg.Exe))) {
        return @{ Exe = $alias; Arguments = [string]$Tg.Arguments; Note = $null }
    }
    $generic.Note = "alias $(Split-Path -Leaf $alias) not used: '$name' would resolve to $(if ($hit) { $hit } else { 'nothing' }), not $($Tg.Exe)"
    return $generic
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

# The registered "open" command for an extension, e.g. '"C:\Python\python.exe" "%1" %*'
function Get-AssocCommand([string]$Ext) {
    if (-not ('PtywNative.Assoc' -as [type])) {
        Add-Type -Namespace PtywNative -Name Assoc -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shlwapi.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int AssocQueryString(uint flags, int str, string assoc, string extra,
                                          System.Text.StringBuilder outBuf, ref uint len);
'@
    }
    $sb = New-Object System.Text.StringBuilder 2048
    [uint32]$len = 2048
    # ASSOCF_NOTRUNCATE = 0x20, ASSOCSTR_COMMAND = 1; honours the user's "Open with" choice
    if ([PtywNative.Assoc]::AssocQueryString(0x20, 1, $Ext, 'open', $sb, [ref]$len) -ne 0) { return $null }
    return $sb.ToString()
}

# What does launching this file really run?  -> @{ Exe; Arguments; Via } or $null.
#  - exe/com/bat/cmd: itself.
#  - anything else, with -Associations: the interpreter its association names (Windows'
#    own %1 / %L / %* substitution), provided the template needs nothing more exotic.
function Get-LaunchTarget([string]$File, [string]$ArgText) {
    $ext = [IO.Path]::GetExtension($File).ToLower()
    if ($ext -in '.exe', '.com', '.bat', '.cmd') { return @{ Exe = $File; Arguments = $ArgText; Via = $null } }
    if (-not $Associations -or -not $ext) { return $null }
    $tpl = Get-AssocCommand $ext
    if (-not $tpl) { return $null }
    $tpl = [Environment]::ExpandEnvironmentVariables($tpl)
    $mF = [string][char]1; $mA = [string][char]2                  # markers, so the file name and
    $tpl = $tpl -replace '%[2-9]', ''                             # arguments are inserted verbatim
    $tpl = $tpl -replace '%[1lL0]', $mF -replace '%\*', $mA
    if ($tpl -match '%') { return $null }                         # %~..., %<n>... etc.: don't guess
    $tpl = $tpl.Replace($mF, $File).Replace($mA, $ArgText)
    $sp = Split-CommandLine $tpl
    $exe = Resolve-Exe $sp.Exe $null
    if (-not $exe) { return $null }
    return @{ Exe = $exe; Arguments = $sp.Arguments; Via = "$ext association" }
}

# Console interpreters that come with a GUI-subsystem twin in the same folder.
$script:GuiTwins = @(
    @{ Match = '^python[\d.]*\.exe$'; Twin = 'pythonw.exe';  Note = 'no console: sys.stdout/stdin are None (print is dropped, input() fails)' },
    @{ Match = '^py\.exe$';           Twin = 'pyw.exe';      Note = 'no console: the script gets no stdout/stdin' },
    @{ Match = '^java\.exe$';         Twin = 'javaw.exe';    Note = 'no console: System.out/in are not attached' },
    @{ Match = '^cscript\.exe$';      Twin = 'wscript.exe';  Note = 'WScript.Echo / StdOut become message boxes; //B-style silent scripts are fine' },
    @{ Match = '^php\.exe$';          Twin = 'php-win.exe';  Note = 'no console: echo output is dropped' },
    @{ Match = '^perl\.exe$';         Twin = 'wperl.exe';    Note = 'no console: STDOUT/STDIN are not attached' },
    @{ Match = '^ruby\.exe$';         Twin = 'rubyw.exe';    Note = 'no console: STDOUT/STDIN are not attached' }
)

# -> @{ Path; Note } for the GUI twin of a console interpreter, or $null
function Get-GuiTwin([string]$Exe) {
    $name = [IO.Path]::GetFileName($Exe).ToLower()
    foreach ($t in $script:GuiTwins) {
        if ($name -match $t.Match) {
            $p = Join-Path (Split-Path -Parent $Exe) $t.Twin
            if ((Test-Path -LiteralPath $p -PathType Leaf) -and (Get-PeSubsystem $p) -eq 2) {
                return @{ Path = $p; Note = $t.Note }
            }
        }
    }
    return $null
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
# Each candidate: Kind, Label, Info, BeforeText, AfterText, Before, After, Skip (reason or $null),
# and when the interpreter has a GUI twin (pythonw etc.): Alt (state using it), AltText, AltNote.

function New-Candidate($Kind, $Label, $Info, $BeforeText, $AfterText, $Before, $After, $Skip, $Tg = $null) {
    $alt = $null; $altText = ''; $altNote = ''
    $twin = if ($Tg) { Get-GuiTwin $Tg.Exe } else { $null }
    if ($twin) {
        $alt = $After.Clone()
        switch ($Kind) {
            'task' { $alt.Execute = $twin.Path; $alt.Arguments = [string]$Tg.Arguments
                     $altText = "$($alt.Execute) $($alt.Arguments)" }
            'run'  { $alt.Value = Join-Args $twin.Path $Tg.Arguments; $altText = $alt.Value }
            'lnk'  { $alt.Target = $twin.Path; $alt.Arguments = [string]$Tg.Arguments
                     $altText = "$($alt.Target) $($alt.Arguments)" }
        }
        $altNote = $twin.Note
    }
    [pscustomobject]@{ Kind = $Kind; Label = $Label; Info = $Info; BeforeText = $BeforeText
                       AfterText = $AfterText; Before = $Before; After = $After; Skip = $Skip
                       Alt = $alt; AltText = $altText.Trim(); AltNote = $altNote
                       WrapNote = $(if ($Tg) { $Tg.WrapNote } else { $null }) }
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
            $file = Resolve-Exe $a.Execute $a.WorkingDirectory
            if (-not $file) { continue }
            $tg = Get-LaunchTarget $file ([string]$a.Arguments)
            if (-not $tg -or (Test-IsWrapper $tg.Exe) -or -not (Test-ConsoleProgram $tg.Exe)) { continue }
            $before = @{ TaskPath = $t.TaskPath; TaskName = $t.TaskName; Index = $i; Execute = $a.Execute
                         Arguments = [string]$a.Arguments; WorkingDirectory = [string]$a.WorkingDirectory }
            $w = Get-WrapForm $tg; $tg.WrapNote = $w.Note
            $after = @{ TaskPath = $t.TaskPath; TaskName = $t.TaskName; Index = $i; Execute = $w.Exe
                        Arguments = $w.Arguments; WorkingDirectory = [string]$a.WorkingDirectory }
            $infoA = if ($tg.Via) { "$info; via $($tg.Via)" } else { $info }
            $skip = $null
            if ([string]$t.Principal.LogonType -eq 'Password') {
                $skip = 'stored-password task: Set-ScheduledTask would need the password; edit it by hand'
            } elseif (-not $mine -and -not $admin) {
                $skip = "runs as $uid; rerun from an elevated shell"
            } elseif (-not $mine -and (Test-InUserProfile $script:Ptyw)) {
                $skip = "runs as $uid, which can't use $script:Ptyw; install ptyw system-wide and give -PtywPath"
            }
            New-Candidate 'task' "Scheduled task  $($t.TaskPath)$($t.TaskName)  (action $($i + 1))" $infoA `
                ("$($a.Execute) $($a.Arguments)".Trim()) ("$($after.Execute) $($after.Arguments)") $before $after $skip $tg
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
                $file = Resolve-Exe $sp.Exe $null
                if (-not $file) { continue }
                $tg = Get-LaunchTarget $file $sp.Arguments
                if (-not $tg -or (Test-IsWrapper $tg.Exe) -or -not (Test-ConsoleProgram $tg.Exe)) { continue }
                $w = Get-WrapForm $tg; $tg.WrapNote = $w.Note
                $newVal = (Join-Args $w.Exe $w.Arguments)
                $before = @{ Hive = $loc.Hive; Sub = $loc.Sub; Name = $n; Value = $raw; Kind = $kind }
                $after  = @{ Hive = $loc.Hive; Sub = $loc.Sub; Name = $n; Value = $newVal; Kind = $kind }
                $skip = $null
                if ($loc.Admin -and -not $admin) { $skip = 'needs an elevated shell' }
                New-Candidate 'run' "Run key  $($loc.Hive)\$($loc.Sub)  value '$n'" $(if ($tg.Via) { "via $($tg.Via)" } else { '' }) $raw $newVal $before $after $skip $tg
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
            $target = Resolve-Exe $l.TargetPath $l.WorkingDirectory
            if (-not $target) { continue }
            $tg = Get-LaunchTarget $target ([string]$l.Arguments)
            if (-not $tg -or (Test-IsWrapper $tg.Exe) -or -not (Test-ConsoleProgram $tg.Exe)) { continue }
            $icon = [string]$l.IconLocation
            $newIcon = if (-not $icon -or $icon.StartsWith(',')) { "$($tg.Exe),0" } else { $icon }   # keep an icon
            $before = @{ Link = $file.FullName; Target = $l.TargetPath; Arguments = [string]$l.Arguments
                         WorkingDirectory = [string]$l.WorkingDirectory; IconLocation = $icon }
            $w = Get-WrapForm $tg; $tg.WrapNote = $w.Note
            $after  = @{ Link = $file.FullName; Target = $w.Exe; Arguments = $w.Arguments
                         WorkingDirectory = [string]$l.WorkingDirectory; IconLocation = $newIcon }
            $skip = $null
            if ($f.Admin -and -not $admin) { $skip = 'needs an elevated shell' }
            New-Candidate 'lnk' "Startup shortcut  $($file.FullName)" $(if ($tg.Via) { "via $($tg.Via)" } else { '' }) ("$($l.TargetPath) $($l.Arguments)".Trim()) `
                ("$($after.Target) $($after.Arguments)") $before $after $skip $tg
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

# The *installed* wrapper, never the copy sitting next to this script (the repo build):
# -PtywPath, else %WINDIR% (system-wide, usable by every task principal), else the per-user
# WindowsApps folder, else any PATH entry other than this script's folder or the cwd.
function Find-InstalledPtyw {
    if ($PtywPath) { return $(if (Test-Path -LiteralPath $PtywPath -PathType Leaf) { $PtywPath } else { $null }) }
    $skip = @($PSScriptRoot, (Get-Location).ProviderPath, '.', '') | ForEach-Object { $_.TrimEnd('\').ToLower() }
    $dirs = @($env:WINDIR, (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')) + @($env:PATH -split ';')
    foreach ($d in $dirs) {
        if (-not $d -or $skip -contains $d.TrimEnd('\').ToLower()) { continue }
        $c = Join-Path $d 'ptyw.exe'
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    return $null
}

function Invoke-Main {
    if ($Undo) { Invoke-Undo $Undo; return }

    $p = Find-InstalledPtyw
    if (-not $p) {
        throw "No installed ptyw.exe found (looked in $env:WINDIR, %LOCALAPPDATA%\Microsoft\WindowsApps and PATH). Run 'make install' in Windows/ptyw first, or give -PtywPath."
    }
    $script:Ptyw = (Resolve-Path -LiteralPath $p).ProviderPath
    Write-Host "Wrapper: $script:Ptyw    (admin: $(Test-Admin))"

    $cands = @(Get-TaskCandidates) + @(Get-RunCandidates) + @(Get-ShortcutCandidates)
    if (-not $cands.Count) { Write-Host 'Nothing to update: no console-subsystem startup entries or scheduled tasks found.'; return }
    Write-Host "$($cands.Count) candidate(s): console programs that would show a window."

    $allMode = $null; $n = 0; $done = 0          # $allMode: $null, 'ptyw' or 'gui'
    foreach ($c in $cands) {
        $n++
        Write-Host ''
        Write-Host "[$n/$($cands.Count)] $($c.Label)" -ForegroundColor Cyan
        if ($c.Info) { Write-Host "  $($c.Info)" -ForegroundColor DarkGray }
        Write-Host "  now    : $($c.BeforeText)"
        Write-Host "  ptyw   : $($c.AfterText)"
        if ($c.WrapNote) { Write-Host "           ($($c.WrapNote))" -ForegroundColor DarkGray }
        if ($c.Alt) {
            Write-Host "  gui    : $($c.AltText)" -ForegroundColor Green
            Write-Host "           ($($c.AltNote))" -ForegroundColor DarkGray
        }
        if ($c.Skip) { Write-Host "  skipped: $($c.Skip)" -ForegroundColor Yellow; continue }
        if ($List -or $DryRun) { continue }
        $choice = $allMode
        if (-not $choice) {
            $q = if ($c.Alt) { '  Update? [p]tyw wrap / [g]ui twin / [N]o / [a]ll remaining (ptyw) / [ag] all, gui where possible / [q]uit' }
                 else        { '  Update? [y]es / [N]o / [a]ll remaining / [q]uit' }
            $ans = (Read-Host $q).Trim().ToLower()
            if ($ans.StartsWith('q')) { break }
            elseif ($ans -eq 'ag') { $allMode = 'gui'; $choice = 'gui' }
            elseif ($ans.StartsWith('a')) { $allMode = 'ptyw'; $choice = 'ptyw' }
            elseif ($ans.StartsWith('g')) {
                if (-not $c.Alt) { Write-Host '  no GUI twin for this one; skipped.' -ForegroundColor Yellow; continue }
                $choice = 'gui'
            }
            elseif ($ans.StartsWith('y') -or $ans.StartsWith('p')) { $choice = 'ptyw' }
            else { continue }
        }
        if ($choice -eq 'gui' -and -not $c.Alt) { $choice = 'ptyw' }
        $state = if ($choice -eq 'gui') { $c.Alt } else { $c.After }
        try {
            Invoke-Change $c.Kind $state
            [void]$script:Log.Add([pscustomobject]@{ Kind = $c.Kind; Label = $c.Label; Before = $c.Before; After = $state
                                                    Via = $choice; Time = (Get-Date).ToString('s') })
            Save-Log
            $done++
            Write-Host "  updated ($choice)." -ForegroundColor Green
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
