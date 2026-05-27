param(
    [switch]$ZipOnly
)

$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$workspaceRoot = Split-Path -Parent $projectRoot
$distFolderName = -join ([char[]](0x53EF, 0x5206, 0x53D1, 0x5B89, 0x88C5, 0x5305))
$distRoot = Join-Path $workspaceRoot $distFolderName
$productName = "FlipPanel Bridge"
$exeName = "FlipPanel-Bridge.exe"
$tempRoot = Join-Path $env:TEMP "FlipPanelBridgePublish"
$outputDir = Join-Path $tempRoot "single-file-publish"
$zipPath = Join-Path $tempRoot "FlipPanel-Bridge-win-x64.zip"
$portableDir = Join-Path $tempRoot "FlipPanel-Bridge"
$env:DOTNET_CLI_HOME = Join-Path (Split-Path -Parent $projectRoot) ".dotnet-home"
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"

Push-Location $projectRoot
try {
    $needsPublish = -not $ZipOnly -or -not (Test-Path $portableDir)
    if ($needsPublish) {
        if (Test-Path $tempRoot) {
            Remove-Item $tempRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $tempRoot | Out-Null

        if (Test-Path $outputDir) {
            Remove-Item $outputDir -Recurse -Force
        }
        if (Test-Path $portableDir) {
            Remove-Item $portableDir -Recurse -Force
        }

        $publishArgs = @(
            "publish",
            ".\ReuseDisplay.Agent.csproj",
            "-c", "Release",
            "-r", "win-x64",
            "-p:SelfContained=true",
            "-p:UseAppHost=true",
            "-p:PublishSingleFile=true",
            "-p:EnableCompressionInSingleFile=true",
            "-p:IncludeNativeLibrariesForSelfExtract=true",
            "-p:DebugType=None",
            "-p:DebugSymbols=false",
            "-p:NuGetAudit=false",
            "--ignore-failed-sources",
            "-o", $outputDir
        )

        dotnet @publishArgs

        $defaultExe = Join-Path $outputDir "ReuseDisplay.Agent.exe"
        $friendlyExe = Join-Path $outputDir $exeName
        if (Test-Path $defaultExe) {
            Move-Item -LiteralPath $defaultExe -Destination $friendlyExe -Force
        }

        $startScript = Join-Path $outputDir "start-flippanel-bridge.cmd"
        @(
            "@echo off"
            "setlocal"
            "if exist ""%~dp0$exeName"" ("
            "  call ""%~dp0$exeName"""
            "  exit /b %errorlevel%"
            ")"
            "echo Missing $exeName"
            "exit /b 1"
        ) | Set-Content -Path $startScript -Encoding ASCII

        Copy-Item -LiteralPath $outputDir -Destination $portableDir -Recurse -Force
    }

    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force
    }

    Compress-Archive -Path (Join-Path $portableDir "*") -DestinationPath $zipPath
    if (-not (Test-Path $distRoot)) {
        New-Item -ItemType Directory -Path $distRoot | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $portableDir $exeName) -Destination (Join-Path $distRoot $exeName) -Force
    Copy-Item -LiteralPath $zipPath -Destination (Join-Path $distRoot (Split-Path $zipPath -Leaf)) -Force
    Write-Host "Published $productName single-file win-x64 output in $tempRoot"
    Write-Host "Created zip package in $tempRoot"
    Write-Host "Copied distributables to $distRoot"
}
finally {
    Pop-Location
}
