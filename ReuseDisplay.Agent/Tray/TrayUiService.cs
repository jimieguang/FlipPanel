using System.Drawing;
using System.Windows.Forms;
using Microsoft.Extensions.Hosting;
using ReuseDisplay.Agent.Media;
using ReuseDisplay.Agent.Netease;

namespace ReuseDisplay.Agent.Tray;

/// <summary>
/// 托盘图标 + 右键菜单。跑在自己的 STA 线程上，不和 Kestrel/MediaService 线程混。
/// 不依赖 WebSocket 连接，PC 可独立运行；手机连上后所有操作还会自动同步过去。
/// </summary>
internal sealed class TrayUiService : IHostedService, IDisposable
{
    private readonly MediaService _media;
    private readonly NeteaseClient _client;
    private readonly Action<string, string>? _log;
    private readonly Action? _requestShutdown;
    private Thread? _uiThread;
    private NotifyIcon? _icon;
    private ToolStripMenuItem? _playPauseItem;
    private ToolStripMenuItem? _likeItem;
    private ToolStripMenuItem? _autostartItem;
    private ToolStripMenuItem? _accountItem;
    private System.Windows.Forms.Timer? _tooltipTimer;
    private ApplicationContext? _appContext;

    public TrayUiService(
        MediaService media,
        NeteaseClient client,
        Action<string, string>? log = null,
        Action? requestShutdown = null)
    {
        _media = media;
        _client = client;
        _log = log;
        _requestShutdown = requestShutdown;
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        _uiThread = new Thread(RunUiLoop)
        {
            IsBackground = false,
            Name = "TrayUi"
        };
        _uiThread.SetApartmentState(ApartmentState.STA);
        _uiThread.Start();
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        try
        {
            _appContext?.ExitThread();
        }
        catch { }

        try
        {
            if (_uiThread is not null &&
                _uiThread.IsAlive &&
                Thread.CurrentThread != _uiThread)
            {
                _uiThread.Join(TimeSpan.FromSeconds(2));
            }
        }
        catch { }

        return Task.CompletedTask;
    }

    public void Dispose()
    {
        _tooltipTimer?.Dispose();
        _icon?.Dispose();
    }

    private void RunUiLoop()
    {
        Application.SetHighDpiMode(HighDpiMode.SystemAware);
        var menu = new ContextMenuStrip();

        _playPauseItem = new ToolStripMenuItem("播放/暂停", null, (_, _) => Invoke(() => _media.PlayPauseAsync()));
        var nextItem = new ToolStripMenuItem("下一首", null, (_, _) => Invoke(() => _media.NextAsync()));
        var prevItem = new ToolStripMenuItem("上一首", null, (_, _) => Invoke(() => _media.PreviousAsync()));
        _likeItem = new ToolStripMenuItem("喜欢", null, (_, _) => Invoke(() => _media.LikeAsync()));
        var dailyItem = new ToolStripMenuItem("加载每日推荐", null, (_, _) => Invoke(() => _media.LoadDailyRecommendAsync()));
        var favoriteItem = new ToolStripMenuItem("加载我的喜欢", null, (_, _) => Invoke(() => _media.LoadFavoritePlaylistAsync()));

        _accountItem = new ToolStripMenuItem("扫码登录", null, OnLoginClicked);
        var logoutItem = new ToolStripMenuItem("退出登录", null, (_, _) =>
        {
            _client.Logout();
            UpdateAccountLabel("已退出登录");
        });

        _autostartItem = new ToolStripMenuItem("开机自启", null, (_, _) =>
        {
            var newState = !Autostart.IsEnabled();
            Autostart.SetEnabled(newState);
            if (_autostartItem is not null) _autostartItem.Checked = newState;
        })
        {
            CheckOnClick = false,
            Checked = Autostart.IsEnabled()
        };

        var quitItem = new ToolStripMenuItem("退出", null, (_, _) =>
        {
            _icon!.Visible = false;
            _requestShutdown?.Invoke();
            _appContext?.ExitThread();
        });

        menu.Items.AddRange(new ToolStripItem[]
        {
            _playPauseItem, prevItem, nextItem, _likeItem,
            new ToolStripSeparator(),
            dailyItem, favoriteItem,
            new ToolStripSeparator(),
            _accountItem, logoutItem,
            new ToolStripSeparator(),
            _autostartItem,
            new ToolStripSeparator(),
            quitItem
        });

        _icon = new NotifyIcon
        {
            Icon = LoadTrayIcon(),
            ContextMenuStrip = menu,
            Text = "FlipPanel Bridge",
            Visible = true
        };
        _icon.DoubleClick += (_, _) => Invoke(() => _media.PlayPauseAsync());
        _icon.BalloonTipTitle = "FlipPanel Bridge";
        _icon.BalloonTipText = "已在系统托盘中运行。双击托盘图标可播放/暂停，右键可打开菜单。";
        _icon.BalloonTipIcon = ToolTipIcon.Info;
        _icon.ShowBalloonTip(3000);

        UpdateTooltip();
        UpdateLikeMenu();
        _media.StateChanged += (_, _) =>
        {
            UpdateTooltip();
            UpdateLikeMenu();
        };

        _tooltipTimer = new System.Windows.Forms.Timer { Interval = 1000 };
        _tooltipTimer.Tick += (_, _) => UpdateTooltip();
        _tooltipTimer.Start();

        _ = RefreshAccountLabelAsync();

        _appContext = new ApplicationContext();
        Application.Run(_appContext);

        _tooltipTimer.Stop();
        _icon.Visible = false;
    }

    private void OnLoginClicked(object? sender, EventArgs e)
    {
        var dlg = new QrLoginDialog(_client, _log);
        dlg.LoginSucceeded += async (_, _) => await RefreshAccountLabelAsync().ConfigureAwait(false);
        dlg.Show();
    }

    private async Task RefreshAccountLabelAsync()
    {
        if (!_client.HasLoginCookie)
        {
            UpdateAccountLabel("扫码登录");
            return;
        }
        try
        {
            var account = await _client.GetCurrentAccountAsync().ConfigureAwait(false);
            UpdateAccountLabel(string.IsNullOrEmpty(account.Nickname) ? "已登录" : $"已登录: {account.Nickname}");
        }
        catch (Exception ex)
        {
            _log?.Invoke("LOGIN", $"account fetch failed: {ex.Message}");
            UpdateAccountLabel("扫码登录");
        }
    }

    private void UpdateAccountLabel(string text)
    {
        if (_accountItem is null) return;
        if (_accountItem.GetCurrentParent()?.InvokeRequired == true)
        {
            _accountItem.GetCurrentParent()!.BeginInvoke(() => _accountItem.Text = text);
        }
        else
        {
            _accountItem.Text = text;
        }
    }

    private void UpdateTooltip()
    {
        if (_icon is null) return;
        var snap = _media.SnapshotNow();
        var head = snap.Title ?? "未播放";
        var artist = string.IsNullOrEmpty(snap.Artist) ? "" : $" — {snap.Artist}";
        var state = snap.PlaybackState switch
        {
            "playing" => "▶",
            "paused" => "⏸",
            "loading" => "…",
            _ => "■"
        };
        // NotifyIcon.Text 限制 63 chars
        var text = $"{state} {head}{artist}";
        if (text.Length > 63) text = text[..63];
        _icon.Text = text;
        if (_playPauseItem is not null)
        {
            _playPauseItem.Text = snap.PlaybackState == "playing" ? "暂停" : "播放";
        }
    }

    private void UpdateLikeMenu()
    {
        if (_likeItem is null) return;
        var snap = _media.SnapshotNow();
        var parent = _likeItem.GetCurrentParent();
        if (parent?.InvokeRequired == true)
        {
            parent.BeginInvoke(() => ApplyLikeMenuState(snap.IsLiked));
        }
        else
        {
            ApplyLikeMenuState(snap.IsLiked);
        }
    }

    private void ApplyLikeMenuState(bool? isLiked)
    {
        if (_likeItem is null) return;
        if (isLiked is null)
        {
            _likeItem.Text = "喜欢";
            _likeItem.ForeColor = SystemColors.GrayText;
            _likeItem.Enabled = false;
        }
        else if (isLiked.Value)
        {
            _likeItem.Text = "♥ 已喜欢";
            _likeItem.ForeColor = Color.Crimson;
            _likeItem.Enabled = true;
        }
        else
        {
            _likeItem.Text = "♡ 喜欢";
            _likeItem.ForeColor = SystemColors.ControlText;
            _likeItem.Enabled = true;
        }
    }

    private static Icon LoadTrayIcon()
    {
        try
        {
            using var stream = typeof(TrayUiService).Assembly
                .GetManifestResourceStream("tray.ico");
            if (stream is null) return SystemIcons.Application;
            return new Icon(stream, SystemInformation.SmallIconSize);
        }
        catch
        {
            return SystemIcons.Application;
        }
    }

    private static void Invoke(Func<Task> action)
    {
        _ = Task.Run(async () =>
        {
            try { await action().ConfigureAwait(false); }
            catch { }
        });
    }
}
