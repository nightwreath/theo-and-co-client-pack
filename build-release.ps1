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
    tag   = $Tag
    files = $entries
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
Write-Host "Next steps to publish:"
Write-Host ""
Write-Host "  git add -A"
Write-Host "  git commit -m 'Release $Tag'"
Write-Host "  git tag $Tag"
Write-Host "  git push origin main --tags"
Write-Host ""
Write-Host "  gh release create $Tag --title '$Tag' --notes-file CHANGELOG.md \"
$assetArgs = ($ManagedFiles | ForEach-Object { "    `"$($_.source)`"" }) -join " \`n"
Write-Host $assetArgs
Write-Host "    `"$manifestPath`""
