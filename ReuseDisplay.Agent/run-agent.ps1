$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:DOTNET_CLI_HOME = Join-Path $projectRoot "..\\.dotnet-home"
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"

Push-Location $projectRoot
try {
    dotnet run --project .\ReuseDisplay.Agent.csproj
}
finally {
    Pop-Location
}
