using System.Drawing;
using System.Windows.Forms;
using QRCoder;
using ReuseDisplay.Agent.Netease;

namespace ReuseDisplay.Agent.Tray;

/// <summary>
/// 扫码登录窗口：调用网易 unikey 接口拿 key → 渲染 QR 图 → 后台轮询 client/login 直到登录成功或失败。
/// 登录成功后 NeteaseClient 的 CookieStore 已自动吸收 Set-Cookie（MUSIC_U 等），不需要在这里手动持久化。
/// </summary>
internal sealed class QrLoginDialog : Form
{
    private readonly NeteaseClient _client;
    private readonly Action<string, string>? _log;
    private readonly PictureBox _qrBox = new() { Dock = DockStyle.Top, Height = 320, SizeMode = PictureBoxSizeMode.Zoom };
    private readonly Label _status = new() { Dock = DockStyle.Top, Height = 60, TextAlign = ContentAlignment.MiddleCenter };
    private readonly Button _refresh = new() { Dock = DockStyle.Bottom, Height = 40, Text = "刷新二维码" };
    private CancellationTokenSource _pollCts = new();
    private string? _unikey;

    public event EventHandler? LoginSucceeded;

    public QrLoginDialog(NeteaseClient client, Action<string, string>? log = null)
    {
        _client = client;
        _log = log;
        Text = "网易云扫码登录";
        Width = 360;
        Height = 460;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        Controls.Add(_status);
        Controls.Add(_qrBox);
        Controls.Add(_refresh);
        _refresh.Click += async (_, _) => await StartFlowAsync().ConfigureAwait(false);
        FormClosing += (_, _) => _pollCts.Cancel();
        Shown += async (_, _) => await StartFlowAsync().ConfigureAwait(false);
    }

    private async Task StartFlowAsync()
    {
        _pollCts.Cancel();
        _pollCts = new CancellationTokenSource();
        var ct = _pollCts.Token;
        SetStatus("正在获取二维码…");
        try
        {
            var keyResult = await _client.GetQrKeyAsync(ct).ConfigureAwait(true);
            if (keyResult.Code != 200 || string.IsNullOrEmpty(keyResult.Unikey) || string.IsNullOrEmpty(keyResult.LoginUrl))
            {
                SetStatus($"获取二维码失败: code={keyResult.Code} {keyResult.Message}");
                return;
            }
            _unikey = keyResult.Unikey;
            var image = RenderQr(keyResult.LoginUrl);
            _qrBox.Image?.Dispose();
            _qrBox.Image = image;
            SetStatus("用网易云 App 扫码授权");
            _ = Task.Run(() => PollLoopAsync(_unikey, ct));
        }
        catch (Exception ex)
        {
            _log?.Invoke("LOGIN", $"qr key failed: {ex.Message}");
            SetStatus($"出错: {ex.Message}");
        }
    }

    private async Task PollLoopAsync(string key, CancellationToken ct)
    {
        var attempts = 0;
        while (!ct.IsCancellationRequested && attempts < 90) // 最多 ~3min
        {
            attempts++;
            try
            {
                var check = await _client.CheckQrAsync(key, ct).ConfigureAwait(false);
                _log?.Invoke("LOGIN", $"check code={check.Code} msg={check.Message}");
                switch (check.Code)
                {
                    case 803: // 登录成功
                        BeginInvoke(() =>
                        {
                            SetStatus("登录成功");
                            LoginSucceeded?.Invoke(this, EventArgs.Empty);
                            Close();
                        });
                        return;
                    case 800: // 二维码失效
                        BeginInvoke(() => SetStatus("二维码已失效，请点刷新"));
                        return;
                    case 801: // 等待扫码
                        BeginInvoke(() => SetStatus("用网易云 App 扫码授权"));
                        break;
                    case 802: // 已扫码，等确认
                        BeginInvoke(() => SetStatus("已扫码，请在手机上确认"));
                        break;
                    default:
                        BeginInvoke(() => SetStatus($"状态: {check.Code} {check.Message}"));
                        break;
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                _log?.Invoke("LOGIN", $"poll error: {ex.Message}");
            }
            try { await Task.Delay(2000, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
        }
        BeginInvoke(() => SetStatus("超时，请点刷新重试"));
    }

    private static Bitmap RenderQr(string text)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(text, QRCodeGenerator.ECCLevel.M);
        using var qr = new QRCode(data);
        return qr.GetGraphic(8);
    }

    private void SetStatus(string text)
    {
        if (_status.InvokeRequired)
        {
            _status.BeginInvoke(() => _status.Text = text);
        }
        else
        {
            _status.Text = text;
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _pollCts.Cancel();
            _pollCts.Dispose();
            _qrBox.Image?.Dispose();
        }
        base.Dispose(disposing);
    }
}
