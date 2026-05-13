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
