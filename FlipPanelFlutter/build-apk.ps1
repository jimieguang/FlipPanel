param(
    [switch]$Clean,
    [string]$FlutterSdk,
    [string]$AndroidSdk,
    [string]$JavaHome,
    [string]$BuildRoot
)

$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$workspaceRoot = Split-Path -Parent $projectRoot
$distFolderName = -join ([char[]](0x53EF, 0x5206, 0x53D1, 0x5B89, 0x88C5, 0x5305))
$distRoot = Join-Path $workspaceRoot $distFolderName

function Resolve-FlutterSdkRoot {
    param([string]$ExplicitPath)

    $candidates = @()
    if ($ExplicitPath) { $candidates += $ExplicitPath }
    if ($env:FLUTTER_ROOT) { $candidates += $env:FLUTTER_ROOT }
    if ($env:FLUTTER_HOME) { $candidates += $env:FLUTTER_HOME }
    $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutterCommand) {
        $candidates += (Split-Path -Parent (Split-Path -Parent $flutterCommand.Source))
    }
    $candidates += "C:\Users\a\flutter-sdk\flutter"

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $resolved = $null
        try { $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch { }
        if ($resolved -and (Test-Path (Join-Path $resolved "bin\flutter.bat"))) {
            return $resolved
        }
    }

    throw "Flutter SDK not found. Set -FlutterSdk, FLUTTER_ROOT, or ensure flutter is available in PATH."
}

function Resolve-AndroidSdkRoot {
    param([string]$ExplicitPath)

    $candidates = @()
    if ($ExplicitPath) { $candidates += $ExplicitPath }
    if ($env:ANDROID_SDK_ROOT) { $candidates += $env:ANDROID_SDK_ROOT }
    if ($env:ANDROID_HOME) { $candidates += $env:ANDROID_HOME }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Android\Sdk") }
    $candidates += "C:\Users\a\AppData\Local\Android\Sdk"

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $resolved = $null
        try { $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch { }
        if ($resolved -and (Test-Path $resolved)) {
            return $resolved
        }
    }

    throw "Android SDK not found. Set -AndroidSdk or ANDROID_SDK_ROOT."
}

function Resolve-JavaHome {
    param([string]$ExplicitPath)

    $candidates = @()
    if ($ExplicitPath) { $candidates += $ExplicitPath }
    if ($env:JAVA_HOME) { $candidates += $env:JAVA_HOME }
    $candidates += "C:\Program Files\Android\Android Studio\jbr"

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $resolved = $null
        try { $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch { }
        if ($resolved -and (Test-Path (Join-Path $resolved "bin\java.exe"))) {
            return $resolved
        }
    }

    throw "Java runtime not found. Set -JavaHome or JAVA_HOME."
}

$flutterSdkRoot = Resolve-FlutterSdkRoot -ExplicitPath $FlutterSdk
$androidSdkRoot = Resolve-AndroidSdkRoot -ExplicitPath $AndroidSdk
$javaHomeRoot = Resolve-JavaHome -ExplicitPath $JavaHome
$runnerTemp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { "C:\Temp" }

if ($BuildRoot) {
    $buildRootPath = $BuildRoot
} elseif ($env:GITHUB_ACTIONS -eq "true") {
    $buildRootPath = Join-Path $runnerTemp "fpf"
} else {
    # Flutter AOT compiler doesn't support non-ASCII paths on Windows,
    # so we copy the project to an ASCII-only path for the actual build.
    $buildRootPath = "C:\fpf"
}

$buildRoot = $buildRootPath
$androidUserHome = Join-Path $runnerTemp "android-user-home"
$gradleUserHome = Join-Path $runnerTemp "gradle-user-home"

foreach ($path in @((Split-Path -Parent $buildRoot), $androidUserHome, $gradleUserHome)) {
    if ($path -and -not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

$env:JAVA_HOME = $javaHomeRoot
$env:ANDROID_HOME = $androidSdkRoot
$env:ANDROID_SDK_ROOT = $androidSdkRoot
$env:ANDROID_USER_HOME = $androidUserHome
$env:GRADLE_USER_HOME = $gradleUserHome
$env:PATH = "$flutterSdkRoot\bin;$env:PATH"

# Sync project to build directory
Write-Host "Syncing project to $buildRoot ..."
if (Test-Path $buildRoot) {
    Remove-Item $buildRoot -Recurse -Force
}
Copy-Item -Path $projectRoot -Destination $buildRoot -Recurse -Force

# Write local.properties
$localProps = @"
sdk.dir=$($androidSdkRoot -replace '\\', '\\\\')
flutter.sdk=$($flutterSdkRoot -replace '\\', '\\\\')
"@
Set-Content -Path "$buildRoot\android\local.properties" -Value $localProps -Encoding ASCII

# Clean dart cache if requested
if ($Clean) {
    $dartTool = "$buildRoot\.dart_tool"
    if (Test-Path $dartTool) { Remove-Item $dartTool -Recurse -Force }
    $buildDir = "$buildRoot\build"
    if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
}

# Build APK
Write-Host "Building APK ..."
Push-Location $buildRoot
try {
    & "$flutterSdkRoot\bin\flutter.bat" build apk --release
} finally {
    Pop-Location
}

# Copy APK to root distributables
$apkSrc = "$buildRoot\build\app\outputs\flutter-apk\app-release.apk"
$distApk = Join-Path $distRoot "FlipPanel-Companion.apk"
if (Test-Path $apkSrc) {
    if (-not (Test-Path $distRoot)) {
        New-Item -ItemType Directory -Path $distRoot | Out-Null
    }
    Copy-Item -Path $apkSrc -Destination $distApk -Force
    Write-Host "`nAPK built successfully: $distApk"
    Write-Host "Copied distributable APK to: $distApk"
    Write-Host "Size: $([math]::Round((Get-Item $distApk).Length / 1MB, 1)) MB"
} else {
    Write-Host "ERROR: APK not found at $apkSrc"
    exit 1
}
