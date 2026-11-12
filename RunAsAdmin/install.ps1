# Install the built RunAsAdmin server and client into C:\dos (run from an ELEVATED prompt, after build.cmd).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-InstallDir C:\dos]
#
# What it does: backs up the installed files to <InstallDir>\BAK (the 3 newest copies of each are kept), stops the "Elevate Service"
# scheduled task and its process, copies the new files, starts the task again and checks that the server is running and its pipe
# exists.  If that check fails it puts the backups back and starts the old server.  Running programs that the server has already
# started are not touched.
# If the server was NOT running when you started (nobody logged on, say), the files are only copied: the task starts the new
# server at the next logon, and nothing is started or checked now.
param([string]$InstallDir = 'C:\dos')

$ErrorActionPreference = 'Stop'
$task   = '\UserCreated\Elevate Service'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin    = Join-Path $here 'bin'
$files  = @('RunAsAdminServer.exe', 'RunAsAdminClient.exe')
$libs   = @('Microsoft.Win32.TaskScheduler.dll', 'ProcPriMgd.dll')
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'run this elevated (an administrator prompt)'
}
foreach ($f in $files) { if (-not (Test-Path (Join-Path $bin $f))) { throw "missing $bin\$f - run build.cmd first" } }
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir | Out-Null }
$bak = Join-Path $InstallDir 'BAK'
if (-not (Test-Path $bak)) { New-Item -ItemType Directory -Path $bak | Out-Null }

$all = $files + $libs + @('RunAsAdminServer.exe.config', 'RunAsAdminClient.exe.config')
foreach ($f in $all) {
    $cur = Join-Path $InstallDir $f
    if (Test-Path $cur) {
        Copy-Item $cur (Join-Path $bak "$f.$stamp") -Force
        Get-ChildItem $bak -Filter "$f.*" | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | Remove-Item -Force
    }
}
Write-Host "backed up to $bak (*.$stamp)"

function Stop-Server {
    try { Stop-ScheduledTask -TaskPath '\UserCreated\' -TaskName 'Elevate Service' -ErrorAction SilentlyContinue } catch {}
    Get-Process RunAsAdminServer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
}
function Test-Server {
    Start-Sleep -Seconds 6
    $p = Get-Process RunAsAdminServer -ErrorAction SilentlyContinue
    $pipe = [IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -like '*RunAsAdmin' }
    return ($p -and $pipe)
}

$wasRunning = [bool](Get-Process RunAsAdminServer -ErrorAction SilentlyContinue)
if ($wasRunning) { Stop-Server }
try {
    foreach ($f in $files + @('RunAsAdminServer.exe.config', 'RunAsAdminClient.exe.config')) {
        $src = Join-Path $bin $f
        if (Test-Path $src) { Copy-Item $src (Join-Path $InstallDir $f) -Force }
    }
    foreach ($f in $libs) {
        $src = Join-Path $here "lib\$f"
        if ((Test-Path $src) -and -not (Test-Path (Join-Path $InstallDir $f))) { Copy-Item $src (Join-Path $InstallDir $f) }
    }
    if ($wasRunning) {
        Start-ScheduledTask -TaskPath '\UserCreated\' -TaskName 'Elevate Service'
        if (-not (Test-Server)) { throw 'the new server did not come up' }
        Write-Host 'installed; the server is running and its pipe exists'
    } else {
        Write-Host 'installed; the server was not running, so it was not started: the scheduled task starts it at the next logon'
    }
}
catch {
    Write-Host "FAILED: $_ - putting the old files back"
    Stop-Server
    foreach ($f in $all) {
        $b = Join-Path $bak "$f.$stamp"
        if (Test-Path $b) { Copy-Item $b (Join-Path $InstallDir $f) -Force }
    }
    Start-ScheduledTask -TaskPath '\UserCreated\' -TaskName 'Elevate Service'
    Write-Host 'rolled back'
    exit 1
}
