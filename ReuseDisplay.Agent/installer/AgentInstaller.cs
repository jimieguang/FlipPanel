using System;
using System.Reflection;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        try
        {
            var installDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "FlipPanelBridge");

            var tempRoot = Path.Combine(Path.GetTempPath(), "FlipPanelBridgeInstaller");
            var zipPath = Path.Combine(tempRoot, "payload.zip");
            var extractDir = Path.Combine(tempRoot, "payload");

            if (Directory.Exists(tempRoot))
            {
                Directory.Delete(tempRoot, true);
            }

            Directory.CreateDirectory(tempRoot);
            Directory.CreateDirectory(extractDir);
            using (var payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
            using (var file = File.Create(zipPath))
            {
                if (payload == null)
                {
                    throw new InvalidOperationException("Missing installer payload.");
                }

                payload.CopyTo(file);
            }
            ZipFile.ExtractToDirectory(zipPath, extractDir);

            Directory.CreateDirectory(installDir);
            CopyDirectory(extractDir, installDir);

            RegisterStartup(Path.Combine(installDir, "start-flippanel-bridge.cmd"));
            TryRunFirewallScript(Path.Combine(installDir, "allow-agent-firewall.ps1"));
            CreateShortcuts(installDir);
            TryStartAgent(Path.Combine(installDir, "FlipPanel-Bridge.exe"));

            MessageBox.Show(
                "FlipPanel Bridge installed to " + installDir + ".",
                "FlipPanel Bridge",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                ex.Message,
                "FlipPanel Bridge Installer",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private static void RegisterStartup(string startAgentCmd)
    {
        using (var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
        {
            key.SetValue("FlipPanelBridge", "\"" + startAgentCmd + "\"");
        }
    }

    private static void TryRunFirewallScript(string firewallScript)
    {
        if (!File.Exists(firewallScript))
        {
            return;
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "powershell",
                Arguments = "-ExecutionPolicy Bypass -File \"" + firewallScript + "\"",
                UseShellExecute = true,
                Verb = "runas"
            });
        }
        catch
        {
        }
    }

    private static void CreateShortcuts(string installDir)
    {
        var startCmd = Path.Combine(installDir, "FlipPanel-Bridge.exe");
        var uninstallCmd = Path.Combine(installDir, "uninstall-flippanel-bridge.cmd");
        File.WriteAllLines(uninstallCmd, new[]
        {
            "@echo off",
            "reg delete HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run /v FlipPanelBridge /f >nul 2>nul",
            "rmdir /s /q \"" + installDir + "\""
        });

        var shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
        var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        var startMenu = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
            "Programs",
            "FlipPanel Bridge");
        Directory.CreateDirectory(startMenu);

        CreateShortcut(shell, Path.Combine(desktop, "FlipPanel Bridge.lnk"), startCmd, installDir);
        CreateShortcut(shell, Path.Combine(startMenu, "FlipPanel Bridge.lnk"), startCmd, installDir);
        CreateShortcut(shell, Path.Combine(startMenu, "Uninstall FlipPanel Bridge.lnk"), uninstallCmd, installDir);
    }

    private static void TryStartAgent(string agentExe)
    {
        if (!File.Exists(agentExe))
        {
            return;
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = agentExe,
                WorkingDirectory = Path.GetDirectoryName(agentExe)
            });
        }
        catch
        {
        }
    }

    private static void CreateShortcut(object shell, string shortcutPath, string targetPath, string workingDirectory)
    {
        dynamic shortcut = shell.GetType().InvokeMember(
            "CreateShortcut",
            System.Reflection.BindingFlags.InvokeMethod,
            null,
            shell,
            new object[] { shortcutPath });
        shortcut.TargetPath = targetPath;
        shortcut.WorkingDirectory = workingDirectory;
        shortcut.Save();
    }

    private static void CopyDirectory(string sourceDir, string targetDir)
    {
        foreach (var directory in Directory.GetDirectories(sourceDir, "*", SearchOption.AllDirectories))
        {
            var relative = directory.Substring(sourceDir.Length).TrimStart(Path.DirectorySeparatorChar);
            Directory.CreateDirectory(Path.Combine(targetDir, relative));
        }

        foreach (var file in Directory.GetFiles(sourceDir, "*", SearchOption.AllDirectories))
        {
            var relative = file.Substring(sourceDir.Length).TrimStart(Path.DirectorySeparatorChar);
            var destination = Path.Combine(targetDir, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination));
            File.Copy(file, destination, true);
        }
    }
}
