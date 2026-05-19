# Build a release bundle for theo-and-co-client-pack.
#
# Generates manifest.json with SHA256 hashes of every managed file, then prints
# the gh-cli commands needed to publish the release.
#
# Usage: pwsh ./build-release.ps1 -Tag v1.0

param(
    [Parameter(Mandatory)]
    [string]$Tag
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot

# Every file this release manages. install_path is relative to the friend's
# EQ root (the parent of "Theo and Co/"). Order doesn't matter.
$ManagedFiles = @(
    @{
        name         = 'Launch_EQ.ps1'
        install_path = 'Theo and Co/Launch_EQ.ps1'
        source       = Join-Path $RepoRoot 'Launch_EQ.ps1'
    }
    @{
        # Stable bootstrap/starter. Friends launch through this (Play_EQ.bat
        # and the desktop shortcut both point here now). It fetches the
        # latest Launch_EQ.ps1 then runs it -- so a launcher update fully
        # applies in ONE run instead of the 3-run self-update bootstrap lag.
        # Designed to never need changing; shipped as a managed file anyway
        # so a fix CAN be pushed (rare; would take the one-time lag itself).
        name         = 'Run_Theo_and_Co.ps1'
        install_path = 'Theo and Co/Run_Theo_and_Co.ps1'
        source       = Join-Path $RepoRoot 'Run_Theo_and_Co.ps1'
    }
    @{
        name         = 'Play_EQ.bat'
        install_path = 'Theo and Co/Play_EQ.bat'
        source       = Join-Path $RepoRoot 'Play_EQ.bat'
    }
    @{
        name         = '_Setup_Helper.ps1'
        install_path = 'Theo and Co/_Setup_Helper.ps1'
        source       = Join-Path $RepoRoot '_Setup_Helper.ps1'
    }
    @{
        name         = 'First_Time_Setup.bat'
        install_path = 'Theo and Co/First_Time_Setup.bat'
        source       = Join-Path $RepoRoot 'First_Time_Setup.bat'
    }
    @{
        # Compiled Zeal-RoF2 DLL. Miles Sound System auto-loads any *.asi in
        # the EQ root directory at sound init, so the install_path is the EQ
        # root (sibling of mssmp3.asi / mssvoice.asi), NOT the "Theo and Co"
        # launcher subfolder. Built externally from
        # https://github.com/nightwreath/Zeal-RoF2 and dropped into this repo
        # dir before running build-release; gitignored so the ~10MB binary
        # doesn't bloat the client-pack git history.
        name         = 'Zeal.asi'
        install_path = 'Zeal.asi'
        source       = Join-Path $RepoRoot 'Zeal.asi'
    }
    @{
        # Wayfinder Skyla token-currency NAME (Session 32). The RoF2
        # client resolves the alternate-currency label from its OWN
        # dbstr_us.txt by currency id -- AltCurrencyPopulateEntry_Struct
        # sends only the number, never the name (verified vs
        # theo-and-co-engine). Custom currency 6 (server sql/056) has no
        # stock entry, so the merchant window showed "Unknown DB String
        # 6-18". This file = the friend base dbstr_us.txt + 3 appended
        # lines (6^17/18/71 = "Skyla Token"/"Skyla Tokens"). EQ root,
        # sibling of eqgame.exe (like Zeal.asi).
        name         = 'dbstr_us.txt'
        install_path = 'dbstr_us.txt'
        source       = Join-Path $RepoRoot 'dbstr_us.txt'
    }
    # Classic-zone fidelity (Session 24). These zones run TAKP V2.1c classic
    # geometry; the stock RoF2 _EnvironmentEmitters.txt described the revamped
    # zones (floating torches/fires) and the bundled maps were the revamped
    # layouts. Emitter files are neutralized to header-only (overwrites the
    # friend's revamped one -> client falls back to the zone's classic .emt);
    # maps are the Brewall original-zone variants. install_path with a "maps/"
    # prefix is handled by the launcher (it Split-Path's the parent and
    # New-Item -Force creates it if absent).
    @{
        name         = 'nektulos_EnvironmentEmitters.txt'
        install_path = 'nektulos_EnvironmentEmitters.txt'
        source       = Join-Path $RepoRoot 'nektulos_EnvironmentEmitters.txt'
    }
    @{
        name         = 'lavastorm_EnvironmentEmitters.txt'
        install_path = 'lavastorm_EnvironmentEmitters.txt'
        source       = Join-Path $RepoRoot 'lavastorm_EnvironmentEmitters.txt'
    }
    @{
        name         = 'nektulos.txt'
        install_path = 'maps/nektulos.txt'
        source       = Join-Path $RepoRoot 'maps\nektulos.txt'
    }
    @{
        name         = 'nektulos_1.txt'
        install_path = 'maps/nektulos_1.txt'
        source       = Join-Path $RepoRoot 'maps\nektulos_1.txt'
    }
    @{
        name         = 'nektulos_2.txt'
        install_path = 'maps/nektulos_2.txt'
        source       = Join-Path $RepoRoot 'maps\nektulos_2.txt'
    }
    @{
        name         = 'lavastorm.txt'
        install_path = 'maps/lavastorm.txt'
        source       = Join-Path $RepoRoot 'maps\lavastorm.txt'
    }
    @{
        name         = 'lavastorm_1.txt'
        install_path = 'maps/lavastorm_1.txt'
        source       = Join-Path $RepoRoot 'maps\lavastorm_1.txt'
    }
    @{
        name         = 'lavastorm_2.txt'
        install_path = 'maps/lavastorm_2.txt'
        source       = Join-Path $RepoRoot 'maps\lavastorm_2.txt'
    }
    # Classic in-game maps (Session 25 map audit). These zones load CLASSIC
    # geometry on RoF2 but shipped with non-classic / unknown-provenance map
    # overlays. Brewall classic maps, in-game verified S25 against the real
    # geometry. highpasshold = classic Highpass served via the reachable
    # zone (so the map ships under the highpasshold name); commons/misty/tox
    # are reached under their own classic short-names on RoF2.
    @{ name='highpasshold.txt';   install_path='maps/highpasshold.txt';   source=Join-Path $RepoRoot 'maps\highpasshold.txt' }
    @{ name='highpasshold_1.txt'; install_path='maps/highpasshold_1.txt'; source=Join-Path $RepoRoot 'maps\highpasshold_1.txt' }
    @{ name='highpasshold_2.txt'; install_path='maps/highpasshold_2.txt'; source=Join-Path $RepoRoot 'maps\highpasshold_2.txt' }
    @{ name='commons.txt';        install_path='maps/commons.txt';        source=Join-Path $RepoRoot 'maps\commons.txt' }
    @{ name='commons_1.txt';      install_path='maps/commons_1.txt';      source=Join-Path $RepoRoot 'maps\commons_1.txt' }
    @{ name='commons_2.txt';      install_path='maps/commons_2.txt';      source=Join-Path $RepoRoot 'maps\commons_2.txt' }
    @{ name='misty.txt';          install_path='maps/misty.txt';          source=Join-Path $RepoRoot 'maps\misty.txt' }
    @{ name='misty_1.txt';        install_path='maps/misty_1.txt';        source=Join-Path $RepoRoot 'maps\misty_1.txt' }
    @{ name='misty_2.txt';        install_path='maps/misty_2.txt';        source=Join-Path $RepoRoot 'maps\misty_2.txt' }
    @{ name='tox.txt';            install_path='maps/tox.txt';            source=Join-Path $RepoRoot 'maps\tox.txt' }
    @{ name='tox_1.txt';          install_path='maps/tox_1.txt';          source=Join-Path $RepoRoot 'maps\tox_1.txt' }
    @{ name='tox_2.txt';          install_path='maps/tox_2.txt';          source=Join-Path $RepoRoot 'maps\tox_2.txt' }
    # Classic Highpass (Session 25). The reachable `highpasshold` zone (id
    # 407) now serves classic Highpass: server DB/maps already done (sql/029
    # +030); these are the CLIENT geometry/audio. Geometry = FV Project's
    # Highpasshold.zip (classic content repackaged with internal WLDs renamed
    # -- a naive outer rename renders a blank void; see ARCHITECTURE quirk
    # #11). The modern revamp's highpasshold.eqg/.zon/_EnvironmentEmitters.txt
    # MUST be removed (RoF2 loads .eqg over .s3d) -- handled via
    # $ManagedDeletions below. .emt is the music-line-removed file validated
    # on Alex's client. install_path is the EQ root (siblings of eqgame.exe).
    @{
        name         = 'highpasshold.s3d'
        install_path = 'highpasshold.s3d'
        source       = Join-Path $RepoRoot 'highpasshold.s3d'
    }
    @{
        name         = 'highpasshold_obj.s3d'
        install_path = 'highpasshold_obj.s3d'
        source       = Join-Path $RepoRoot 'highpasshold_obj.s3d'
    }
    @{
        name         = 'highpasshold_chr.s3d'
        install_path = 'highpasshold_chr.s3d'
        source       = Join-Path $RepoRoot 'highpasshold_chr.s3d'
    }
    @{
        name         = 'highpasshold.emt'
        install_path = 'highpasshold.emt'
        source       = Join-Path $RepoRoot 'highpasshold.emt'
    }
    @{
        name         = 'highpasshold_chr.txt'
        install_path = 'highpasshold_chr.txt'
        source       = Join-Path $RepoRoot 'highpasshold_chr.txt'
    }
    @{
        name         = 'highpasshold_sndbnk.eff'
        install_path = 'highpasshold_sndbnk.eff'
        source       = Join-Path $RepoRoot 'highpasshold_sndbnk.eff'
    }
    @{
        name         = 'highpasshold_sounds.eff'
        install_path = 'highpasshold_sounds.eff'
        source       = Join-Path $RepoRoot 'highpasshold_sounds.eff'
    }
)

# Files to DELETE from the friend's EQ root (relative to it, same base as
# install_path). The launcher removes these if present, idempotently. Used
# when shipping a classic .s3d that the modern .eqg would otherwise override
# (RoF2 prefers .eqg > .s3d). Older launchers (pre-delete-manifest) simply
# ignore this key, so the manifest stays backward compatible.
$ManagedDeletions = @(
    'highpasshold.eqg'
    'highpasshold.zon'
    'highpasshold_EnvironmentEmitters.txt'
    # Bazaar (Session 25). Bazaar runs TAKP V2.1c classic geometry, but the
    # stock RoF2 bazaar maps are the revamped DoDh layout (multi-level, does
    # not match what you walk). No correct classic bazaar overlay exists
    # (Brewall ships none; TAKP ships no map overlays). Decision: ship NO
    # bazaar map -- a blank in-game map beats a wrong one. Delete the
    # revamped overlays so none loads.
    'maps/bazaar.txt'
    'maps/bazaar_1.txt'
    'maps/bazaar_2.txt'
    'maps/bazaar_3.txt'
)

# Compute hashes
$entries = @()
foreach ($file in $ManagedFiles) {
    if (-not (Test-Path $file.source)) {
        throw "Source file missing: $($file.source)"
    }
    $hash = (Get-FileHash -Path $file.source -Algorithm SHA256).Hash.ToLower()
    $entries += [ordered]@{
        name         = $file.name
        install_path = $file.install_path
        sha256       = $hash
    }
    Write-Host "  $($file.name)  sha256=$hash"
}

$manifest = [ordered]@{
    tag       = $Tag
    files     = $entries
    deletions = @($ManagedDeletions)
}

if ($ManagedDeletions.Count -gt 0) {
    Write-Host ""
    foreach ($d in $ManagedDeletions) { Write-Host "  (delete) $d" }
}

$manifestPath = Join-Path $RepoRoot 'manifest.json'

# IMPORTANT: write UTF-8 WITHOUT BOM. PowerShell 5.1's `Set-Content -Encoding
# UTF8` writes a BOM, which Invoke-RestMethod's JSON parser silently fails on
# (returns the raw response as a string instead of a parsed object). That bug
# made every "auto-update" between v1.0.1 and v1.0.4 a silent no-op.
$json = $manifest | ConvertTo-Json -Depth 5
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, $json, $utf8NoBom)

Write-Host ""
Write-Host "Wrote $manifestPath (UTF-8, no BOM)"
Write-Host ""
Write-Host "Next steps to publish (PowerShell -- single-line commands, paste as-is):"
Write-Host ""
Write-Host "  git add -A"
Write-Host "  git commit -m `"Release $Tag`""
Write-Host "  git tag $Tag"
Write-Host "  git push origin main --tags"
Write-Host ""
# IMPORTANT: emit ONE single-line PowerShell command with every asset source
# AND manifest.json. The old version printed bash-style `\` continuations and
# left manifest.json orphaned on its own line -- pasted into PowerShell it
# broke, and a release published without the manifest.json asset makes every
# friend's launcher log "Update skipped (no manifest in release)" and pull
# nothing (silent failure). One line, no continuations, manifest.json last.
$assetList = (($ManagedFiles | ForEach-Object { "`"$($_.source)`"" }) + "`"$manifestPath`"") -join ' '
Write-Host "  gh release create $Tag --title `"$Tag`" --notes-file CHANGELOG.md $assetList"
