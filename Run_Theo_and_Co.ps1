# Theo and Co - starter (bootstrap).
#
# THIS FILE IS DELIBERATELY STABLE. Its only job: make sure Launch_EQ.ps1 is
# the latest version, then run it -- all in ONE launch. A running script
# cannot overwrite itself (that's why a plain self-updating launcher needs
# multiple runs to fully apply a launcher update). The starter is NOT the
# launcher, so it CAN replace Launch_EQ.ps1 before running it. Friends always
# start the game through this (Play_EQ.bat / the desktop shortcut), so the
# real launcher is always current within a single run -- no "run it 3 times."
#
# Because this starter never needs to change (its logic is final), it never
# hits the self-overwrite problem itself.
#
# A network failure must NEVER block the game: on any error we simply run
# whatever Launch_EQ.ps1 is already on disk.

$ProgressPreference = 'SilentlyContinue'

$Here       = $PSScriptRoot
$Launcher   = Join-Path $Here 'Launch_EQ.ps1'
$UpdaterLog = Join-Path $Here 'theo_and_co_updater.log'
$TmpPath    = Join-Path $Here 'Launch_EQ.ps1.download'   # NOT *.new (so the
                                                         # launcher's
                                                         # Resolve-PendingUpdates
                                                         # never touches it)
$RepoOwner  = 'nightwreath'
$RepoName   = 'theo-and-co-client-pack'

function Write-BootLog {
    param([string]$Message)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try { Add-Content -Path $UpdaterLog -Value "[$stamp] [starter] $Message" -ErrorAction SilentlyContinue } catch {}
}

function Get-JsonFromUrl {
    # BOM-safe JSON fetch (same defensive pattern as Launch_EQ.ps1: PS 5.1's
    # Invoke-RestMethod silently fails to parse a body that starts with a
    # UTF-8 BOM).
    param([string]$Uri, [hashtable]$Headers = @{})
    $resp  = Invoke-WebRequest -Uri $Uri -Headers $Headers -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
    $bytes = if ($resp.Content -is [byte[]]) { $resp.Content } else { [System.Text.Encoding]::UTF8.GetBytes($resp.Content) }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    return ([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
}

# Best-effort: clear a stale download from a prior interrupted run.
if (Test-Path -LiteralPath $TmpPath) { Remove-Item -LiteralPath $TmpPath -Force -ErrorAction SilentlyContinue }

try {
    Write-Host "[Starter] Checking launcher version..."
    $headers = @{ 'User-Agent' = 'theo-and-co-launcher'; 'Accept' = 'application/vnd.github+json' }
    $release = Get-JsonFromUrl -Uri "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest" -Headers $headers

    $mAsset = $release.assets | Where-Object { $_.name -eq 'manifest.json' }
    $lAsset = $release.assets | Where-Object { $_.name -eq 'Launch_EQ.ps1' }
    if ($mAsset -and $lAsset) {
        $manifest = Get-JsonFromUrl -Uri $mAsset.browser_download_url
        $want = (@($manifest.files) | Where-Object { $_.name -eq 'Launch_EQ.ps1' }).sha256
        if ($want) {
            $want = $want.ToLower()
            $have = ''
            if (Test-Path -LiteralPath $Launcher) {
                $have = (Get-FileHash -LiteralPath $Launcher -Algorithm SHA256).Hash.ToLower()
            }
            if ($have -ne $want) {
                Invoke-WebRequest -Uri $lAsset.browser_download_url -OutFile $TmpPath -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
                $got = (Get-FileHash -LiteralPath $TmpPath -Algorithm SHA256).Hash.ToLower()
                if ($got -eq $want) {
                    # Safe: the launcher is NOT running yet (we run it below),
                    # so it isn't locked and Move-Item succeeds.
                    Move-Item -LiteralPath $TmpPath -Destination $Launcher -Force -ErrorAction Stop
                    Write-Host "[Starter] Launcher updated to $($release.tag_name)." -ForegroundColor Green
                    Write-BootLog "Launcher -> $($release.tag_name) (sha $want)."
                } else {
                    Remove-Item -LiteralPath $TmpPath -Force -ErrorAction SilentlyContinue
                    Write-Host "[Starter] Launcher download was corrupt; keeping the installed one." -ForegroundColor Yellow
                    Write-BootLog "Launcher download hash mismatch (want $want got $got); kept existing."
                }
            } else {
                Write-BootLog "Launcher already current ($($release.tag_name))."
            }
        }
    }
} catch {
    Write-Host "[Starter] Launcher update check skipped ($($_.Exception.Message)). Using the installed launcher." -ForegroundColor Yellow
    Write-BootLog "Update check skipped: $($_.Exception.Message)"
}

if (-not (Test-Path -LiteralPath $Launcher)) {
    Write-Host "[Starter] ERROR: Launch_EQ.ps1 is missing and could not be downloaded." -ForegroundColor Red
    Write-Host "          Check your internet connection and try again." -ForegroundColor Red
    Write-BootLog "FATAL: no Launch_EQ.ps1 on disk and download failed."
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 3 }
    exit 1
}

# Hand off to the (now current) launcher in THIS same window. Set the
# self-promote sentinel so Launch_EQ.ps1 skips its hidden-window relaunch
# block -- that check was written for being the -File target and would
# misfire on the starter's command line. We are already a normal visible
# window (Play_EQ.bat / shortcut launch powershell with default window).
$env:THEO_LAUNCHER_PROMOTED = '1'
& $Launcher
