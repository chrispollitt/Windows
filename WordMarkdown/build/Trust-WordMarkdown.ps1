<#
.SYNOPSIS
  Makes Word trust macros in its STARTUP folder, so WordMarkdown.dotm loads
  without the "SECURITY WARNING - Enable Content" bar.

.DESCRIPTION
  Adds %APPDATA%\Microsoft\Word\STARTUP (this folder only, no subfolders) as a
  Trusted Location for Word, for the current user.  Use -Remove to undo it.
  Anything placed in that folder is then trusted, so keep it to templates you
  put there yourself.
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [string]$StartupDir = (Join-Path $env:APPDATA 'Microsoft\Word\STARTUP')
)

$ErrorActionPreference = 'Stop'
$key = 'HKCU:\Software\Microsoft\Office\16.0\Word\Security\Trusted Locations\WordMarkdownStartup'
$path = $StartupDir.TrimEnd('\') + '\'

if ($Remove) {
    if (Test-Path $key) { Remove-Item $key -Recurse; Write-Host 'Removed the trusted location.' }
    else { Write-Host 'Nothing to remove.' }
    return
}

New-Item -Path $key -Force | Out-Null
Set-ItemProperty -Path $key -Name Path -Value $path
Set-ItemProperty -Path $key -Name AllowSubFolders -Value 0 -Type DWord
Set-ItemProperty -Path $key -Name Description -Value 'WordMarkdown add-in (Word STARTUP folder)'
Write-Host "Trusted location added: $path"
Write-Host 'Restart Word; the security bar should be gone.'
Write-Host 'To undo: run this script with -Remove.'
