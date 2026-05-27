param(
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$workspaceRoot = Split-Path -Parent $projectRoot
$distFolderName = -join ([char[]](0x53EF, 0x5206, 0x53D1, 0x5B89, 0x88C5, 0x5305))
$distRoot = Join-Path $workspaceRoot $distFolderName
$flutterSdk = "C:\Users\a\flutter-sdk\flutter"
$androidSdk = "C:\Users\a\AppData\Local\Android\Sdk"
$javaHome = "C:\Program Files\Android\Android Studio\jbr"

# Flutter AOT compiler doesn't support non-ASCII paths on Windows,
# so we copy the project to C:\fpf for the actual build.
$buildRoot = "C:\fpf"

$env:JAVA_HOME = $javaHome
$env:ANDROID_HOME = $androidSdk
$env:ANDROID_SDK_ROOT = $androidSdk
$env:ANDROID_USER_HOME = "C:\a"
$env:GRADLE_USER_HOME = "C:\g"
$env:PATH = "$flutterSdk\bin;$env:PATH"

# Sync project to build directory
Write-Host "Syncing project to $buildRoot ..."
if (Test-Path $buildRoot) {
    Remove-Item $buildRoot -Recurse -Force
}
Copy-Item -Path $projectRoot -Destination $buildRoot -Recurse -Force

# Write local.properties
$localProps = @"
sdk.dir=$($androidSdk -replace '\\', '\\\\')
flutter.sdk=$($flutterSdk -replace '\\', '\\\\')
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
    & "$flutterSdk\bin\flutter.bat" build apk --release
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
