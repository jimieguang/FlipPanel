$ErrorActionPreference = "Stop"

Write-Error @"
Device-owner provisioning is not supported by the current project state.

Reason:
- FlipPanelFlutter does not declare a DeviceAdminReceiver in AndroidManifest.xml.
- The historical device-owner instructions were removed because they no longer match the code.

See KIOSK_SETUP.md for the currently supported kiosk-related capabilities.
"@
exit 1
