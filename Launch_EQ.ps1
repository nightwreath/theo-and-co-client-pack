# Launch EverQuest (RoF2) on Theo and Co server.
# This script lives in the "Theo and Co" subfolder; the EQ client files are
# in its parent directory.
#
# On every launch, this script checks GitHub for client-pack updates from
# nightwreath/theo-and-co-client-pack and applies any new versions before
# launching EQ. A failed update check NEVER blocks launch.
#
# Edit the $LockedSettings hashtable below to add or remove settings to keep
# stable across EQ sessions.

# Suppress Invoke-WebRequest's progress bar -- otherwise every download paints
# a colored ASCII progress bar across the terminal that flickers in and out
# in 50ms, which looks like a glitch even though the download is fine.
$ProgressPreference = 'SilentlyContinue'

# --- Self-promote to visible window ------------------------------------------
# Older Play_EQ.bat versions (pre-v1.0.1) and desktop shortcuts created by
# pre-v1.0.1 setup invoked PowerShell with -WindowStyle Hidden, which hid
# the update messages. Detect that case and relaunch ourselves visible.
#
# Detection: inspect our own process's command line via CIM/WMI for an
# explicit "-WindowStyle Hidden" argument. The previous approach (testing
# Process.MainWindowHandle for IntPtr.Zero) fired spuriously during the
# first ~100ms of a visible PowerShell process's lifetime, before the .NET
# Process object had a chance to populate the window handle -- causing an
# unnecessary self-promote (visible flicker) even when launched visibly.
#
# Two safety guards against an infinite self-promote loop:
#  1. THEO_LAUNCHER_PROMOTED env var is set before spawning the child; child
#     inherits it and skips this block.
#  2. $PSCommandPath is explicitly quoted so paths with spaces survive the
#     CreateProcess command-line concatenation.

if (-not $env:THEO_LAUNCHER_PROMOTED) {
    $myCmdLine = $null
    try {
        $myCmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop).CommandLine
    } catch {
        # CIM unavailable; fall back to the old MainWindowHandle proxy.
        $proc = Get-Process -Id $PID -ErrorAction SilentlyContinue
        if ($proc -and $proc.MainWindowHandle -eq [IntPtr]::Zero) {
            $myCmdLine = '-WindowStyle Hidden'  # treat as hidden
        }
    }

    if ($myCmdLine -and ($myCmdLine -match '(?i)-w(indowstyle)?\s+["'']?hidden["'']?')) {
        $env:THEO_LAUNCHER_PROMOTED = '1'
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-File', ('"{0}"' -f $PSCommandPath)
        ) -WindowStyle Normal
        exit
    }
}

# --- Configuration ------------------------------------------------------------

$RepoOwner   = 'nightwreath'
$RepoName    = 'theo-and-co-client-pack'
$EQRoot      = Split-Path $PSScriptRoot -Parent           # parent of "Theo and Co" subfolder
$IniPath     = Join-Path $EQRoot 'eqclient.ini'
$VersionFile = Join-Path $PSScriptRoot 'theo_and_co.version'
$UpdaterLog  = Join-Path $PSScriptRoot 'theo_and_co_updater.log'

# Settings re-stamped into eqclient.ini before every EQ launch. The key
# must already exist in eqclient.ini under whatever section. To turn off
# all locking, empty the hashtable: $LockedSettings = @{}
#
# What's locked (and why):
#   MaxFPS=60 + MaxMouseLookFPS=60  -- pairs that cap the frame-rate, the
#     fix for EQ's intrinsic 2:1 horizontal/vertical mouse-look disparity
#     at high FPS (Project 1999 community fix). Neither has an in-game UI;
#     they only exist via ini edits, and EQ can silently drop unfamiliar
#     keys on exit -- the lock is the belt-and-suspenders that survives
#     ini-rewrites, manual edits, future-version drift, etc.
#
# What's deliberately NOT locked:
#   MouseSensitivity -- EQ persists the slider's position between sessions
#     on its own; personal preference (8 discrete buckets, 0.5x-2.0x
#     multiplier range per the Session 11 Ghidra findings).
#   MouseTurnZoom -- has its own in-game UI toggle (Options -> Mouse),
#     personal preference, no reason to force a value on the friend.
$LockedSettings = @{
    'MaxFPS'          = '60'
    'MaxMouseLookFPS' = '60'
}

# --- Updater ------------------------------------------------------------------

function Write-UpdaterLog {
    param([string]$Message)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try { Add-Content -Path $UpdaterLog -Value "[$stamp] $Message" -ErrorAction SilentlyContinue } catch {}
}

function Get-LocalTag {
    if (Test-Path $VersionFile) {
        return (Get-Content $VersionFile -Raw -ErrorAction SilentlyContinue).Trim()
    }
    return ''
}

function Test-PathInsideRoot {
    param([string]$Path, [string]$Root)
    $pathAbs = [System.IO.Path]::GetFullPath($Path)
    $rootAbs = [System.IO.Path]::GetFullPath($Root)
    if (-not $rootAbs.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $rootAbs = $rootAbs + [System.IO.Path]::DirectorySeparatorChar
    }
    return $pathAbs.StartsWith($rootAbs, [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-PendingUpdates {
    # Apply any .new files left behind by a previous launch where Move-Item
    # couldn't replace the target file (most commonly because the launcher
    # was busy replacing itself). At this point the previous PowerShell
    # process has long since exited, so the file is no longer locked.
    $candidates = @()
    foreach ($dir in @($PSScriptRoot, $EQRoot)) {
        if (Test-Path $dir) {
            $candidates += Get-ChildItem -LiteralPath $dir -Filter '*.new' -ErrorAction SilentlyContinue
        }
    }

    foreach ($pending in $candidates) {
        $targetPath = $pending.FullName.Substring(0, $pending.FullName.Length - 4)  # strip ".new"
        try {
            Move-Item -LiteralPath $pending.FullName -Destination $targetPath -Force -ErrorAction Stop
            Write-Host "[Launcher] Applied pending update: $($pending.Name -replace '\.new$','')" -ForegroundColor Cyan
            Write-UpdaterLog "Applied pending update: $($pending.Name)"
        } catch {
            Write-Host "[Launcher]   Could not apply pending $($pending.Name): $($_.Exception.Message)" -ForegroundColor Yellow
            Write-UpdaterLog "Pending apply FAILED: $($pending.Name): $($_.Exception.Message)"
        }
    }
}

function Get-JsonFromUrl {
    param([string]$Uri, [hashtable]$Headers = @{})
    # Defensive JSON fetch: download as raw bytes, strip a UTF-8 BOM if present,
    # then ConvertFrom-Json explicitly. Works around Invoke-RestMethod's silent
    # parse failure when the body starts with EF BB BF (UTF-8 BOM). That bug
    # is what made every auto-update between v1.0.1 and v1.0.4 a no-op.
    $resp = Invoke-WebRequest -Uri $Uri -Headers $Headers -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
    $bytes = if ($resp.Content -is [byte[]]) { $resp.Content } else { [System.Text.Encoding]::UTF8.GetBytes($resp.Content) }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $text | ConvertFrom-Json
}

function Update-ClientPack {
    $localTag = Get-LocalTag

    try {
        $apiUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"
        Write-Host "[Launcher] Checking for client-pack updates..."
        $headers = @{ 'User-Agent' = 'theo-and-co-launcher'; 'Accept' = 'application/vnd.github+json' }
        $release = Get-JsonFromUrl -Uri $apiUrl -Headers $headers

        $remoteTag = $release.tag_name

        if ($remoteTag -eq $localTag) {
            Write-Host "[Launcher] Up to date at $localTag." -ForegroundColor Green
            Write-UpdaterLog "Check OK: up to date at $localTag."
            return
        }

        $displayLocal = if ($localTag) { $localTag } else { '(first run)' }
        Write-Host "[Launcher] Update available: $displayLocal -> $remoteTag. Applying..." -ForegroundColor Cyan

        $manifestAsset = $release.assets | Where-Object { $_.name -eq 'manifest.json' }
        if (-not $manifestAsset) {
            Write-UpdaterLog "Update FAILED: release $remoteTag has no manifest.json asset."
            Write-Host "[Launcher] Update skipped (no manifest in release). Continuing with current files." -ForegroundColor Yellow
            return
        }

        $manifest = Get-JsonFromUrl -Uri $manifestAsset.browser_download_url

        # Sanity check: if the manifest doesn't look like a manifest (no .files
        # array, or empty), refuse to advance the version stamp. This is the
        # check that would have caught v1.0.1-v1.0.4's BOM bug: those updates
        # reported "Update OK" with 0 files iterated, lying about success.
        $fileList = @($manifest.files)
        if (-not $manifest.tag -or $fileList.Count -eq 0) {
            Write-UpdaterLog "Update FAILED: manifest is malformed or empty (tag='$($manifest.tag)', files=$($fileList.Count))."
            Write-Host "[Launcher] Update skipped (manifest is malformed). Continuing with current files." -ForegroundColor Yellow
            return
        }

        $allOk        = $true
        $downloaded   = 0
        $alreadyValid = 0
        foreach ($entry in $manifest.files) {
            $installPath = Join-Path $EQRoot $entry.install_path

            # Safety: refuse to write outside the EQ root.
            if (-not (Test-PathInsideRoot -Path $installPath -Root $EQRoot)) {
                Write-UpdaterLog "Update REJECTED: $($entry.name) install_path escapes EQ root: $($entry.install_path)"
                Write-Host "[Launcher] Update aborted (unsafe install_path on $($entry.name))." -ForegroundColor Red
                $allOk = $false
                continue
            }

            $expectedHash = $entry.sha256.ToLower()
            $currentHash  = ''
            if (Test-Path $installPath) {
                $currentHash = (Get-FileHash -Path $installPath -Algorithm SHA256).Hash.ToLower()
            }

            if ($currentHash -eq $expectedHash) {
                $alreadyValid++
                continue   # File already correct
            }

            $asset = $release.assets | Where-Object { $_.name -eq $entry.name }
            if (-not $asset) {
                Write-UpdaterLog "Update FAILED: release $remoteTag missing asset $($entry.name)."
                Write-Host "[Launcher]   Skipped $($entry.name) (missing in release)." -ForegroundColor Yellow
                $allOk = $false
                continue
            }

            Write-Host "[Launcher]   Downloading $($entry.name)..."
            $tmpPath = "$installPath.new"
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpPath -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop

            $newHash = (Get-FileHash -Path $tmpPath -Algorithm SHA256).Hash.ToLower()
            if ($newHash -ne $expectedHash) {
                Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
                Write-UpdaterLog "Update FAILED: $($entry.name) hash mismatch (expected $expectedHash, got $newHash)."
                Write-Host "[Launcher]   Aborted $($entry.name) (hash mismatch)." -ForegroundColor Red
                $allOk = $false
                continue
            }

            $parent = Split-Path -Parent $installPath
            if (-not (Test-Path $parent)) {
                New-Item -Path $parent -ItemType Directory -Force | Out-Null
            }

            try {
                Move-Item -LiteralPath $tmpPath -Destination $installPath -Force -ErrorAction Stop
                Write-UpdaterLog "Updated $($entry.name) -> $remoteTag"
                $downloaded++
            } catch {
                Write-Host "[Launcher]   Replace failed on $($entry.name); $($_.Exception.Message). Will retry next launch." -ForegroundColor Yellow
                Write-UpdaterLog "Update DEFERRED: $($entry.name) replace failed: $($_.Exception.Message). .new file kept for next-launch apply."
                $allOk = $false
                # Keep $tmpPath ($installPath.new) in place; Resolve-PendingUpdates will catch it next launch.
            }
        }

        # Deletions: files the bundle wants REMOVED from the friend's client
        # (e.g. the modern highpasshold.eqg/.zon, which RoF2 loads in
        # preference to the classic .s3d we ship -- the swap is inert until
        # they're gone). Idempotent: absent = already handled on a prior
        # launch. Older launchers ignore $manifest.deletions entirely, so the
        # manifest stays backward compatible.
        $deletions = @($manifest.deletions)
        $deleted   = 0
        foreach ($delRel in $deletions) {
            if ([string]::IsNullOrWhiteSpace($delRel)) { continue }
            $delPath = Join-Path $EQRoot $delRel

            # Same guard as installs: never touch anything outside EQ root.
            if (-not (Test-PathInsideRoot -Path $delPath -Root $EQRoot)) {
                Write-UpdaterLog "Deletion REJECTED: '$delRel' escapes EQ root."
                Write-Host "[Launcher] Update aborted (unsafe deletion path: $delRel)." -ForegroundColor Red
                $allOk = $false
                continue
            }
            # Never delete something this same bundle also installs.
            if (@($manifest.files | Where-Object { $_.install_path -eq $delRel }).Count -gt 0) {
                Write-UpdaterLog "Deletion SKIPPED: '$delRel' is also a managed file in this bundle."
                continue
            }

            if (Test-Path -LiteralPath $delPath) {
                try {
                    Remove-Item -LiteralPath $delPath -Force -ErrorAction Stop
                    Write-Host "[Launcher]   Removed $delRel" -ForegroundColor Cyan
                    Write-UpdaterLog "Deleted $delRel -> $remoteTag"
                    $deleted++
                } catch {
                    Write-Host "[Launcher]   Could not remove $delRel; $($_.Exception.Message). Will retry next launch." -ForegroundColor Yellow
                    Write-UpdaterLog "Deletion FAILED: $delRel : $($_.Exception.Message)"
                    $allOk = $false
                }
            }
            # absent -> already removed on a prior launch; nothing to do.
        }

        # Defense-in-depth: re-verify every managed file's hash against the
        # manifest. Catches a Move-Item that "succeeded" but didn't actually
        # replace the file (e.g., AV reverted, or a silent share-mode issue).
        # If any file is wrong, treat the update as a failure -- the version
        # stamp stays at the previous value and the launcher retries next run.
        $verifyFailed = @()
        foreach ($entry in $manifest.files) {
            $installPath = Join-Path $EQRoot $entry.install_path
            if (Test-Path $installPath) {
                $h = (Get-FileHash -LiteralPath $installPath -Algorithm SHA256).Hash.ToLower()
                if ($h -ne $entry.sha256.ToLower()) {
                    $verifyFailed += $entry.name
                }
            } else {
                $verifyFailed += "$($entry.name) (missing)"
            }
        }
        # ...and re-verify every deletion is actually gone (a failed/locked
        # Remove-Item would otherwise let the version stamp advance with the
        # modern .eqg still shadowing the classic .s3d).
        foreach ($delRel in $deletions) {
            if ([string]::IsNullOrWhiteSpace($delRel)) { continue }
            if (@($manifest.files | Where-Object { $_.install_path -eq $delRel }).Count -gt 0) { continue }
            $delPath = Join-Path $EQRoot $delRel
            if ((Test-PathInsideRoot -Path $delPath -Root $EQRoot) -and (Test-Path -LiteralPath $delPath)) {
                $verifyFailed += "$delRel (still present)"
            }
        }
        if ($verifyFailed.Count -gt 0) {
            Write-Host "[Launcher] Integrity check FAILED for: $($verifyFailed -join ', '). Will retry next launch." -ForegroundColor Red
            Write-UpdaterLog "Integrity FAILED: $($verifyFailed -join ', '). Version stamp held at $displayLocal."
            $allOk = $false
        }

        if ($allOk) {
            Set-Content -Path $VersionFile -Value $remoteTag -NoNewline
            if ($downloaded -gt 0 -or $deleted -gt 0) {
                $delMsg = if ($deleted -gt 0) { ", $deleted removed" } else { '' }
                Write-Host "[Launcher] Updated $displayLocal -> $remoteTag ($downloaded file$(if($downloaded -ne 1){'s'}) downloaded$delMsg)." -ForegroundColor Green
            } else {
                Write-Host "[Launcher] Version stamp advanced to $remoteTag (all files already at correct hash)." -ForegroundColor Green
            }
            Write-UpdaterLog "Update OK: $displayLocal -> $remoteTag ($downloaded downloaded, $deleted removed, $alreadyValid already valid)."
        }
        else {
            Write-Host "[Launcher] Update completed with errors; version stamp NOT advanced. See $UpdaterLog for details." -ForegroundColor Yellow
            Write-UpdaterLog "Update PARTIAL: $displayLocal -> $remoteTag failed; version stamp held at $displayLocal."
        }
    }
    catch {
        Write-UpdaterLog "Update check failed: $($_.Exception.Message)"
        Write-Host "[Launcher] Update check failed ($($_.Exception.Message))." -ForegroundColor Yellow
        Write-Host "[Launcher] Continuing with current files (local tag: $(if($localTag){$localTag}else{'(first run)'}))."
    }
}

function Wait-ForKeyPress {
    Write-Host ""
    Write-Host "Press any key to launch the game..."
    try {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        # Fallback for non-interactive hosts: just continue
        Start-Sleep -Seconds 1
    }
}

# --- Run ----------------------------------------------------------------------

Resolve-PendingUpdates
Update-ClientPack
Wait-ForKeyPress

# Apply $LockedSettings to eqclient.ini BEFORE launching EQ. The pre-v1.0.6
# launcher applied these after EQ exited, which required the launcher to
# stay alive (and its console window visible) for the entire EQ session.
# Applying at launch time achieves the same end state -- locked keys stay
# locked across sessions -- while letting PowerShell exit immediately after
# launching the game. Closes the visible terminal window the moment EQ
# takes over, matching every other normal Windows game launcher.
if (Test-Path $IniPath) {
    # When a locked key already exists in eqclient.ini, replace its value.
    # When it doesn't exist (e.g., a friend's pre-v1.0.8 ini that predates
    # the MaxMouseLookFPS addition), insert it after a related anchor key
    # so it lands in the same INI section -- EQ's loadOptions reads keys
    # via section-scoped lookups, so just appending at EOF isn't reliable.
    $anchorMap = @{
        'MaxMouseLookFPS' = 'MaxFPS'   # both live in [Defaults] in EQ's ini
    }
    $content = Get-Content -Raw $IniPath
    foreach ($key in $LockedSettings.Keys) {
        $value   = $LockedSettings[$key]
        $pattern = "(?m)^$([regex]::Escape($key))=.*$"
        if ($content -match $pattern) {
            $content = [regex]::Replace($content, $pattern, "$key=$value")
            continue
        }
        # Missing -- try to insert after the mapped anchor key
        $inserted = $false
        $anchor = $anchorMap[$key]
        if ($anchor) {
            $anchorPattern = "(?m)(^$([regex]::Escape($anchor))=.*)$"
            if ($content -match $anchorPattern) {
                $content = [regex]::Replace($content, $anchorPattern, "`$1`r`n$key=$value", 1)
                $inserted = $true
            }
        }
        # No anchor or anchor not in file -- last resort, append at EOF
        if (-not $inserted) {
            if (-not $content.EndsWith("`n")) { $content += "`r`n" }
            $content += "$key=$value`r`n"
        }
    }
    Set-Content -Path $IniPath -Value $content -NoNewline
}

Write-Host "[Launcher] Launching EverQuest..."
Start-Process -FilePath (Join-Path $EQRoot 'eqgame.exe') `
              -ArgumentList 'patchme' `
              -WorkingDirectory $EQRoot

# PowerShell exits now. The visible terminal window closes. EQ continues
# running independently. On next launch, $LockedSettings will be applied
# again -- catching any drift from the previous session.
