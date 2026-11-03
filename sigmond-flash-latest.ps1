<#
sigmond-flash-latest.ps1 — Windows version of sigmond-flash-latest.sh.

Downloads the NEWEST published Sigmond appliance image, writes it to a USB
stick, then reads the stick back and proves it matches.  The steps and the
safety rules are the bash script's:

  * the release folder is read with no Google login;
  * the newest version with both an .img and its .sha256 is chosen;
  * the download resumes if interrupted and is checked against the .sha256
    (a copy already downloaded and verified is reused);
  * the stick is found by attribute: USB bus AND Windows' "Removable Media".
    An external USB hard disk reports "External hard disk media" and is never
    picked; the boot and system disks are always refused;
  * you answer y to confirm; the whole image is read back.

Run from a PowerShell opened with "Run as administrator" (writing a whole
disk needs it):

  powershell -ExecutionPolicy Bypass -File .\sigmond-flash-latest.ps1
  ... -List              show what is published, write nothing
  ... -Version v3.84     a specific published version
  ... -Disk 2            name the disk (number from Get-Disk); still checked
  ... -DownloadOnly      fetch and verify, no stick
  ... -DryRun            every check, no write

Environment: SIGMOND_IMAGE_DIR (default %USERPROFILE%\sigmond-images),
SIGMOND_IMAGE_FOLDER (Drive folder id), ALLOW_FIXED=1 (allow a disk that is
not "Removable Media"; only with -Disk).  Works in Windows PowerShell 5.1 and
PowerShell 7.
#>
[CmdletBinding()]
param(
    [string]$Version = "",
    [int]$Disk = -1,
    [switch]$List,
    [switch]$DownloadOnly,
    [switch]$DryRun,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest's bar is very slow in 5.1

$FolderId = if ($env:SIGMOND_IMAGE_FOLDER) { $env:SIGMOND_IMAGE_FOLDER } else { '1Eym7xsP_qVvbGOVmlXER73K3jx6J7dQs' }
$ImgDir   = if ($env:SIGMOND_IMAGE_DIR) { $env:SIGMOND_IMAGE_DIR } else { Join-Path $HOME 'sigmond-images' }
$ListUrl  = "https://drive.google.com/embeddedfolderview?id=$FolderId"
$DlUrl    = 'https://drive.usercontent.google.com/download?export=download&confirm=t&id='

function Say([string]$m) { Write-Host ('{0}  {1}' -f ([DateTime]::UtcNow.ToString('HH:mm:ss') + 'Z'), $m) }
function Die([string]$m) { Write-Host ('{0}  ABORT: {1}' -f ([DateTime]::UtcNow.ToString('HH:mm:ss') + 'Z'), $m) -ForegroundColor Red; exit 1 }
function Sha256File([string]$p) { (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower() }

# Windows PowerShell 5.1 may default to TLS 1.0; Google requires 1.2+.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$IsWin = ($PSVersionTable.PSVersion.Major -le 5) -or $IsWindows
$Curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue
if (-not $Curl) { $Curl = Get-Command curl -CommandType Application -ErrorAction SilentlyContinue }
if (-not $Curl) { Die 'curl.exe not found (it ships with Windows 10 1803 and later)' }
$Curl = $Curl.Source
if ($Version -and -not $Version.StartsWith('v')) { $Version = "v$Version" }

# ── 1. what is published ────────────────────────────────────────────────────
Say 'reading the published image list'
try { $html = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri $ListUrl).Content }
catch { Die "cannot read the download folder ($ListUrl): $($_.Exception.Message)" }
$Ids = @{}
foreach ($m in [regex]::Matches($html, '<div class="flip-entry" id="entry-([A-Za-z0-9_-]+)".*?flip-entry-title">([^<]+)<', 'Singleline')) {
    $Ids[$m.Groups[2].Value] = $m.Groups[1].Value
}
if ($Ids.Count -eq 0) { Die 'the download folder listing had no files (did Google change the page?)' }

$Versions = @(@(foreach ($name in $Ids.Keys) {
    if ($name -match '^sigmond-appliance-(v[0-9.]+)-([0-9]{8})-release\.img$') {
        $ver = $Matches[1]; $built = $Matches[2]
        if ($Ids.ContainsKey("sigmond-appliance-$ver-$built-release.sha256")) {
            [pscustomobject]@{ V = $ver; D = $built; Key = [version]($ver.TrimStart('v')) }
        }
    }
}) | Sort-Object Key, D)
if ($Versions.Count -eq 0) { Die 'no published image with a checksum found' }

if ($List) {
    Say 'published images (newest last):'
    $Versions | ForEach-Object { Write-Host "          $($_.V) $($_.D)" }
    exit 0
}
if ($Version) {
    $Pick = $Versions | Where-Object { $_.V -eq $Version } | Select-Object -Last 1
    if (-not $Pick) { Die "$Version is not published; published: $(($Versions | ForEach-Object V) -join ' ')" }
} else {
    $Pick = $Versions | Select-Object -Last 1
}
$Stem = "sigmond-appliance-$($Pick.V)-$($Pick.D)-release"
$ImgName = "$Stem.img"
Say "selected: $ImgName  (version $($Pick.V), built $($Pick.D))"

# ── 2. the checksum, then the image (reused if already here and good) ──────
New-Item -ItemType Directory -Force -Path $ImgDir | Out-Null
$Img = Join-Path $ImgDir $ImgName
$WantSha = (& $Curl -fsSL --max-time 60 "$DlUrl$($Ids["$Stem.sha256"])" | Select-Object -First 1)
if ($WantSha) { $WantSha = ($WantSha -split '\s+')[0].ToLower() }
if ($WantSha -notmatch '^[0-9a-f]{64}$') { Die "could not read the published sha256 for $ImgName" }
Say "published sha256 $($WantSha.Substring(0,16))..."

if (Test-Path -LiteralPath $Img) {
    Say "found $Img already - checking it"
    if ((Sha256File $Img) -eq $WantSha) { Say '  it matches the published checksum; not downloading again' }
    else { Say '  it does NOT match; downloading again'; Remove-Item -LiteralPath $Img }
}
if (-not (Test-Path -LiteralPath $Img)) {
    $Part = "$Img.part"
    $root = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $ImgDir).Path)
    $free = ([IO.DriveInfo]::new($root)).AvailableFreeSpace
    if ($free -lt 6GB) { Die "$ImgDir has $([math]::Floor($free/1MB)) MiB free; the image needs about 5600 MiB (set SIGMOND_IMAGE_DIR elsewhere)" }
    Say "downloading to $ImgDir (resumes if interrupted; rerun to continue)"
    & $Curl -fL --retry 5 --retry-delay 5 -C - -o $Part "$DlUrl$($Ids[$ImgName])"
    if ($LASTEXITCODE -ne 0) { Die 'download failed - rerun this script to resume' }
    $len = (Get-Item -LiteralPath $Part).Length
    if ($len -lt 1000000000) { Remove-Item -LiteralPath $Part; Die "download is only $len bytes - Google returned a page, not the image; try again later" }
    Say 'verifying the download'
    $gotSha = Sha256File $Part
    if ($gotSha -ne $WantSha) { Remove-Item -LiteralPath $Part; Die "download checksum $($gotSha.Substring(0,16))... does not match the published $($WantSha.Substring(0,16))... - deleted; rerun to fetch again" }
    Move-Item -LiteralPath $Part -Destination $Img
    Say "download verified: $Img"
}
$Bytes = (Get-Item -LiteralPath $Img).Length

if ($DownloadOnly) { Say "DONE (download only): $Img is $($Pick.V), sha256 $($WantSha.Substring(0,16))..."; exit 0 }
if (-not $IsWin) { Die 'writing a stick needs Windows here; on Linux or macOS use sigmond-flash-latest.sh' }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Die 'writing a disk needs an administrator PowerShell: right-click PowerShell, "Run as administrator", and run this again' }

# ── 3. the stick, found by attribute and never by guess ────────────────────
function IsRemovable([int]$num) {
    $dd = Get-CimInstance Win32_DiskDrive | Where-Object { $_.Index -eq $num }
    return ($dd -and $dd.MediaType -eq 'Removable Media')
}
if ($Disk -ge 0) {
    $D = Get-Disk -Number $Disk -ErrorAction SilentlyContinue
    if (-not $D) { Die "no disk number $Disk (see Get-Disk)" }
    if (-not (IsRemovable $Disk)) {
        if ($env:ALLOW_FIXED -ne '1') { Die "disk $Disk is not removable (a fixed disk, not a stick); refusing" }
        Say 'ALLOW_FIXED=1 - proceeding against a FIXED disk'
    }
} else {
    $Cands = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and (IsRemovable $_.Number) })
    foreach ($cand in $Cands) { Say "found USB stick: disk $($cand.Number)  $([math]::Round($cand.Size/1e9)) GB  $($cand.FriendlyName)" }
    if ($Cands.Count -ne 1) { Die "expected exactly one USB stick plugged in, found $($Cands.Count) - plug in one, or name it: -Disk N (see Get-Disk)" }
    $D = $Cands[0]
}
if ($D.IsBoot -or $D.IsSystem) { Die "disk $($D.Number) CARRIES THE RUNNING SYSTEM - refusing" }
$N = $D.Number
if ($Bytes -gt $D.Size) { Die "the image ($([math]::Floor($Bytes/1MB)) MiB) does not fit on disk $N ($([math]::Floor($D.Size/1MB)) MiB)" }

Say "about to ERASE disk $N ($($D.FriendlyName), $([math]::Round($D.Size/1e9)) GB):"
Get-Partition -DiskNumber $N -ErrorAction SilentlyContinue |
    Format-Table PartitionNumber, DriveLetter, @{n='SizeGB';e={[math]::Round($_.Size/1e9,1)}}, Type -AutoSize | Out-String | Write-Host
if ($DryRun) { Say 'DRY RUN - every check passed; nothing written'; exit 0 }
if (-not $Force) {
    $ans = Read-Host "erase disk $N and write the image? [y/N]"
    if ($ans -notin @('y', 'yes', "$N")) { Die 'not confirmed - nothing written' }
}

# ── 4. write ────────────────────────────────────────────────────────────────
# Windows refuses raw writes over a mounted volume, so drop the partitions
# first.  A blank or Linux-formatted stick has nothing to clear: ignore that.
try { Clear-Disk -Number $N -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop } catch {}
Update-Disk -Number $N -ErrorAction SilentlyContinue
$Sector = 4096          # a multiple of every sector size in use (512, 4096)
$Chunk = 4MB
$buf = New-Object byte[] $Chunk
$Path = "\\.\PhysicalDrive$N"
Say "writing $([math]::Floor($Bytes/1MB)) MiB to $Path - a few minutes"
$t0 = Get-Date
$in = [IO.File]::OpenRead($Img)
$out = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite, $Sector, [IO.FileOptions]::WriteThrough)
try {
    $done = [long]0; $lastPct = -1
    while (($cnt = $in.Read($buf, 0, $Chunk)) -gt 0) {
        $w = $cnt
        if ($cnt % $Sector) {      # last piece: pad to whole sectors (zeros past the image end)
            $w = $cnt + ($Sector - $cnt % $Sector)
            [Array]::Clear($buf, $cnt, $w - $cnt)
        }
        $out.Write($buf, 0, $w)
        $done += $cnt
        $pct = [math]::Floor(100 * $done / $Bytes)
        if ($pct -ge $lastPct + 5) { Say "  $pct %"; $lastPct = $pct }
    }
    $out.Flush()
} catch { Die "write failed: $($_.Exception.Message)" }
finally { $in.Close(); $out.Close() }
Say "wrote in $([math]::Round(((Get-Date) - $t0).TotalSeconds))s"

# ── 5. read it back — the only step that proves anything ───────────────────
Say 'reading the stick back and comparing'
$sha = [Security.Cryptography.SHA256]::Create()
$rd = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite, $Sector)
try {
    $left = [long]$Bytes
    while ($left -gt 0) {
        $want = [long][math]::Min($Chunk, $left)
        $ask = $want; if ($ask % $Sector) { $ask += $Sector - $ask % $Sector }
        $have = 0
        while ($have -lt $ask) {
            $r = $rd.Read($buf, $have, $ask - $have)
            if ($r -le 0) { Die 'short read from the stick' }
            $have += $r
        }
        [void]$sha.TransformBlock($buf, 0, [int]$want, $null, 0)
        $left -= $want
    }
    [void]$sha.TransformFinalBlock($buf, 0, 0)
} finally { $rd.Close() }
$Back = -join ($sha.Hash | ForEach-Object { $_.ToString('x2') })
Update-Disk -Number $N -ErrorAction SilentlyContinue

if ($Back -eq $WantSha) {
    Write-Host ''
    Say "VERIFIED - disk $N matches the published image byte for byte"
    Say "INSTALLED ON THE STICK: $ImgName"
    Say "   version $($Pick.V), built $($Pick.D), sha256 $WantSha"
    if ($Ids.ContainsKey("$Stem.INSTALL.html")) { Say "   install guide: https://drive.google.com/file/d/$($Ids["$Stem.INSTALL.html"])/view" }
    Say 'Windows cannot read the stick''s Linux partitions: if it offers to FORMAT the disk, click Cancel.'
    Say 'Remove the stick. Connect the RX888 (and GPSDO) BEFORE booting the target machine from it.'
} else {
    Die "READ-BACK MISMATCH: stick $($Back.Substring(0,16))... vs image $($WantSha.Substring(0,16))... - DO NOT USE THIS STICK; rerun"
}
