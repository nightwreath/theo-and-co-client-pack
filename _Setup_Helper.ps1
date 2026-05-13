# Helper for First_Time_Setup.bat - creates the EQ desktop shortcut.
# Don't run this directly; use First_Time_Setup.bat instead.

$here   = $PSScriptRoot
$eqroot = Split-Path $here -Parent

$WshShell    = New-Object -ComObject WScript.Shell
$desktop     = [Environment]::GetFolderPath('Desktop')
$linkPath    = Join-Path $desktop "EQ - Theo and Co.lnk"

$lnk                  = $WshShell.CreateShortcut($linkPath)
$lnk.TargetPath       = "powershell.exe"
$lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$here\Launch_EQ.ps1`""
$lnk.WorkingDirectory = $eqroot
$lnk.IconLocation     = Join-Path $eqroot "Everquest.ico"
$lnk.Save()

Write-Host ""
Write-Host "Desktop shortcut created:" -ForegroundColor Green
Write-Host "  $linkPath" -ForegroundColor Green
Write-Host ""
Write-Host "Double-click that shortcut on your desktop anytime to play." -ForegroundColor Green
Write-Host ""
