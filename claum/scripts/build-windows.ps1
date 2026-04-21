# ============================================================================
# Claum — Windows x64 build script (PowerShell)
# ----------------------------------------------------------------------------
# Equivalent of build-mac.sh for Windows. Requires:
#   * Visual Studio 2022 with "Desktop development with C++" workload
#   * Windows 10 SDK 10.0.22621 or later
#   * Python 3.11+ on PATH
#   * depot_tools on PATH (https://commondatastorage.googleapis.com/chrome-infra-docs/flat/depot_tools/docs/html/depot_tools_tutorial.html)
#   * ~120 GB free on the drive you set with -BuildRoot
#
# Usage (elevated PowerShell):
#   PS> .\claum\scripts\build-windows.ps1 -Arch x64
#   PS> .\claum\scripts\build-windows.ps1 -Arch x64 -DefaultSearch duckduckgo
#   PS> .\claum\scripts\build-windows.ps1 -SkipDownload
# ============================================================================

[CmdletBinding()]
param (
  [ValidateSet('x64','arm64')] [string]$Arch          = 'x64',
  [string]                     $DefaultSearch         = 'bing',
  [string]                     $BuildRoot             = "$HOME\claum-build",
  [switch]                     $SkipDownload          = $false,
  [switch]                     $Clean                 = $false
)

$ErrorActionPreference = 'Stop'

# --- Paths ------------------------------------------------------------------
$RepoDir = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$ChromiumVersion = (Get-Content (Join-Path $RepoDir 'CHROMIUM_VERSION')).Trim()
$UngoogledRepo   = 'https://github.com/ungoogled-software/ungoogled-chromium.git'

function Step($msg)  { Write-Host "==> $msg"  -ForegroundColor Cyan }
function Done($msg)  { Write-Host "  ✓ $msg"  -ForegroundColor Green }
function Warn($msg)  { Write-Host "  ⚠ $msg"  -ForegroundColor Yellow }
function Fail($msg)  { Write-Host "  ✗ $msg"  -ForegroundColor Red;  throw $msg }

@"

╔══════════════════════════════════════════════════╗
║   Claum Browser — Windows Build                  ║
║   Arch: $Arch  ·  Chromium $ChromiumVersion     ║
╚══════════════════════════════════════════════════╝
"@ | Write-Host

# -------- [1/6] Prereqs ----------------------------------------------------
Step '[1/6] Checking prerequisites'

foreach ($t in @('git','python','gclient','ninja','gn')) {
  if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
    Fail "$t not found on PATH. See header of this script for setup steps."
  }
  Done "$t"
}

# Visual Studio detection — look for vswhere.
$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $VsWhere)) {
  Fail 'Visual Studio 2022 not detected (vswhere.exe missing).'
}
$VsInstall = & $VsWhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $VsInstall) { Fail 'VS 2022 with C++ workload not installed.' }
Done "Visual Studio: $VsInstall"

# Disk space check.
$freeGB = [math]::Floor((Get-PSDrive -Name ($BuildRoot.Substring(0,1))).Free / 1GB)
if ($freeGB -lt 100) {
  Warn "Only $freeGB GB free on the build drive — Chromium needs ~120 GB."
  $ans = Read-Host '     Continue anyway? [y/N]'
  if ($ans -notmatch '^[Yy]$') { exit 1 }
} else {
  Done "Disk: $freeGB GB free"
}

# -------- [2/6] Clone ungoogled-chromium -----------------------------------
Step '[2/6] Syncing ungoogled-chromium'
if (Test-Path (Join-Path $BuildRoot '.git')) {
  git -C $BuildRoot fetch --depth=1 origin master
  git -C $BuildRoot reset --hard origin/master
} else {
  git clone --depth=1 $UngoogledRepo $BuildRoot
}
Done 'ungoogled-chromium ready'

# -------- [3/6] Download + unpack Chromium -------------------------------
if (-not $SkipDownload) {
  Step "[3/6] Downloading and unpacking Chromium $ChromiumVersion"
  Push-Location $BuildRoot
  try {
    python .\utils\downloads.py retrieve -c $ChromiumVersion -i .\downloads.ini -o .\build\downloads
    python .\utils\downloads.py unpack  -c .\build\downloads -i .\downloads.ini .\build\src
    python .\utils\prune_binaries.py    .\build\src .\pruning.list
    python .\utils\patches.py apply     .\build\src .\patches
    python .\utils\domain_substitution.py apply `
           -r .\domain_regex.list -f .\domain_substitution.list `
           -c .\build\domsubcache.tar.gz .\build\src
  } finally { Pop-Location }
} else {
  Done '[3/6] Skipping download (-SkipDownload)'
}

# -------- [4/6] Stage Claum resources --------------------------------------
Step '[4/6] Staging Claum resources'
$Src = Join-Path $BuildRoot 'build\src'
$Dest = Join-Path $Src 'chrome\browser\resources\claum_extensions'
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
robocopy "$RepoDir\claum\extensions\claum-newtab"      "$Dest\claum_newtab"     /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
robocopy "$RepoDir\claum\extensions\claude-for-chrome" "$Dest\claude_for_chrome" /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
Done 'Extensions copied'

# -------- [5/6] Apply Claum patches ----------------------------------------
Step '[5/6] Applying Claum patches'
Push-Location $Src
try {
  Get-ChildItem "$RepoDir\claum\patches\*.patch" | Sort-Object Name | ForEach-Object {
    Write-Host "     $($_.Name)"
    $check = git apply --check $_.FullName 2>$null
    if ($LASTEXITCODE -ne 0) {
      Warn "    skipping (already applied or conflicts)"
      return
    }
    git apply $_.FullName
  }
} finally { Pop-Location }
Done 'Patches applied'

# Copy branding overlay.
Copy-Item "$RepoDir\claum\branding\BRANDING" `
          "$Src\chrome\app\theme\chromium\BRANDING" -Force
if (Test-Path "$RepoDir\claum\branding\icons\app.ico") {
  Copy-Item "$RepoDir\claum\branding\icons\app.ico" `
            "$Src\chrome\app\theme\chromium\win\app.ico" -Force
}

# ---------------------------------------------------------------------------
# FIX: ungoogled-chromium's fix-building-without-safebrowsing.patch REMOVES
# the initial `sources = [...]` in chrome/browser/safe_browsing/BUILD.gn but
# leaves in place a later `sources += [...]`. Without a matching `sources =`
# in scope, `gn gen` dies with "Undefined identifier. sources += [".
#
# The helper script inserts `sources = []` just before the orphan `+=` so
# that gn has something to append to. Idempotent — safe to re-run.
# (Same script runs on mac and windows — it's just Python.)
# ---------------------------------------------------------------------------
Step 'Fixing chrome/browser/safe_browsing/BUILD.gn (ungoogled patch artifact)'
# On Windows the Python launcher is usually `python` (not `python3`).
python "$RepoDir\claum\scripts\fix-safe-browsing-gn.py" $Src

# -------- [6/6] gn gen + ninja ---------------------------------------------
Step '[6/6] Running gn gen and ninja'
Push-Location $Src
try {
  $OutDir = 'out\Claum'
  if ($Clean -and (Test-Path $OutDir)) {
    Warn "Removing previous build output ($OutDir)"
    Remove-Item $OutDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

  $gnArgs = @"
is_debug=false
is_official_build=true
symbol_level=1
blink_symbol_level=0
enable_nacl=false
enable_widevine=false
target_os="win"
target_cpu="$Arch"
chrome_pgo_phase=0
is_component_build=false
claum_default_search="$DefaultSearch"
claum_component_extensions=true
"@

  gn gen $OutDir --args=$gnArgs
  $jobs = [Environment]::ProcessorCount
  ninja -C $OutDir -j $jobs chrome
} finally { Pop-Location }

$ExePath = Join-Path $Src "out\Claum\chrome.exe"
@"

╔══════════════════════════════════════════════════╗
║                 Build complete                   ║
╠══════════════════════════════════════════════════╣
  Claum → $ExePath

  Launch it with:
    Start-Process $ExePath
╚══════════════════════════════════════════════════╝
"@ | Write-Host
