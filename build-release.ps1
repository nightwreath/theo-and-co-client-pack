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
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8 -NoNewline
Write-Host ""
Write-Host "Wrote $manifestPath"
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
