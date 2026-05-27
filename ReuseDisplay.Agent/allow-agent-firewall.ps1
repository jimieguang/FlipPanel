$ErrorActionPreference = "Stop"

param(
    [switch]$Remove
)

$tcpRuleName = "FlipPanel Bridge"
$udpRuleName = "FlipPanel Bridge UDP"

if ($Remove) {
    netsh advfirewall firewall delete rule name="$tcpRuleName" | Out-Null
    netsh advfirewall firewall delete rule name="$udpRuleName" | Out-Null
    Write-Host "Removed firewall rules: $tcpRuleName, $udpRuleName"
    exit 0
}

netsh advfirewall firewall add rule `
    name="$tcpRuleName" `
    dir=in `
    action=allow `
    protocol=TCP `
    localport=50571 | Out-Null

netsh advfirewall firewall add rule `
    name="$udpRuleName" `
    dir=in `
    action=allow `
    protocol=UDP `
    localport=50570 | Out-Null

Write-Host "Added inbound firewall rules for FlipPanel Bridge."
