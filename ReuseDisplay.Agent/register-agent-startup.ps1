param(
    [switch]$Remove
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$runScript = Join-Path $projectRoot "run-agent.ps1"
$command = "pwsh -ExecutionPolicy Bypass -File `"$runScript`""
$registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$valueName = "FlipPanelBridge"
$displayName = "FlipPanel Bridge"

if ($Remove) {
    Remove-ItemProperty -Path $registryPath -Name $valueName -ErrorAction SilentlyContinue
    Write-Host "Removed startup registration for $displayName."
    exit 0
}

Set-ItemProperty -Path $registryPath -Name $valueName -Value $command
Write-Host "Registered startup command for $displayName."
