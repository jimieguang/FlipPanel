param()

$ErrorActionPreference = "Stop"

$installerRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$agentRoot = Split-Path -Parent $installerRoot
$workspaceRoot = Split-Path -Parent $agentRoot
$distFolderName = -join ([char[]](0x53EF, 0x5206, 0x53D1, 0x5B89, 0x88C5, 0x5305))
$distRoot = Join-Path $workspaceRoot $distFolderName
$publishScript = Join-Path $agentRoot "publish-agent.ps1"
$payloadZip = Join-Path $distRoot "FlipPanel-Bridge-win-x64.zip"
$sourcePath = Join-Path $installerRoot "AgentInstaller.cs"
$outputExe = Join-Path $distRoot "FlipPanelBridgeSetup.exe"
$frameworkDir = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319"
$csc = Join-Path $frameworkDir "csc.exe"
powershell -ExecutionPolicy Bypass -File $publishScript
if (-not (Test-Path $distRoot)) {
    New-Item -ItemType Directory -Path $distRoot | Out-Null
}
if (-not (Test-Path $payloadZip)) {
    throw "Installer payload zip not found at $payloadZip"
}
& $csc /nologo /target:winexe /out:$outputExe /reference:"$frameworkDir\System.IO.Compression.dll" /reference:"$frameworkDir\System.IO.Compression.FileSystem.dll" /reference:"$frameworkDir\System.Windows.Forms.dll" /resource:"$payloadZip",payload.zip $sourcePath
if ($LASTEXITCODE -ne 0) {
    throw "Installer compilation failed."
}
Write-Host "Built installer at $outputExe"
Write-Host "Installer is ready in $distRoot"
