<#
.SYNOPSIS
    Read-only reconciliation of your local OneDrive Personal folder against the
    cloud, via the Microsoft Graph API. Finds files that are local-only,
    cloud-only, or present on both sides but mismatched (size or content hash).

.DESCRIPTION
    The local OneDrive client's own status can be wrong (the "Moving files,
    0 remaining" jam being a prime example). This script ignores the client and
    asks the service directly what it holds, then diffs that against disk.

    It makes NO changes to either side. Output is a console summary plus an
    optional CSV of every discrepancy.

    Hashing: OneDrive Personal returns sha256Hash / sha1Hash per file, so true
    content comparison is possible. Online-only (Files On-Demand) placeholders
    are NOT downloaded — they are compared by size + modified-time only.

.PARAMETER ClientId
    The Application (client) ID of your own Entra app registration. See SETUP.

.PARAMETER Path
    Optional subfolder (relative to the OneDrive root, e.g. "!CP+MH") to limit
    the comparison. Default: the entire OneDrive Personal library.

.PARAMETER OutCsv
    Optional path to write a full discrepancy report as CSV.

.PARAMETER IncludeInSync
    Also list files that match (otherwise only discrepancies are shown).

.PARAMETER MaxHashMB
    Skip content-hashing of local files larger than this (compare by size only).
    Default 2048. Set 0 to disable hashing entirely (size/time compare).

.PARAMETER NoTokenCache
    Do not cache the refresh token to disk (you will device-code each run).

# ---------------------------------------------------------------------------
# SETUP — one-time, ~5 minutes (free)
# ---------------------------------------------------------------------------
#  1. Go to https://entra.microsoft.com  ->  Applications  ->  App registrations
#     ->  New registration.
#  2. Name: anything (e.g. "OneDrive Reconciler").
#     Supported account types: "Personal Microsoft accounts only".
#     Register.
#  3. Copy the "Application (client) ID" shown on the overview page — that is
#     the value you pass as -ClientId.
#  4. Left menu -> Authentication -> Advanced settings ->
#     "Allow public client flows" = Yes.  Save.
#  5. Left menu -> API permissions -> Add a permission -> Microsoft Graph ->
#     Delegated permissions -> add  Files.Read  (read-only). Save.
#     (No admin consent is needed for delegated Files.Read on a personal account.)
#
#  Then:  .\Compare-OneDriveCloud.ps1 -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
# ---------------------------------------------------------------------------

.EXAMPLE
    .\Compare-OneDriveCloud.ps1 -ClientId $cid -Path "!CP+MH" -OutCsv .\diff.csv

.NOTES
    Windows PowerShell 5.1+ compatible. Read-only. No external modules required.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ClientId,
    [string]$Path,
    [string]$OutCsv,
    [switch]$IncludeInSync,
    [int]$MaxHashMB = 2048,
    [switch]$NoTokenCache
)

$ErrorActionPreference = 'Stop'
$Authority = 'https://login.microsoftonline.com/consumers/oauth2/v2.0'
$Scope     = 'Files.Read offline_access'
$GraphRoot = 'https://graph.microsoft.com/v1.0'
$CacheFile = Join-Path $env:LOCALAPPDATA 'OneDriveReconciler\token.cache'

function Write-Section { param($t) Write-Host ""; Write-Host ("=" * 70) -ForegroundColor DarkCyan; Write-Host "  $t" -ForegroundColor Cyan; Write-Host ("=" * 70) -ForegroundColor DarkCyan }
function Write-OK   { param($m) Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Info { param($m) Write-Host "  [INFO] $m" -ForegroundColor Gray }

# ---------------------------------------------------------------------------
# Auth — device code flow, with optional DPAPI-protected refresh-token cache
# ---------------------------------------------------------------------------
function Save-RefreshToken { param($Rt)
    if ($NoTokenCache -or -not $Rt) { return }
    $dir = Split-Path $CacheFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # ConvertFrom-SecureString uses Windows DPAPI, scoped to this user account.
    (ConvertTo-SecureString $Rt -AsPlainText -Force | ConvertFrom-SecureString) | Set-Content -Path $CacheFile
}

function Read-RefreshToken {
    if ($NoTokenCache -or -not (Test-Path $CacheFile)) { return $null }
    try {
        $sec = Get-Content $CacheFile | ConvertTo-SecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { return $null }
}

function Get-AccessToken {
    # Try silent refresh first.
    $rt = Read-RefreshToken
    if ($rt) {
        try {
            $r = Invoke-RestMethod -Method Post -Uri "$Authority/token" -Body @{
                client_id = $ClientId; grant_type = 'refresh_token'
                refresh_token = $rt; scope = $Scope
            }
            Save-RefreshToken $r.refresh_token
            Write-Info "Reused cached sign-in."
            return $r.access_token
        } catch { Write-Info "Cached token expired; signing in again." }
    }

    # Device code flow.
    $dc = Invoke-RestMethod -Method Post -Uri "$Authority/devicecode" -Body @{ client_id = $ClientId; scope = $Scope }
    Write-Host ""
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  $($dc.message)" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Yellow
    $interval = [int]$dc.interval
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $r = Invoke-RestMethod -Method Post -Uri "$Authority/token" -Body @{
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                client_id   = $ClientId
                device_code = $dc.device_code
            }
            Save-RefreshToken $r.refresh_token
            Write-OK "Signed in."
            return $r.access_token
        } catch {
            $detail = $null
            try { $detail = $_.ErrorDetails.Message | ConvertFrom-Json } catch { }
            switch ($detail.error) {
                'authorization_pending' { continue }
                'slow_down'             { $interval += 5; continue }
                default { throw "Sign-in failed: $($detail.error_description)$($_.Exception.Message)" }
            }
        }
    }
    throw "Sign-in timed out."
}

# ---------------------------------------------------------------------------
# Graph GET with throttling-aware retry (429 / 503 honour Retry-After)
# ---------------------------------------------------------------------------
function Invoke-Graph { param([string]$Uri, [string]$Token)
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Uri -Method Get -Headers @{ Authorization = "Bearer $Token" }
        } catch {
            $resp = $_.Exception.Response
            $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
            if ($code -in 429,503,504) {
                $wait = 5
                try { $h = $resp.Headers['Retry-After']; if ($h) { $wait = [int]$h } } catch { }
                Write-Info "Throttled ($code); waiting $wait s..."
                Start-Sleep -Seconds ([Math]::Max($wait, 5))
                continue
            }
            throw
        }
    }
    throw "Graph request failed after retries: $Uri"
}

# ---------------------------------------------------------------------------
# Locate local OneDrive Personal root
# ---------------------------------------------------------------------------
function Get-OneDrivePersonalPath {
    try {
        $uf = (Get-ItemProperty 'HKCU:\Software\Microsoft\OneDrive\Accounts\Personal' -ErrorAction Stop).UserFolder
        if ($uf -and (Test-Path $uf)) { return $uf }
    } catch { }
    foreach ($v in @($env:OneDriveConsumer, $env:OneDrive)) { if ($v -and (Test-Path $v)) { return $v } }
    return $null
}

# ===========================================================================
Write-Host ""
Write-Host "  OneDrive Local <-> Cloud Reconciler (read-only)" -ForegroundColor White

$odPath = Get-OneDrivePersonalPath
if (-not $odPath) { throw "Could not find your OneDrive Personal folder. Is OneDrive signed in?" }
Write-Info "Local root: $odPath"

# Resolve optional focus prefix (relative, forward-slash, lower-cased for matching)
$relPrefix = ''
$scanRoot  = $odPath
if ($Path) {
    $scanRoot = if (Test-Path $Path) { (Resolve-Path $Path).Path } else { Join-Path $odPath $Path }
    if (-not (Test-Path $scanRoot)) { throw "Focus path not found: $scanRoot" }
    $relPrefix = $scanRoot.Substring($odPath.Length).TrimStart('\','/').Replace('\','/')
    Write-Info "Limiting comparison to: $relPrefix"
}
$prefixLower = $relPrefix.ToLowerInvariant()

# ---------------------------------------------------------------------------
Write-Section "1. Authenticate"
$token = Get-AccessToken

# ---------------------------------------------------------------------------
Write-Section "2. Enumerate cloud (Graph delta)"
$cloud = @{}
$uri = "$GraphRoot/me/drive/root/delta"
$count = 0
do {
    $page = Invoke-Graph -Uri $uri -Token $token
    foreach ($item in $page.value) {
        if ($item.deleted -or $item.root -or $item.folder) { continue }   # files only
        $parent = $item.parentReference.path                              # /drive/root:/Folder/Sub
        $relDir = ''
        if ($parent) { $relDir = ([uri]::UnescapeDataString(($parent -replace '^/drive/root:?',''))).TrimStart('/') }
        $rel = if ($relDir) { "$relDir/$($item.name)" } else { $item.name }
        $key = $rel.ToLowerInvariant()
        if ($prefixLower -and -not ($key.StartsWith("$prefixLower/") -or $key -eq $prefixLower)) { continue }
        $cloud[$key] = [pscustomobject]@{
            Path     = $rel
            Size     = [int64]$item.size
            Sha1     = $item.file.hashes.sha1Hash
            Sha256   = $item.file.hashes.sha256Hash
            Modified = [datetime]$item.lastModifiedDateTime
        }
        $count++
    }
    $uri = $page.'@odata.nextLink'
} while ($uri)
Write-OK "Indexed $count cloud file(s)."

# ---------------------------------------------------------------------------
Write-Section "3. Enumerate local & compare"
$results  = New-Object System.Collections.Generic.List[object]
$seenCloud = @{}
$maxBytes = [int64]$MaxHashMB * 1MB

$localItems = Get-ChildItem -LiteralPath $scanRoot -Recurse -File -Force -ErrorAction SilentlyContinue
$n = 0
foreach ($f in $localItems) {
    $n++
    if ($f.Name -like '~$*') { continue }               # skip Office lock files
    $rel = $f.FullName.Substring($odPath.Length).TrimStart('\','/').Replace('\','/')
    $key = $rel.ToLowerInvariant()
    $onlineOnly = (($f.Attributes -band [IO.FileAttributes]::Offline) -ne 0)

    if ($cloud.ContainsKey($key)) {
        $c = $cloud[$key]
        $seenCloud[$key] = $true
        $status = $null; $detail = $null

        if ($f.Length -ne $c.Size) {
            $status = 'SizeMismatch'; $detail = "local=$($f.Length) cloud=$($c.Size)"
        }
        elseif ($onlineOnly -or $MaxHashMB -eq 0 -or $f.Length -gt $maxBytes) {
            # Can't (or chose not to) hash: size matches, fall back to time check.
            $dt = [math]::Abs(($f.LastWriteTimeUtc - $c.Modified.ToUniversalTime()).TotalSeconds)
            if ($dt -gt 2) { $status = 'TimeMismatch'; $detail = "dt=$([int]$dt)s (size matches; not hashed)" }
            else           { $status = 'InSync';       $detail = 'size+time (not hashed)' }
        }
        else {
            # Content hash compare — prefer sha256 if the cloud provided it.
            if ($c.Sha256)   { $alg='SHA256'; $cloudHash=$c.Sha256 }
            elseif ($c.Sha1) { $alg='SHA1';   $cloudHash=$c.Sha1 }
            else             { $alg=$null }

            if ($alg) {
                $localHash = (Get-FileHash -LiteralPath $f.FullName -Algorithm $alg).Hash
                if ($localHash -ieq $cloudHash) { $status='InSync';       $detail="$alg match" }
                else                            { $status='HashMismatch'; $detail="$alg differs" }
            } else {
                $status = 'InSync'; $detail = 'size match (no cloud hash)'
            }
        }
        $results.Add([pscustomobject]@{ Status=$status; Path=$rel; Detail=$detail })
    }
    else {
        $results.Add([pscustomobject]@{ Status='LocalOnly'; Path=$rel
            Detail = if ($onlineOnly) {'online-only placeholder w/ no cloud match'} else {'pending upload or failed upload'} })
    }
}

# Cloud entries never matched by a local file
foreach ($key in $cloud.Keys) {
    if (-not $seenCloud.ContainsKey($key)) {
        $results.Add([pscustomobject]@{ Status='CloudOnly'; Path=$cloud[$key].Path; Detail='missing locally (pending download?)' })
    }
}

# ---------------------------------------------------------------------------
Write-Section "Reconciliation summary"
$order = 'HashMismatch','SizeMismatch','TimeMismatch','LocalOnly','CloudOnly','InSync'
$grouped = $results | Group-Object Status
foreach ($s in $order) {
    $g = $grouped | Where-Object Name -eq $s
    $cnt = if ($g) { $g.Count } else { 0 }
    $color = switch ($s) { 'InSync' {'Green'} 'CloudOnly' {'Yellow'} 'LocalOnly' {'Yellow'} default {'Red'} }
    Write-Host ("  {0,-14} {1}" -f $s, $cnt) -ForegroundColor $color
}

$problems = $results | Where-Object { $_.Status -ne 'InSync' } | Sort-Object Status, Path
if ($problems) {
    Write-Host ""
    Write-Host "  Discrepancies (first 40):" -ForegroundColor White
    $problems | Select-Object -First 40 | ForEach-Object {
        Write-Host ("   [{0}] {1}  ({2})" -f $_.Status, $_.Path, $_.Detail) -ForegroundColor Gray
    }
    if ($problems.Count -gt 40) { Write-Host "   ... and $($problems.Count - 40) more (use -OutCsv for the full list)." -ForegroundColor DarkGray }
} else {
    Write-OK "Local and cloud are fully reconciled — no discrepancies."
}

if ($OutCsv) {
    $toWrite = if ($IncludeInSync) { $results } else { $problems }
    $toWrite | Sort-Object Status, Path | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Info "Full report written to: $OutCsv"
}

Write-Host ""
Write-Host "  Done (read-only — nothing was changed)." -ForegroundColor White
