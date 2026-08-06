<#
  Creates "Video Encoding.lnk" in the repo root: double-clickable like
  LaunchUI.bat, but carrying the app icon. Shortcuts embed absolute paths, so
  the .lnk is generated per machine (and gitignored) rather than committed --
  run this once after cloning or moving the repo.

  Optionally pass -Desktop to also place a copy on the user's Desktop.
#>

[CmdletBinding()]
param([switch]$Desktop)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$ico  = Join-Path $repo 'assets\icon.ico'

function New-UiShortcut {
  param([Parameter(Mandatory)][string]$LnkPath)
  $shell = New-Object -ComObject WScript.Shell
  $lnk = $shell.CreateShortcut($LnkPath)
  $lnk.TargetPath = 'powershell.exe'
  $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $repo 'ui.ps1')
  $lnk.WorkingDirectory = $repo
  $lnk.WindowStyle = 7   # minimized console; the WPF window fronts itself
  if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = "$ico,0" }
  $lnk.Description = 'Video Encoding - drop-folder encoder UI'
  $lnk.Save()
  Write-Host "created $LnkPath"
}

New-UiShortcut -LnkPath (Join-Path $repo 'Video Encoding.lnk')
if ($Desktop) {
  New-UiShortcut -LnkPath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Video Encoding.lnk')
}
