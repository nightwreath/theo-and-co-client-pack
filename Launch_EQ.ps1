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
$PrefsFile   = Join-Path $PSScriptRoot 'theo_and_co_prefs.json'   # local, NOT managed by the updater
$ServerToken = 'TheoAndCo'   # the <Char>_<ServerToken>.ini suffix used by this server's client

# Model-style swap: stash dir for assets temporarily disabled by Classic mode.
# Lives inside $EQRoot so Test-PathInsideRoot is happy; never auto-deleted by
# the updater (not on its managed-files list).
$ClassicStashDir = Join-Path $EQRoot '_theo_classic_assets_disabled'

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
#   MouseRightHanded=1  -- defends against a one-way trap (S42 cascade).
#     The stock "Right-handed mouse" checkbox in Options -> Mouse swaps
#     LMB/RMB inside EQ when toggled off, after which the user can no
#     longer click the checkbox to toggle it back on (clicks land on the
#     wrong button). The state persists to eqclient.ini -> survives
#     client restart AND Windows reboot. EQUI_OptionsWindow.xml in
#     v1.4.17 also removes the checkbox from the panel; this lock is the
#     defense-in-depth so even an out-of-band ini edit can't strand the
#     player. See memory/project_zeal_rof2_lmb_pan_audit.md for the
#     incident chronology and the full D1/D2/D3 defense layers.
#
# What's deliberately NOT locked:
#   MouseSensitivity -- EQ persists the slider's position between sessions
#     on its own; personal preference (8 discrete buckets, 0.5x-2.0x
#     multiplier range per the Session 11 Ghidra findings).
#   MouseTurnZoom -- has its own in-game UI toggle (Options -> Mouse),
#     personal preference, no reason to force a value on the friend.
$LockedSettings = @{
    'MaxFPS'           = '60'
    'MaxMouseLookFPS'  = '60'
    'MouseRightHanded' = '1'
}

# --- Model style prefs --------------------------------------------------------
# Per-friend pick of CLASSIC vs LUCLIN, independently for character models
# and weapon models. Local-only state (not in $ManagedFiles, not updated by
# the patcher); a separate Toggle_Character_Models.ps1 / Toggle_Weapon_Models.ps1
# pair flips the values, and this launcher applies them every launch.
#
# Characters: pure eqclient.ini -- AllLuclinPcModelsOff (master switch;
#   Vah Shir always loads regardless) + LoadLuclinCharacters (older naming;
#   set in lockstep for belt+suspenders).
# Weapons: file presence -- $EQRoot\equipment-01.eqg moved in/out of
#   $ClassicStashDir. The underlying classic weapon models are already in
#   any RoF2 install via gequip*.s3d; removing equipment-01.eqg lets the
#   client fall back to them. One known quirk: weapon model 10409 has no
#   classic equivalent (EQEmu forum, 2018) -- will render as a placeholder
#   in CLASSIC mode.

function Read-ModelStylePrefs {
    # Returns @{ character_style='luclin'|'classic'; weapon_style=... },
    # writing the prefs file with detected defaults if it's missing.
    $result = [ordered]@{ character_style = $null; weapon_style = $null }
    if (Test-Path -LiteralPath $PrefsFile) {
        try {
            $obj = Get-Content -Raw -LiteralPath $PrefsFile -ErrorAction Stop | ConvertFrom-Json
            if ($obj.character_style -in @('luclin','classic')) { $result.character_style = $obj.character_style }
            if ($obj.weapon_style    -in @('luclin','classic')) { $result.weapon_style    = $obj.weapon_style    }
        } catch {
            Write-UpdaterLog "Model style prefs parse failed: $($_.Exception.Message). Re-detecting."
        }
    }
    $detected = $false
    if (-not $result.character_style) {
        $allOff = $null
        if (Test-Path -LiteralPath $IniPath) {
            $iniContent = Get-Content -Raw -LiteralPath $IniPath -ErrorAction SilentlyContinue
            if ($iniContent -and ($iniContent -match '(?m)^AllLuclinPcModelsOff=(\d+)')) { $allOff = $Matches[1] }
        }
        $result.character_style = if ($allOff -eq '1') { 'classic' } else { 'luclin' }
        $detected = $true
    }
    if (-not $result.weapon_style) {
        $equipFile = Join-Path $EQRoot 'equipment-01.eqg'
        $result.weapon_style = if (Test-Path -LiteralPath $equipFile) { 'luclin' } else { 'classic' }
        $detected = $true
    }
    if ($detected) {
        try { Save-ModelStylePrefs -Prefs $result } catch {
            Write-UpdaterLog "Model style prefs write FAILED on first-run: $($_.Exception.Message)"
        }
        Write-UpdaterLog "Model style prefs detected: characters=$($result.character_style), weapons=$($result.weapon_style)"
    }
    return $result
}

function Save-ModelStylePrefs {
    param($Prefs)
    $obj  = [ordered]@{
        character_style = $Prefs.character_style
        weapon_style    = $Prefs.weapon_style
    }
    $json = $obj | ConvertTo-Json -Depth 3
    # UTF-8 WITHOUT BOM. Same pattern as build-release.ps1's manifest write
    # -- PowerShell 5.1's Set-Content -Encoding UTF8 writes a BOM that JSON
    # consumers can silently mishandle.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($PrefsFile, $json, $utf8NoBom)
}

function Show-ModelStyleMenu {
    # Interactive menu shown after the update check, before launch. Lets the
    # friend flip CHARACTER or WEAPON models inline -- one key per axis,
    # re-shows current state after each flip, exits + launches on any other
    # key. Replaces the older "Press any key to launch" prompt: this prompt
    # IS the keypress gate; pressing Enter (or any non-C/W key) launches.
    # Prefs are saved on each toggle so a launcher crash between menu and
    # game-start still persists the choice.
    param([Parameter(Mandatory)][ref]$PrefsRef)

    while ($true) {
        $char = $PrefsRef.Value.character_style.ToUpper()
        $weap = $PrefsRef.Value.weapon_style.ToUpper()

        Write-Host ""
        Write-Host "[Launcher] Current models:" -ForegroundColor Green
        Write-Host ("           Characters: " + $char.PadRight(8) + " Weapons: " + $weap) -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  [C] Toggle character models"
        Write-Host "  [W] Toggle weapon models"
        Write-Host "  [Enter or any other key] Launch EverQuest"
        Write-Host ""

        try {
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        } catch {
            # Non-interactive host (redirected stdin, etc.) -- just launch.
            Start-Sleep -Seconds 1
            return
        }

        $c = if ($key.Character) { $key.Character.ToString().ToLower() } else { '' }
        if ($c -eq 'c') {
            $old = $PrefsRef.Value.character_style
            $new = if ($old -eq 'luclin') { 'classic' } else { 'luclin' }
            $PrefsRef.Value.character_style = $new
            try {
                Save-ModelStylePrefs -Prefs $PrefsRef.Value
                Write-UpdaterLog "Menu toggle: characters $old -> $new"
            } catch {
                Write-Host "[Launcher] Could not save prefs: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-UpdaterLog "Menu toggle save FAILED (characters $old -> $new): $($_.Exception.Message)"
            }
            Write-Host ("[Launcher] Character models: " + $old.ToUpper() + " -> " + $new.ToUpper()) -ForegroundColor Cyan
            continue
        }
        if ($c -eq 'w') {
            $old = $PrefsRef.Value.weapon_style
            $new = if ($old -eq 'luclin') { 'classic' } else { 'luclin' }
            $PrefsRef.Value.weapon_style = $new
            try {
                Save-ModelStylePrefs -Prefs $PrefsRef.Value
                Write-UpdaterLog "Menu toggle: weapons $old -> $new"
            } catch {
                Write-Host "[Launcher] Could not save prefs: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-UpdaterLog "Menu toggle save FAILED (weapons $old -> $new): $($_.Exception.Message)"
            }
            Write-Host ("[Launcher] Weapon models: " + $old.ToUpper() + " -> " + $new.ToUpper()) -ForegroundColor Cyan
            continue
        }
        return
    }
}

function Apply-WeaponStyleFileMove {
    # Idempotent: every launch ensures equipment-01.eqg is in the right
    # place for the current weapon_style pref. Mid-game guarded (EQ memory-
    # maps eqg files; locked while running). Called BEFORE Start-Process
    # eqgame.exe so by the time EQ opens its handles, the file is settled.
    param([string]$Style)
    $rootFile  = Join-Path $EQRoot   'equipment-01.eqg'
    $stashFile = Join-Path $ClassicStashDir 'equipment-01.eqg'

    if ($Style -eq 'classic') {
        if (Test-Path -LiteralPath $rootFile) {
            try {
                if (-not (Test-Path -LiteralPath $ClassicStashDir)) {
                    New-Item -ItemType Directory -Path $ClassicStashDir -Force -ErrorAction Stop | Out-Null
                }
                Move-Item -LiteralPath $rootFile -Destination $stashFile -Force -ErrorAction Stop
                Write-Host "[Launcher]   Stashed equipment-01.eqg (weapons: CLASSIC)" -ForegroundColor Cyan
                Write-UpdaterLog "Weapon style classic: stashed equipment-01.eqg."
            } catch {
                Write-Host "[Launcher]   Could not stash equipment-01.eqg: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-UpdaterLog "Weapon style apply FAILED (classic): $($_.Exception.Message)"
            }
        }
        # If neither root nor stash has it, log once and continue. Friend can
        # still play; weapons just render however the engine falls back to.
        elseif (-not (Test-Path -LiteralPath $stashFile)) {
            Write-UpdaterLog "Weapon style classic: equipment-01.eqg not found in root or stash; no file action."
        }
    } else {
        # 'luclin' (or any other value treated as luclin -- default)
        if (Test-Path -LiteralPath $stashFile) {
            try {
                Move-Item -LiteralPath $stashFile -Destination $rootFile -Force -ErrorAction Stop
                Write-Host "[Launcher]   Restored equipment-01.eqg (weapons: LUCLIN)" -ForegroundColor Cyan
                Write-UpdaterLog "Weapon style luclin: restored equipment-01.eqg from stash."
            } catch {
                Write-Host "[Launcher]   Could not restore equipment-01.eqg: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-UpdaterLog "Weapon style apply FAILED (luclin): $($_.Exception.Message)"
            }
        }
    }
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

function Invoke-ManifestDeletions {
    # Reconcile the manifest's deletion list against disk. Idempotent: a file
    # already gone is a no-op. Called on EVERY launch (including "up to date")
    # -- deliberately NOT gated behind a version-tag change. Reason: the
    # launcher updates itself via the .new / Resolve-PendingUpdates bootstrap,
    # so by the time delete-capable launcher code first *executes*, an older
    # in-memory launcher has usually already advanced the version stamp to the
    # remote tag. Gating deletions on a tag mismatch would mean they never run
    # for anyone upgrading across that boundary (every existing friend). Same
    # philosophy as $LockedSettings: enforce the invariant every launch.
    param($Manifest, [string]$Tag)
    $removed = 0
    $ok      = $true
    foreach ($delRel in @($Manifest.deletions)) {
        if ([string]::IsNullOrWhiteSpace($delRel)) { continue }
        $delPath = Join-Path $EQRoot $delRel
        # Same guard as installs: never touch anything outside EQ root.
        if (-not (Test-PathInsideRoot -Path $delPath -Root $EQRoot)) {
            Write-UpdaterLog "Deletion REJECTED: '$delRel' escapes EQ root."
            Write-Host "[Launcher] Skipped unsafe deletion path: $delRel." -ForegroundColor Red
            $ok = $false
            continue
        }
        # Never delete something this same bundle also installs.
        if (@($Manifest.files | Where-Object { $_.install_path -eq $delRel }).Count -gt 0) {
            Write-UpdaterLog "Deletion SKIPPED: '$delRel' is also a managed file in this bundle."
            continue
        }
        if (Test-Path -LiteralPath $delPath) {
            try {
                Remove-Item -LiteralPath $delPath -Force -ErrorAction Stop
                Write-Host "[Launcher]   Removed $delRel" -ForegroundColor Cyan
                Write-UpdaterLog "Deleted $delRel ($Tag)"
                $removed++
            } catch {
                Write-Host "[Launcher]   Could not remove $delRel; $($_.Exception.Message). Will retry next launch." -ForegroundColor Yellow
                Write-UpdaterLog "Deletion FAILED: $delRel : $($_.Exception.Message)"
                $ok = $false
            }
        }
        # absent -> already removed on a prior launch; nothing to do.
    }
    return [pscustomobject]@{ Removed = $removed; Ok = $ok }
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
            # Even when up to date, reconcile deletions every launch
            # (idempotent). This is the path that actually delivers a
            # delete-manifest to friends: the delete-capable launcher only
            # starts executing AFTER the version stamp already moved (the
            # self-update bootstrap lag, see Invoke-ManifestDeletions), so
            # the normal mismatch flow never runs its deletions for them.
            try {
                $mAsset = $release.assets | Where-Object { $_.name -eq 'manifest.json' }
                if ($mAsset) {
                    $m = Get-JsonFromUrl -Uri $mAsset.browser_download_url
                    if ($m.tag -and @($m.files).Count -gt 0) {
                        $null = Invoke-ManifestDeletions -Manifest $m -Tag $localTag
                    }
                }
            } catch {
                Write-UpdaterLog "Up-to-date deletion reconcile skipped: $($_.Exception.Message)"
            }
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

        # Reconcile deletions (shared with the up-to-date path via the
        # function). $manifest.deletions is ignored by pre-delete launchers,
        # so the manifest stays backward compatible.
        $deletions = @($manifest.deletions)
        $delResult = Invoke-ManifestDeletions -Manifest $manifest -Tag $remoteTag
        $deleted   = $delResult.Removed
        if (-not $delResult.Ok) { $allOk = $false }

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

# --- Bot Socials -------------------------------------------------------------
# Pre-installed bot command buttons (Phase 3 Tier 1). Socials are client-side
# and per-character (<Char>_<ServerToken>.ini, [Socials] section). Bot names
# are GLOBALLY unique server-wide, so each character's create buttons must use
# a name unique to that character -- the launcher templates the character's
# own name (from the ini filename) into every "{P}" placeholder below.
#
# Idempotent and re-asserted every launch (same philosophy as $LockedSettings):
# only the keys for OUR managed buttons (pages 2-5) are written; the friend's
# other socials/pages are never touched. A brand-new character has no ini until
# it first logs in/camps, so it gets these on its *next* launch.
#
# Pages: 2 = control/combat, 3 = group/manage, 4-5 = per-class create.

$BotClasses = @(
    @{ Tag = 'war'; Cls = 1  }   # Warrior
    @{ Tag = 'clr'; Cls = 2  }   # Cleric
    @{ Tag = 'pal'; Cls = 3  }   # Paladin
    @{ Tag = 'rng'; Cls = 4  }   # Ranger
    @{ Tag = 'shd'; Cls = 5  }   # Shadow Knight
    @{ Tag = 'dru'; Cls = 6  }   # Druid
    @{ Tag = 'mnk'; Cls = 7  }   # Monk
    @{ Tag = 'brd'; Cls = 8  }   # Bard
    @{ Tag = 'rog'; Cls = 9  }   # Rogue
    @{ Tag = 'shm'; Cls = 10 }   # Shaman
    @{ Tag = 'nec'; Cls = 11 }   # Necromancer
    @{ Tag = 'wiz'; Cls = 12 }   # Wizard
    @{ Tag = 'mag'; Cls = 13 }   # Magician
    @{ Tag = 'enc'; Cls = 14 }   # Enchanter
    @{ Tag = 'bst'; Cls = 15 }   # Beastlord
)

# Authoritative race -> allowed-classes bitmask, copied verbatim from the
# live PEQ DB table `bot_create_combinations` (Session 27). Bit (Cls-1)
# set => that race may be that class. This is the same data the engine's
# Bot::IsValidRaceClassCombo checks, so a race picked from here can never
# produce an "invalid race-class" error. Race IDs are the numeric values
# ^botcreate expects (1 Human .. 128 Iksar, 130 Vah Shir, 330 Froglok,
# 522 Drakkin). If the DB table ever changes, re-pull and update here.
$RaceClasses = @(
    @{ Race = 1;   Classes = 15871 }
    @{ Race = 2;   Classes = 49921 }
    @{ Race = 3;   Classes = 15382 }
    @{ Race = 4;   Classes = 425   }
    @{ Race = 5;   Classes = 14342 }
    @{ Race = 6;   Classes = 15635 }
    @{ Race = 7;   Classes = 429   }
    @{ Race = 8;   Classes = 33031 }
    @{ Race = 9;   Classes = 49681 }
    @{ Race = 10;  Classes = 49681 }
    @{ Race = 11;  Classes = 303   }
    @{ Race = 12;  Classes = 15639 }
    @{ Race = 128; Classes = 18001 }
    @{ Race = 130; Classes = 50049 }
    @{ Race = 330; Classes = 3863  }
    # Race 522 (Drakkin) intentionally REMOVED: Serpent's Spine 2006,
    # post-PoP. Server-side sql/107 also blocks Drakkin in
    # bot_create_combinations so any ^botcreate with race=522 is
    # engine-rejected. This list stays in sync with that block --
    # picker can never hand out a Drakkin and trip the rejection.
)

# Per-(character, class) race overrides. Keys are "$Prefix|$Tag" exactly
# as Get-StableHash sees them. Values are race IDs from $RaceClasses
# above. Used by Get-CreateButtons to bypass the hash picker for
# specific characters who've asked for a specific race for a specific
# class. Race must still be valid for that class (no validation here --
# pick from the list yourself).
$RaceOverrides = @{
    'Theolin|brd' = 7   # Half-Elf Bard (Alex S40 request)
}

# Stable 32-bit hash (deterministic across launches & machines). MD5 is
# used only as a fixed, well-distributed digest (NOT for security) -- it
# sidesteps PowerShell 5.1's uint*int -> double overflow trap that an
# arithmetic FNV hash hits. Picks a race/gender per (character, class) so
# each character gets a varied-but-fixed, always-valid roster (idempotent).
function Get-StableHash {
    param([string]$Text)
    $md5   = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    } finally {
        $md5.Dispose()
    }
    return [System.BitConverter]::ToUInt32($bytes, 0)
}

# Races valid for a class, in stable $RaceClasses order.
function Get-ValidRaces {
    param([int]$ClassId)
    $bit = [int](1 -shl ($ClassId - 1))
    $out = @()
    foreach ($rc in $RaceClasses) {
        if (($rc.Classes -band $bit) -ne 0) { $out += $rc.Race }
    }
    return $out
}

# Each button: @{ P=page; B=button; Name='...'; Lines=@('line1', 'line2'...) }.
# {P} in any line is replaced with the per-character bot-name prefix.
function Get-BotSocialButtons {
    $btns = @()

    # ---- Page 2 -- Combat (S39): Pull dropped; Bal/Agg moved to Page 5
    # (dedicated Stances page); Camp All moved to Page 3 (camp buttons live
    # together with Camp Bot, not duplicated on Page 2); Attack now 2-line
    # (clear hold + attack) so a held bot resumes on click. Engine fix #7
    # (theo-and-co-engine S39 PR #18) silences "no longer holding" chat
    # when no bots were actually held, so the bundled clear never spams.
    $ctrl = @(
        @{ Name = 'Attack';        Lines = @('^hold clear spawned', '^attack spawned') }
        @{ Name = 'Hold';          Cmd   = '^hold spawned'        }
        @{ Name = 'Hold Off';      Cmd   = '^hold clear spawned'  }
        @{ Name = 'Guard';         Cmd   = '^guard spawned'       }
        @{ Name = 'Guard Off';     Lines = @('^guard clear spawned', '^follow reset spawned') }
        @{ Name = 'Follow Me';     Cmd   = '^follow reset spawned' }
        @{ Name = 'Taunt On';      Cmd   = '^taunt on spawned'    }
        @{ Name = 'Taunt Off';     Cmd   = '^taunt off spawned'   }
        @{ Name = 'Casters In';    Cmd   = '^botstopmeleelevel 100 spawned'   }   # S55: force casters into melee/belly range (stop-melee-level 100 > any bot level => melee branch, bot.cpp:2369/3247) so they CAN cast on CastingFromRangeImmunity mobs (Sol B fire giants, Naggy). Pairs with Casters Back; reset via Default Roles.
        @{ Name = 'Casters Back';  Cmd   = '^botstopmeleelevel 1 spawned'     }   # S53: caster bots never melee (stop-melee-level = 1; effective at any level)
        @{ Name = 'Default Roles'; Cmd   = '^botstopmeleelevel reset spawned' }   # S53: restore server default L13 (Bots:CasterStopMeleeLevel rule). Sub-L13 casters melee, L13+ stand back and cast.
    )
    for ($i = 0; $i -lt $ctrl.Count; $i++) {
        # Explicit assignment (NOT `$cl = if(){}else{}`): an `if`-expression
        # unwraps a single-element @(...) into a scalar string, which the
        # writer then char-indexes -> every single-Cmd button became "^".
        if ($ctrl[$i].Lines) { $cl = @($ctrl[$i].Lines) } else { $cl = @($ctrl[$i].Cmd) }
        $btns += @{ P = 2; B = ($i + 1); Name = $ctrl[$i].Name; Lines = $cl }
    }

    # ---- Page 3 -- Per-bot management + Camp (S39): Delete Bot dropped
    # (moved to Page 7 next to the per-class Create buttons so the bot-
    # lifecycle controls live together). Camp All + Camp Bot now adjacent.
    $grp = @(
        @{ Name = 'Invite Bot';    Cmd = '/invite'                  }
        @{ Name = 'Disband Bot';   Cmd = '/disband'                 }
        @{ Name = 'Bot Report';    Cmd = '^botreport spawned'       }
        @{ Name = 'Camp All';      Cmd = '^botcamp spawned'         }
        @{ Name = 'Camp Bot';      Cmd = '^botcamp target'          }   # logout the single targeted bot
        @{ Name = 'Bot Gear';      Cmd = '^inventorywindow target'  }   # pop-up: targeted bot's equipped gear per slot
        @{ Name = 'Bot Stats';     Cmd = '^statswindow target'      }   # pop-up: targeted bot's Group A stat-model readout
        @{ Name = 'Bot Gear List'; Cmd = '^inventorylist target'    }   # chat: clickable item links (alt+click -> full item details)
    )
    for ($i = 0; $i -lt $grp.Count; $i++) {
        $btns += @{ P = 3; B = ($i + 1); Name = $grp[$i].Name; Lines = @($grp[$i].Cmd) }
    }

    # ---- Page 4 -- Group ops + Spell management + Speed (S39): consolidates
    # the old Page 6 group/formation controls with new spell-management and
    # movement-speed buttons (engine fixes #4/#5/#6 on PR #18). Spell List
    # rows now carry [Disable]/[Info] saylinks per spell; Disabled Spells
    # carries [Enable]. Speed buttons drive the new ^cast movementspeed
    # group / each sub-target modes.
    $ops = @(
        @{ Name = 'Bot List';        Cmd = '^botlist'                     }
        @{ Name = 'Group Up';        Cmd = '^groupup'                     }
        @{ Name = 'Summon';          Cmd = '^botsummon target'            }   # targeted bot only
        @{ Name = 'Summon All';      Cmd = '^botsummon all'               }   # S53: summons every spawned bot to player. `all` and `spawned` are aliases on ^botsummon (bot_command.h:735-737 shared switch branch + ABM_Spawned_All combined mask).
        @{ Name = 'Compact';         Cmd = '^formation compact spawned'   }
        @{ Name = 'Normal';          Cmd = '^formation normal spawned'    }   # formation; distinct from "Balanced" stance on Page 5
        @{ Name = 'Spread';          Cmd = '^formation spread spawned'    }
        @{ Name = 'Spell List';      Cmd = '^spells target'               }   # outputs rows w/ [Info]/[Disable] saylinks per spell
        @{ Name = 'Disabled Spells'; Cmd = '^spellsettings target'        }   # outputs rows w/ [Enable] saylinks per disabled spell
        @{ Name = 'Group Speed';     Cmd = '^cast movementspeed group spawned' }  # Pack Shrew (DRU/SHM/BST/RNG L34+) / Pack Spirit (DRU 35+) / Selo's (BRD 5+)
        @{ Name = 'Single Speed';    Cmd = '^cast movementspeed each spawned'  }  # iterates group members; multi-click for full coverage
    )
    for ($i = 0; $i -lt $ops.Count; $i++) {
        $btns += @{ P = 4; B = ($i + 1); Name = $ops[$i].Name; Lines = @($ops[$i].Cmd) }
    }

    # ---- Page 5 -- Stances (S39) + nuke resist toggles (S55): the 6 valid stances in defensive->
    # offensive order. Engine fix #1 (PR #18) widened IsTaunting() so
    # WAR/PAL/SK auto-taunt in every non-Passive stance -- no need for an
    # "Aggressive Tank" carve-out; the stance picker also picks the right
    # tank behavior. "Normal" here would clash with the Page 4 formation
    # button -- we use "Balanced" specifically to keep them distinct.
    $stances = @(
        @{ Name = 'Balanced';   Cmd = '^botstance 2 spawned' }
        @{ Name = 'Aggressive'; Cmd = '^botstance 5 spawned' }
        @{ Name = 'Vanguard';   Cmd = '^botstance 10 spawned' }  # S55 (engine PR #34): Aggressive offense, but healers keep healing on Balanced thresholds -- one-button group burn for a single-cleric group
        @{ Name = 'Assist';     Cmd = '^botstance 6 spawned' }
        @{ Name = 'AE Burn';    Cmd = '^botstance 9 spawned' }
        @{ Name = 'Passive';    Cmd = '^botstance 1 spawned' }
        # S55: nuke resist-ceiling toggles, appended after the stances (Alex's placement).
        # Class-agnostic by construction -- DoResistCheck (bot.cpp:11015-11038) reads each
        # spell's OWN resist type, so one button steers every caster to a landing element
        # (e.g. on Naggy FR/MR 340-425 are skipped, CR 70 cold lands). Value 100 is a
        # starting ceiling -- tune in-game with `^spellresistlimits nukes <value> spawned`.
        @{ Name = 'Smart Nukes'; Cmd = '^spellresistlimits nukes 100 spawned' }   # skip nukes whose effective target resist > 100; bot falls through to a lower-resist element
        @{ Name = 'Any Nuke';    Cmd = '^spellresistlimits nukes 0 spawned' }      # 0 = disable the gate (cast regardless of resist) -- the reset for Smart Nukes
    )
    for ($i = 0; $i -lt $stances.Count; $i++) {
        $btns += @{ P = 5; B = ($i + 1); Name = $stances[$i].Name; Lines = @($stances[$i].Cmd) }
    }

    # Pages 6-7 (per-class create + Delete Bot) are generated per character
    # in Set-BotSocials via Get-CreateButtons -- race/gender derive from the
    # character's name (deterministic, valid, varied).
    return $btns
}

# Per-character create buttons (pages 6-7 as of S39; was 4-5 pre-S39 before
# Group ops/Stances took those slots). Race+gender are a deterministic
# function of the character name + class: same character always gets the
# same valid roster (idempotent), different characters differ. Delete Bot
# also lives on Page 7 (slot 4, after the 3 class buttons) so the bot
# lifecycle controls (create + delete) sit together.
function Get-CreateButtons {
    param([string]$Prefix)
    $btns = @()
    for ($i = 0; $i -lt $BotClasses.Count; $i++) {
        $c     = $BotClasses[$i]
        $name  = "$Prefix$($c.Tag)"
        $valid = Get-ValidRaces -ClassId $c.Cls
        $h     = Get-StableHash "$Prefix|$($c.Tag)"
        # Per-(character, class) race override takes precedence over the
        # hash picker. See $RaceOverrides above. Falls through to the
        # hash if no override is set for this combo.
        $oKey = "$Prefix|$($c.Tag)"
        if ($RaceOverrides.ContainsKey($oKey)) {
            $race = $RaceOverrides[$oKey]
        }
        else {
            $race = $valid[ [int]($h % [uint64]$valid.Count) ]
        }
        $gender = [int](($h -shr 8) % 2)   # different hash slice than race
        $page  = if ($i -lt 12) { 6 } else { 7 }
        $btn   = if ($i -lt 12) { $i + 1 } else { $i - 11 }
        $btns += @{
            P = $page; B = $btn; Name = ('New ' + $c.Tag.ToUpper())
            Lines = @(
                "^botcreate $name $($c.Cls) $race $gender"
                "^botspawn $name"
            )
        }
    }

    # Delete Bot lives on Page 7 slot 4, immediately after the 3 overflow
    # class buttons (BST/BER block etc.). Engine opens a click-to-confirm
    # popup; no inline 'confirm' so a stray click can't delete.
    $btns += @{
        P = 7; B = 4; Name = 'Delete Bot'
        Lines = @('^botdelete')
    }
    return $btns
}

function Get-BotNamePrefix {
    # Char name from "<Char>_<ServerToken>.ini": A-Za-z only, first letter
    # upper / rest lower, truncated to 12 so prefix+3-char tag stays within
    # EQ's 15-char bot-name limit.
    param([string]$IniFileName)
    $base = $IniFileName -replace ('_' + [regex]::Escape($ServerToken) + '\.ini$'), ''
    $base = ($base -replace '[^A-Za-z]', '')
    if ($base.Length -lt 1) { return $null }
    $p = $base.Substring(0, 1).ToUpper()
    if ($base.Length -gt 1) { $p += $base.Substring(1).ToLower() }
    if ($p.Length -gt 12) { $p = $p.Substring(0, 12) }
    return $p
}

function Set-BotSocials {
    # Inject the managed [Socials] buttons into every character ini. Never
    # throws -- a failure on one file logs and is skipped; launch is never
    # blocked.
    $btns = Get-BotSocialButtons
    $iniFiles = Get-ChildItem -LiteralPath $EQRoot -Filter ("*_{0}.ini" -f $ServerToken) -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike 'UI_*' }

    foreach ($ini in $iniFiles) {
        try {
            $prefix = Get-BotNamePrefix -IniFileName $ini.Name
            if (-not $prefix) { continue }

            # Flat key=value map for this character (managed keys only).
            # Pages 2-3 are {P}-templated; pages 4-5 (create) are computed
            # for this character's name (race/gender already embedded).
            $allBtns = @($btns) + @(Get-CreateButtons -Prefix $prefix)
            $managed = [ordered]@{}
            foreach ($b in $allBtns) {
                $k = "Page$($b.P)Button$($b.B)"
                $managed["${k}Name"]  = $b.Name
                $managed["${k}Color"] = '0'
                # Coerce to an array: if Lines ever arrives as a scalar string
                # (single-element-array unwrap), $lines[$n] must still yield
                # the whole line, not its Nth character.
                $lines = @($b.Lines)
                for ($n = 0; $n -lt $lines.Count; $n++) {
                    $managed["${k}Line$($n + 1)"] = ($lines[$n] -replace '\{P\}', $prefix)
                }
            }

            $content = Get-Content -LiteralPath $ini.FullName -Raw -ErrorAction Stop
            if ($null -eq $content) { $content = '' }

            # Locate the [Socials] section (case-insensitive header match;
            # tolerate the header being the final line with no trailing nl).
            $headerRx = [regex]'(?im)^\[Socials\][^\r\n]*(\r?\n|$)'
            $hm = $headerRx.Match($content)

            if (-not $hm.Success) {
                # No section -- append one with all managed keys.
                $nl = "`r`n"
                if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) { $content += $nl }
                $block = "[Socials]$nl"
                foreach ($mk in $managed.Keys) { $block += "$mk=$($managed[$mk])$nl" }
                $content += $block
            }
            else {
                $secStart = $hm.Index + $hm.Length
                # Section ends at the next "[Header]" line or EOF.
                $nextRx = [regex]'(?m)^\['
                $nm = $nextRx.Match($content, $secStart)
                $secEnd  = if ($nm.Success) { $nm.Index } else { $content.Length }

                $pre  = $content.Substring(0, $secStart)
                $sec  = $content.Substring($secStart, $secEnd - $secStart)
                $post = $content.Substring($secEnd)

                # Theo S32 -- PRUNE orphaned managed-page keys. Set-BotSocials
                # was historically add/update-only: a bot button removed or
                # moved between releases (e.g. Group Up Page 3 -> Page 6 in
                # v1.4.10) left its old Page{P}Button* keys in every ini
                # forever, so the button never actually "moved". Make the
                # pages WE manage declarative: drop any PageNButton* line on a
                # managed page whose exact key is no longer in the current
                # managed set. Managed pages are derived from the button set
                # (S39: 2-7 -- Stances on Page 5 and Delete Bot on Page 7
                # extended the range from the pre-S39 2-6), so Page 1 and the
                # remaining personal pages (8-10) are never matched. Current
                # managed keys are left in place so the
                # in-place value replace below stays idempotent; once an ini
                # is clean there are no orphans left to strip and the file is
                # stable across launches.
                $mgPages = @($allBtns | ForEach-Object { $_.P } | Sort-Object -Unique)
                if ($mgPages.Count -gt 0) {
                    $pgAlt    = ($mgPages -join '|')
                    $orphanRx = [regex]("(?m)^(Page(?:$pgAlt)Button\d+(?:Name|Color|Line\d+))=[^\r\n]*\r?\n?")
                    $keepEval = [System.Text.RegularExpressions.MatchEvaluator]{
                        param($m)
                        if ($managed.Contains($m.Groups[1].Value)) { $m.Value } else { '' }
                    }
                    $sec = $orphanRx.Replace($sec, $keepEval)
                }

                $toAppend = @()
                foreach ($mk in $managed.Keys) {
                    $mv = $managed[$mk]
                    # Match only the value chars (NOT the trailing CR/LF), so
                    # the line's CRLF survives the replace -- otherwise an
                    # already-present key loses its \r every run and the
                    # section collapses (idempotency break).
                    $lineRx = [regex]('(?m)^' + [regex]::Escape($mk) + '=[^\r\n]*')
                    if ($lineRx.IsMatch($sec)) {
                        # MatchEvaluator returns a constant, so a '$' in the
                        # value is never treated as a regex substitution.
                        $newLine = "$mk=$mv"
                        $eval = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newLine }
                        $sec = $lineRx.Replace($sec, $eval, 1)
                    } else {
                        $toAppend += "$mk=$mv"
                    }
                }
                if ($toAppend.Count -gt 0) {
                    $trimmed = $sec -replace '\s+$', ''
                    if ($trimmed -ne '') {
                        $sec = $trimmed + "`r`n" + ($toAppend -join "`r`n") + "`r`n"
                    } else {
                        $sec = ($toAppend -join "`r`n") + "`r`n"
                    }
                }
                $content = $pre + $sec + $post
            }

            Set-Content -LiteralPath $ini.FullName -Value $content -NoNewline -ErrorAction Stop
            Write-UpdaterLog "Bot socials injected into $($ini.Name) (prefix '$prefix')."
        }
        catch {
            Write-UpdaterLog "Bot socials SKIPPED for $($ini.Name): $($_.Exception.Message)"
        }
    }
}

# --- Run ----------------------------------------------------------------------

Resolve-PendingUpdates
Update-ClientPack

# Load (or first-run-detect) the model-style prefs, then show the inline
# menu. The menu IS the keypress-to-launch gate -- it replaces the older
# Wait-ForKeyPress. Toggles persist to disk inside the loop; any non-C/W
# key (incl. Enter) exits the menu and the rest of the launch continues.
$ModelStylePrefs = Read-ModelStylePrefs
Show-ModelStyleMenu -PrefsRef ([ref]$ModelStylePrefs)

# Apply the (possibly-just-toggled) character side via $LockedSettings so
# it goes through the same ini-stamp loop as everything else. The weapon
# side is a file move and runs after the stamp.
if ($ModelStylePrefs.character_style -eq 'classic') {
    $LockedSettings['AllLuclinPcModelsOff'] = '1'
    $LockedSettings['LoadLuclinCharacters'] = 'FALSE'
} else {
    $LockedSettings['AllLuclinPcModelsOff'] = '0'
    $LockedSettings['LoadLuclinCharacters'] = 'TRUE'
}

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
        'MaxMouseLookFPS'      = 'MaxFPS'             # both live in [Defaults] in EQ's ini
        'MouseRightHanded'     = 'MouseSensitivity'   # both live in [Options]; MouseSensitivity is always present
        'AllLuclinPcModelsOff' = 'MaxFPS'             # [Defaults]; MaxFPS is the only key we KNOW exists section-wise
        'LoadLuclinCharacters' = 'MaxFPS'             # [Defaults]
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

# Pre-install the bot command Socials into every character ini (idempotent,
# per-character templated). Done before launch so the client reads them at
# char-select; never blocks launch.
Set-BotSocials

# Apply the weapon-style file move (independent of the ini stamp). Runs
# before Start-Process so the swap is settled before EQ memory-maps any
# .eqg files. Idempotent: a no-op if equipment-01.eqg is already in the
# correct location for the current weapon_style pref.
Apply-WeaponStyleFileMove -Style $ModelStylePrefs.weapon_style

Write-Host "[Launcher] Launching EverQuest..."
Start-Process -FilePath (Join-Path $EQRoot 'eqgame.exe') `
              -ArgumentList 'patchme' `
              -WorkingDirectory $EQRoot

# PowerShell exits now. The visible terminal window closes. EQ continues
# running independently. On next launch, $LockedSettings will be applied
# again -- catching any drift from the previous session.
