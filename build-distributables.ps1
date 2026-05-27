$ErrorActionPreference = "Stop"

$workspaceRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$distFolderName = -join ([char[]](0x53EF, 0x5206, 0x53D1, 0x5B89, 0x88C5, 0x5305))
$distRoot = Join-Path $workspaceRoot $distFolderName

Write-Host "Preparing distributables in $distRoot ..."
if (-not (Test-Path $distRoot)) {
    New-Item -ItemType Directory -Path $distRoot | Out-Null
}
Get-ChildItem -LiteralPath $distRoot -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne ".gitkeep" } |
    Remove-Item -Recurse -Force

Push-Location $workspaceRoot
try {
    powershell -ExecutionPolicy Bypass -File ".\ReuseDisplay.Agent\installer\build-installer.ps1"
    powershell -ExecutionPolicy Bypass -File ".\FlipPanelFlutter\build-apk.ps1"
}
finally {
    Pop-Location
}

Write-Host "Distributables ready in $distRoot"
