<#
.SYNOPSIS
  Builds WordMarkdown.dotm (VBA + ribbon) and installs it for Microsoft Word.

.DESCRIPTION
  1. Uses Word itself to create a macro-enabled template and import the VBA
     source (src\MarkdownIO.bas, src\AppEvents.cls).  This needs Word's
     "Trust access to the VBA project object model" setting (see below).
  2. Runs MarkdownIO.SelfTest so a compile error stops the build.
  3. Adds the ribbon XML (src\customUI14.xml) to the saved template.
  4. Installs it to Word's STARTUP folder, and installs the Pandoc support
     files (filters, reference.docx) to %APPDATA%\WordMarkdown.
  Existing installed files are backed up first (BAK\, 3 newest kept).

.PARAMETER EnableVbomTemporarily
  Word blocks scripts from touching VBA unless
    File > Options > Trust Center > Trust Center Settings > Macro Settings >
    "Trust access to the VBA project object model"
  is ticked.  Tick it yourself, or pass this switch to have the script turn it
  on for the build and put the old value back afterwards.
#>
[CmdletBinding()]
param(
    [switch]$EnableVbomTemporarily,
    [switch]$NoSign,
    [string]$CertMatch = 'Chris Pollitt',
    [string]$StartupDir = (Join-Path $env:APPDATA 'Microsoft\Word\STARTUP'),
    [string]$SupportDir = (Join-Path $env:APPDATA 'WordMarkdown')
)

$ErrorActionPreference = 'Stop'
$proj  = Split-Path -Parent $PSScriptRoot
$src   = Join-Path $proj 'src'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Backup-File([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $bak = Join-Path (Split-Path -Parent $path) 'BAK'
    New-Item -ItemType Directory -Force -Path $bak | Out-Null
    $name = Split-Path -Leaf $path
    Copy-Item -LiteralPath $path -Destination (Join-Path $bak "$name.bak-$stamp")
    Get-ChildItem -LiteralPath $bak -Filter "$name.bak-*" |
        Sort-Object Name -Descending | Select-Object -Skip 3 |
        Remove-Item -Force
}

# --- signing the VBA project ---------------------------------------------------
# Word has no API for signing VBA, so this opens the VBE's own Tools > Digital
# Signature dialog and lets build\Sign-Helper.ps1 (a separate process, started
# first) click through the dialogs.  Everything it sees is logged to $signLog.
$signLog = Join-Path $env:TEMP 'WordMarkdown-sign.log'

function Sign-VbaProject($word, $vbp, [string]$certMatch, [string]$log) {
    $word.VBE.MainWindow.Visible = $true
    $vbp.VBComponents.Item('MarkdownIO').CodeModule.CodePane.Show()   # makes this project the active one

    $item = $null
    foreach ($m in $word.VBE.CommandBars.Item('Menu Bar').Controls) {
        if ($m.Caption -match 'Tools') {
            foreach ($i in $m.Controls) { if ($i.Caption -match 'Digital Signature') { $item = $i } }
        }
    }
    if (-not $item) { throw 'Could not find Tools > Digital Signature in the VBA editor.' }
    if (-not $item.Enabled) { throw 'Tools > Digital Signature is disabled in the VBA editor.' }

    $wordPid = (Get-Process WINWORD | Select-Object -First 1).Id
    $helper = Join-Path $PSScriptRoot 'Sign-Helper.ps1'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $helper + '"'),
                 '-WordPid', $wordPid, '-CertMatch', ('"' + $certMatch + '"'), '-Log', ('"' + $log + '"'))
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru

    $item.Execute()          # opens the dialog and returns at once; the helper does the clicking
    if (-not $p.WaitForExit(110000)) { try { $p.Kill() } catch {}; return 'timed out' }
    for ($i = 0; $i -lt 30; $i++) {          # wait until Word answers again
        try { [void]$word.Visible; break } catch { Start-Sleep -Milliseconds 500 }
    }
    try { $word.VBE.MainWindow.Visible = $false } catch {}
    if ($p.ExitCode -eq 0) { return 'signed' } else { return 'helper gave up' }
}


# Does the saved .dotm contain a VBA digital-signature stream?
# Office keeps the VBA signature in its own package part(s) next to vbaProject.bin.
function Test-VbaSigned([string]$dotm) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($dotm)
    try { return [bool]($z.Entries | Where-Object { $_.FullName -like "word/vbaProjectSignature*.bin" }) }
    finally { $z.Dispose() }
}

# --- preconditions -----------------------------------------------------------
if (Get-Process WINWORD -ErrorAction SilentlyContinue) {
    throw 'Word is running. Close all Word windows and run this again.'
}
foreach ($f in 'MarkdownIO.bas', 'AppEvents.cls', 'customUI14.xml') {
    if (-not (Test-Path (Join-Path $src $f))) { throw "Missing source file: $src\$f" }
}

$secKey = 'HKCU:\Software\Microsoft\Office\16.0\Word\Security'
$old = $null
if (Test-Path $secKey) { $old = (Get-ItemProperty $secKey -ErrorAction SilentlyContinue).AccessVBOM }
$vbomChanged = $false
if ($old -ne 1) {
    if ($EnableVbomTemporarily) {
        New-Item -Path $secKey -Force | Out-Null
        Set-ItemProperty -Path $secKey -Name AccessVBOM -Value 1 -Type DWord
        $vbomChanged = $true
        Write-Host 'Turned on "Trust access to the VBA project object model" for this build.'
    } else {
        throw ('Word does not allow scripts to access VBA projects.' + [Environment]::NewLine +
               'Tick File > Options > Trust Center > Trust Center Settings > Macro Settings >' + [Environment]::NewLine +
               '"Trust access to the VBA project object model", then run this again' + [Environment]::NewLine +
               '(or run it with -EnableVbomTemporarily).')
    }
}

# --- build the template with Word -------------------------------------------
$work = Join-Path $env:TEMP "WordMarkdown-build-$stamp"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$built = Join-Path $work 'WordMarkdown.dotm'

$word = $null
try {
    $word = New-Object -ComObject Word.Application
    $word.Visible = $true          # so that a VBA compile-error dialog can be seen
    $doc = $word.Documents.Add()
    $vbp = $doc.VBProject
    $vbp.Name = 'WordMarkdown'
    [void]$vbp.VBComponents.Import((Join-Path $src 'MarkdownIO.bas'))
    [void]$vbp.VBComponents.Import((Join-Path $src 'AppEvents.cls'))

    $result = $word.Run('MarkdownIO.SelfTest')
    Write-Host "SelfTest: $result"

    if (-not $NoSign) {
        Remove-Item -LiteralPath $signLog -ErrorAction SilentlyContinue
        Write-Host "Signing the VBA project with '$CertMatch' (do not touch the Word windows that pop up)..."
        try { $signRes = Sign-VbaProject $word $vbp $CertMatch $signLog; Write-Host "Signing step: $signRes" }
        catch { Write-Warning "Signing step failed: $_" }
    }

    # FileFormat 15 = wdFormatXMLTemplateMacroEnabled
    [void]$doc.GetType().InvokeMember('SaveAs2',
        [System.Reflection.BindingFlags]::InvokeMethod, $null, $doc,
        @([string]$built, [int]15))
    $doc.Close(0)
} finally {
    if ($word) { try { $word.Quit(0) } catch {} }
    foreach ($o in @($vbp, $doc, $word)) { if ($o) { try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($o) } catch {} } }
    $doc = $null; $vbp = $null; $word = $null
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    # Word keeps the old STARTUP template open until it has really exited
    $t0 = Get-Date
    while ((Get-Process WINWORD -ErrorAction SilentlyContinue) -and ((Get-Date) - $t0).TotalSeconds -lt 8) { Start-Sleep -Milliseconds 250 }
    Write-Host ("Word exited after {0:N1}s" -f ((Get-Date) - $t0).TotalSeconds)
    Get-Process WINWORD -ErrorAction SilentlyContinue | Stop-Process -Force
    if ($vbomChanged) {
        if ($null -eq $old) { Remove-ItemProperty -Path $secKey -Name AccessVBOM -ErrorAction SilentlyContinue }
        else { Set-ItemProperty -Path $secKey -Name AccessVBOM -Value $old -Type DWord }
        Write-Host 'Put the VBA-access setting back the way it was.'
    }
}
if (-not (Test-Path $built)) { throw 'Word did not produce the template.' }

$isSigned = $false
if (-not $NoSign) {
    $isSigned = Test-VbaSigned $built
    if ($isSigned) { Write-Host 'The template carries a VBA digital signature.' }
    else {
        Write-Warning ('The template is NOT signed. Install continues; sign it by hand (see README) or send me ' + $signLog)
    }
}

# --- add the ribbon -----------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$utf8 = New-Object System.Text.UTF8Encoding($false)
$zip = [System.IO.Compression.ZipFile]::Open($built, [System.IO.Compression.ZipArchiveMode]::Update)
try {
    $ui = $zip.CreateEntry('customUI/customUI14.xml')
    $w = New-Object System.IO.StreamWriter($ui.Open(), $utf8)
    $w.Write([System.IO.File]::ReadAllText((Join-Path $src 'customUI14.xml')))
    $w.Dispose()

    $relEntry = $zip.GetEntry('_rels/.rels')
    $r = New-Object System.IO.StreamReader($relEntry.Open())
    $rels = $r.ReadToEnd(); $r.Dispose()
    $rel = '<Relationship Id="rIdWordMarkdownUI" Type="http://schemas.microsoft.com/office/2007/relationships/ui/extensibility" Target="customUI/customUI14.xml"/>'
    $rels = $rels -replace '</Relationships>', ($rel + '</Relationships>')
    $relEntry.Delete()
    $newRel = $zip.CreateEntry('_rels/.rels')
    $w = New-Object System.IO.StreamWriter($newRel.Open(), $utf8)
    $w.Write($rels); $w.Dispose()
} finally {
    $zip.Dispose()
}

# --- install -------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $StartupDir, $SupportDir, (Join-Path $SupportDir 'filters') | Out-Null

$target = Join-Path $StartupDir 'WordMarkdown.dotm'
Backup-File $target
for ($try = 1; $try -le 10; $try++) {
    try { Copy-Item -LiteralPath $built -Destination $target -Force -ErrorAction Stop; break }
    catch { if ($try -eq 10) { throw }; Start-Sleep -Seconds 1 }
}

foreach ($f in 'md-to-word.lua', 'word-to-md.lua') {
    $dest = Join-Path $SupportDir "filters\$f"
    Backup-File $dest
    Copy-Item -LiteralPath (Join-Path $proj "filters\$f") -Destination $dest -Force
}
$refDest = Join-Path $SupportDir 'reference.docx'
if (-not (Test-Path $refDest)) {
    Copy-Item -LiteralPath (Join-Path $proj 'ref\reference.docx') -Destination $refDest
} else {
    Write-Host "Kept your existing $refDest (edit its styles to change how Markdown looks in Word)."
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "Installed: $target"
Write-Host "Support:   $SupportDir"
Write-Host 'Start Word: there is a new "Markdown" tab on the ribbon.'
$pandoc = Get-Command pandoc -ErrorAction SilentlyContinue
if ($pandoc) { Write-Host "Pandoc found: $($pandoc.Source)" }
else { Write-Host 'Pandoc is not on PATH; the add-in will look in the usual places or ask you for it.' }
