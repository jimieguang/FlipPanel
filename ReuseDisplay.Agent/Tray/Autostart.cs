using Microsoft.Win32;

namespace ReuseDisplay.Agent.Tray;

/// <summary>
/// HKCU\Software\Microsoft\Windows\CurrentVersion\Run 注册项管理。
/// 用 HKCU 而非 HKLM，避免要 UAC 提权。
/// </summary>
internal static class Autostart
{
    private const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "FlipPanelBridge";

    public static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(KeyPath, writable: false);
        if (key is null) return false;
        var value = key.GetValue(ValueName) as string;
        return !string.IsNullOrEmpty(value);
    }

    public static void Enable()
    {
        var exePath = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exePath)) return;
        using var key = Registry.CurrentUser.CreateSubKey(KeyPath, writable: true);
        // 加引号，路径里有空格也能跑
        key.SetValue(ValueName, $"\"{exePath}\"", RegistryValueKind.String);
    }

    public static void Disable()
    {
        using var key = Registry.CurrentUser.OpenSubKey(KeyPath, writable: true);
        key?.DeleteValue(ValueName, throwOnMissingValue: false);
    }

    public static void SetEnabled(bool enabled)
    {
        if (enabled) Enable();
        else Disable();
    }
}
