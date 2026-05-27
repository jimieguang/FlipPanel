using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Hosting;
using ReuseDisplay.Agent.Media;
using ReuseDisplay.Agent.Netease;
using ReuseDisplay.Agent.Tray;
using System.Windows.Forms;

// 单例锁：第二次启动直接退出，避免多个托盘图标和端口冲突
var singleInstanceMutex = new Mutex(initiallyOwned: true, "ReuseDisplay.Agent.SingleInstance", out var firstInstance);
if (!firstInstance)
{
    try
    {
        MessageBox.Show(
            "FlipPanel Bridge 已在后台运行。",
            "FlipPanel Bridge",
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
    }
    catch
    {
        Console.WriteLine("FlipPanel Bridge is already running.");
    }
    return;
}

var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;
    cts.Cancel();
};

var settings = AgentSettings.Load(args);

// 写文件日志：WinExe 启动时 stdout 被丢弃，没文件就什么都看不到。
// 路径与 cookie 同目录，方便用户出问题时直接抓 %USERPROFILE%\.reusedisplay\agent.log。
var logFilePath = Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
    ".reusedisplay",
    "agent.log");
StreamWriter? logFile = null;
try
{
    Directory.CreateDirectory(Path.GetDirectoryName(logFilePath)!);
    var stream = new FileStream(logFilePath, FileMode.Create, FileAccess.Write, FileShare.Read);
    logFile = new StreamWriter(stream) { AutoFlush = true };
}
catch { /* 日志文件不可写就只保留 stdout */ }

var neteaseClient = new NeteaseClient();
var mediaService = new MediaService(neteaseClient, (cat, msg) => Log(cat, msg));
await mediaService.StartAsync(cts.Token);
var trayService = new TrayUiService(
    mediaService,
    neteaseClient,
    (cat, msg) => Log(cat, msg),
    () => cts.Cancel());
await trayService.StartAsync(cts.Token);
var musicController = new MusicController(
    mediaService,
    message => Log("MUSIC", message));
var clients = new ConcurrentDictionary<Guid, WsClient>();
var sampler = new SnapshotSampler();
var runtime = new AgentRuntimeState();
var jsonOptions = new JsonSerializerOptions(JsonSerializerDefaults.Web);

// 封面代理共用 HttpClient：原来每请求 new HttpClient 在高频访问下耗光临时端口
// （TIME_WAIT 累积），且 SocketsHttpHandler 默认不重新解析 DNS。
// PooledConnectionLifetime=5min 让长寿命池在 CDN IP 切换时也能跟上。
var coverHttpHandler = new SocketsHttpHandler
{
    PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    PooledConnectionIdleTimeout = TimeSpan.FromMinutes(2),
    AutomaticDecompression = System.Net.DecompressionMethods.All
};
var coverHttpClient = new HttpClient(coverHttpHandler) { Timeout = TimeSpan.FromSeconds(10) };
coverHttpClient.DefaultRequestHeaders.Referrer = new Uri("https://music.126.net/");

void Log(string category, string message, bool verboseOnly = false)
{
    if (verboseOnly && !settings.VerboseLogging)
    {
        return;
    }

    var line = $"[{DateTimeOffset.Now:HH:mm:ss}] [{category}] {message}";
    Console.WriteLine(line);
    try { logFile?.WriteLine(line); } catch { }
}

string SummarizeMusicStatus(MusicPlaybackSnapshot? snapshot)
{
    if (snapshot is null)
    {
        return "music=null";
    }

    return string.Join(" ",
    [
        $"state={snapshot.PlaybackState}",
        $"title={(string.IsNullOrWhiteSpace(snapshot.Title) ? "<null>" : snapshot.Title)}",
        $"artist={(string.IsNullOrWhiteSpace(snapshot.Artist) ? "<null>" : snapshot.Artist)}",
        $"trackId={(string.IsNullOrWhiteSpace(snapshot.TrackId) ? "<null>" : snapshot.TrackId)}",
        $"pos={(snapshot.PositionSeconds?.ToString("0.0") ?? "<null>")}",
        $"dur={(snapshot.DurationSeconds?.ToString("0.0") ?? "<null>")}",
        $"vol={(snapshot.VolumePercent?.ToString() ?? "<null>")}",
        $"liked={(snapshot.IsLiked?.ToString() ?? "<null>")}",
        $"lyric={(string.IsNullOrWhiteSpace(snapshot.Lyric) ? "none" : $"{snapshot.Lyric!.Length} chars")}",
        $"cover={(string.IsNullOrWhiteSpace(snapshot.CoverImgUrl) ? "none" : snapshot.CoverImgUrl)}"
    ]);
}

string SummarizeStatusPayload(DeviceStatusMessage status)
{
    return string.Join(" ",
    [
        $"host={status.HostAddress}:{status.HostPort}",
        $"clients={clients.Count}",
        $"title={(string.IsNullOrWhiteSpace(status.MusicTitle) ? "<null>" : status.MusicTitle)}",
        $"artist={(string.IsNullOrWhiteSpace(status.MusicArtist) ? "<null>" : status.MusicArtist)}",
        $"state={(string.IsNullOrWhiteSpace(status.MusicPlaybackState) ? "<null>" : status.MusicPlaybackState)}",
        $"trackId={(string.IsNullOrWhiteSpace(status.MusicTrackId) ? "<null>" : status.MusicTrackId)}",
        $"lyric={(string.IsNullOrWhiteSpace(status.MusicLyric) ? "none" : $"{status.MusicLyric.Length} chars")}",
        $"cover={(string.IsNullOrWhiteSpace(status.MusicCoverImgUrl) ? "none" : status.MusicCoverImgUrl)}"
    ]);
}

var builder = WebApplication.CreateSlimBuilder(args);
builder.WebHost.UseUrls($"http://0.0.0.0:{settings.WebSocketPort}");

var app = builder.Build();
app.UseWebSockets();

app.MapGet("/health", () => Results.Json(new
{
    status = "ok",
    deviceName = settings.GetDeviceName(),
    protocolVersion = Protocol.Version,
    clientCount = clients.Count,
    sampleIntervalMs = settings.SampleIntervalMs,
    lastBroadcastUtc = runtime.LastBroadcastUtc,
    lastSnapshotUtc = runtime.LastSnapshot?.TimestampUtc
}));

app.MapGet("/snapshot", () =>
{
    return runtime.LastSnapshot is null
        ? Results.NoContent()
        : Results.Json(runtime.LastSnapshot, jsonOptions);
});

app.MapGet("/settings", () => Results.Json(settings, jsonOptions));

// 封面图片代理：手机端通过 PC 获取网易云 CDN 封面，避免手机直连外网的网络问题
app.MapGet("/cover", async (HttpContext context) =>
{
    var url = context.Request.Query["url"].FirstOrDefault();
    if (string.IsNullOrWhiteSpace(url))
    {
        context.Response.StatusCode = StatusCodes.Status400BadRequest;
        await context.Response.WriteAsync("missing url parameter");
        return;
    }

    // SSRF 防护：仅允许网易云 CDN 域名。原来全 URL 放行，攻击者可让
    // PC 代发请求到内网（http://192.168.x.x/admin、http://localhost:xxx）
    // 探测内网服务或外发拷贝数据。
    if (!Uri.TryCreate(url, UriKind.Absolute, out var parsedUri) ||
        (parsedUri.Scheme != Uri.UriSchemeHttp && parsedUri.Scheme != Uri.UriSchemeHttps) ||
        !IsAllowedCoverHost(parsedUri.Host))
    {
        Log("COVER", $"Reject disallowed url: {TruncUrl(url, 80)}");
        context.Response.StatusCode = StatusCodes.Status400BadRequest;
        await context.Response.WriteAsync("disallowed url");
        return;
    }

    try
    {
        var response = await coverHttpClient.GetAsync(parsedUri, HttpCompletionOption.ResponseHeadersRead, cts.Token);
        if (!response.IsSuccessStatusCode)
        {
            Log("COVER", $"Proxy fetch failed: url={TruncUrl(url, 80)} status={response.StatusCode}");
            context.Response.StatusCode = (int)response.StatusCode;
            return;
        }

        var contentType = response.Content.Headers.ContentType?.MediaType ?? "image/jpeg";
        context.Response.ContentType = contentType;
        context.Response.Headers.CacheControl = "public, max-age=86400";
        // 直接 stream copy，避免一次性 ReadAsByteArray 把大图缓进 LOH。
        await using var src = await response.Content.ReadAsStreamAsync(cts.Token);
        await src.CopyToAsync(context.Response.Body, cts.Token);
        Log("COVER", $"Proxy fetch ok: url={TruncUrl(url, 80)} type={contentType}", verboseOnly: true);
    }
    catch (Exception ex)
    {
        Log("COVER", $"Proxy fetch error: url={TruncUrl(url, 80)} {ex.GetType().Name}: {ex.Message}");
        context.Response.StatusCode = StatusCodes.Status502BadGateway;
    }
});

static bool IsAllowedCoverHost(string host)
{
    // 网易云封面 CDN 主域：p1.music.126.net / p2.music.126.net / y.music.126.net 等。
    // 留出 netease.com 兜底（部分历史 cover 走 nos.netease.com）。
    return host.EndsWith(".126.net", StringComparison.OrdinalIgnoreCase)
        || host.Equals("126.net", StringComparison.OrdinalIgnoreCase)
        || host.EndsWith(".netease.com", StringComparison.OrdinalIgnoreCase)
        || host.Equals("netease.com", StringComparison.OrdinalIgnoreCase);
}

app.Map("/ws", async context =>
{
    if (!context.WebSockets.IsWebSocketRequest)
    {
        context.Response.StatusCode = StatusCodes.Status400BadRequest;
        return;
    }

    using var socket = await context.WebSockets.AcceptWebSocketAsync();
    var clientId = Guid.NewGuid();
    var client = new WsClient(socket);
    clients[clientId] = client;
    var remoteIp = context.Connection.RemoteIpAddress?.ToString() ?? "unknown";
    var remotePort = context.Connection.RemotePort;
    Log("WS", $"Client connected: {clientId} from {remoteIp}:{remotePort} ({clients.Count} total)");

    if (runtime.LastSnapshot is not null)
    {
        Log("STATUS", $"Send cached snapshot to new client {clientId}: {SummarizeStatusPayload(runtime.LastSnapshot)}");
        await SendJsonAsync(client, runtime.LastSnapshot, jsonOptions, cts.Token);
    }

    try
    {
        var buffer = new byte[4096];
        var messageStream = new MemoryStream();
        while (!cts.Token.IsCancellationRequested && socket.State == WebSocketState.Open)
        {
            messageStream.SetLength(0);
            WebSocketReceiveResult result;
            do
            {
                result = await socket.ReceiveAsync(buffer, cts.Token);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    break;
                }
                messageStream.Write(buffer, 0, result.Count);
                // 单条消息上限 64KB：command 消息只有十几字节，超过这个量级一定是异常输入，主动断开避免无限累积。
                if (messageStream.Length > 64 * 1024)
                {
                    Log("WS", $"Oversized message from {clientId}, closing");
                    await socket.CloseAsync(WebSocketCloseStatus.MessageTooBig, "too big", CancellationToken.None);
                    return;
                }
            } while (!result.EndOfMessage);

            if (result.MessageType == WebSocketMessageType.Close)
            {
                Log("WS", $"Client requested close: {clientId}", verboseOnly: true);
                break;
            }

            if (result.MessageType == WebSocketMessageType.Text)
            {
                var text = Encoding.UTF8.GetString(messageStream.GetBuffer(), 0, (int)messageStream.Length);
                Log("WS", $"Recv text from {clientId}: {text}", verboseOnly: true);
                var command = CommandMessage.TryParse(text);
                if (command is null)
                {
                    Log("WS", $"Ignored unrecognized message from {clientId}", verboseOnly: true);
                    continue;
                }

                var sw = Stopwatch.StartNew();
                Log("CMD", $"Action requested: client={clientId} actionId={command.ActionId}" +
                    (command.Value is null ? "" : $" value={command.Value}"));
                var actionResult = await musicController.ExecuteActionAsync(command.ActionId, command.Value, cts.Token);
                sw.Stop();
                Log("CMD", $"Action result: client={clientId} actionId={actionResult.ActionId} ok={actionResult.Success} ms={sw.ElapsedMilliseconds} msg={actionResult.Message}");
                await SendJsonAsync(client, new CommandResultMessage(
                    MessageType: "commandResult",
                    ActionId: actionResult.ActionId,
                    Success: actionResult.Success,
                    Message: actionResult.Message,
                    TimestampUtc: DateTimeOffset.UtcNow), jsonOptions, cts.Token);

                // 状态推送靠 mediaService.StateChanged 事件驱动；这里不再 sleep-poll status command。
            }
        }
    }
    catch (OperationCanceledException)
    {
    }
    finally
    {
        clients.TryRemove(clientId, out _);
        if (socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
        {
            await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None);
        }

        Log("WS", $"Client disconnected: {clientId} ({clients.Count} total)");
    }
});

app.Lifetime.ApplicationStopping.Register(() => cts.Cancel());

// 事件驱动状态推送：MediaService 状态变化时立刻向所有 WS 客户端广播（<100ms 延迟）。
// 周期 broadcast loop 仍保留以同步 CPU/内存等系统指标。
mediaService.StateChanged += (_, _) =>
{
    if (runtime.LastSnapshot is null) return;
    var music = mediaService.SnapshotNow();
    var updated = runtime.LastSnapshot with
    {
        MusicTrackId = music.TrackId,
        MusicTitle = music.Title,
        MusicArtist = music.Artist,
        MusicPlaybackState = music.PlaybackState,
        MusicVolumePercent = music.VolumePercent,
        MusicPositionSeconds = music.PositionSeconds,
        MusicDurationSeconds = music.DurationSeconds,
        MusicIsLiked = music.IsLiked,
        MusicLyric = music.Lyric,
        MusicCoverImgUrl = music.CoverImgUrl,
        TimestampUtc = DateTimeOffset.UtcNow
    };
    runtime.LastSnapshot = updated;
    _ = Task.Run(async () =>
    {
        try { await BroadcastStatusAsync(clients, updated, jsonOptions, cts.Token); }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            Log("WS", $"StateChanged push failed: {ex.GetType().Name} {ex.Message}", verboseOnly: true);
        }
    });
};

var broadcastTask = Task.Run(async () =>
{
    using var udp = new UdpClient { EnableBroadcast = true };
    Log("BOOT", $"Device        : {settings.GetDeviceName()}");
    Log("BOOT", $"HTTP/WebSocket: ws://0.0.0.0:{settings.WebSocketPort}/ws");
    Log("BOOT", $"UDP broadcast : {settings.BroadcastPort} enabled={settings.EnableBroadcastDiscovery}");
    Log("BOOT", $"Sample every  : {settings.SampleIntervalMs} ms");
    Log("BOOT", $"VerboseLogging: {settings.VerboseLogging}");
    Log("BOOT", "Press Ctrl+C to stop.");

    var lastBroadcastLogAt = DateTimeOffset.MinValue;

    while (!cts.Token.IsCancellationRequested)
    {
        try
        {
            var snapshot = sampler.Sample();
            var music = mediaService.SnapshotNow();
            Log("STATUS", $"Sampled runtime snapshot host={snapshot.HostAddress} cpu={snapshot.CpuUsagePercent}% mem={snapshot.MemoryUsedPercent}% top={snapshot.TopProcessName} music={SummarizeMusicStatus(music)}", verboseOnly: true);
            var broadcastTargets = NetworkDiscovery.ResolveBroadcastTargets(snapshot.HostAddress);
            var status = new DeviceStatusMessage(
                MessageType: "status",
                ProtocolVersion: Protocol.Version,
                DeviceName: settings.GetDeviceName(),
                HostAddress: snapshot.HostAddress,
                HostPort: settings.WebSocketPort,
                CpuUsagePercent: snapshot.CpuUsagePercent,
                MemoryUsedGb: snapshot.MemoryUsedGb,
                MemoryTotalGb: snapshot.MemoryTotalGb,
                MemoryUsedPercent: snapshot.MemoryUsedPercent,
                UptimeMinutes: snapshot.UptimeMinutes,
                ActiveProcessName: snapshot.TopProcessName,
                TopProcessCpuPercent: snapshot.TopProcessCpuPercent,
                NetworkReceiveMbps: snapshot.NetworkReceiveMbps,
                NetworkSendMbps: snapshot.NetworkSendMbps,
                SystemDriveUsedGb: snapshot.SystemDriveUsedGb,
                SystemDriveFreeGb: snapshot.SystemDriveFreeGb,
                ProcessorCount: snapshot.ProcessorCount,
                OsVersion: snapshot.OsVersion,
                MusicTrackId: music?.TrackId,
                MusicTitle: music?.Title,
                MusicArtist: music?.Artist,
                MusicPlaybackState: music?.PlaybackState,
                MusicVolumePercent: music?.VolumePercent,
                MusicPositionSeconds: music?.PositionSeconds,
                MusicDurationSeconds: music?.DurationSeconds,
                MusicIsLiked: music?.IsLiked,
                MusicLyric: music?.Lyric,
                MusicCoverImgUrl: music?.CoverImgUrl,
                TimestampUtc: DateTimeOffset.UtcNow);

            runtime.LastSnapshot = status;
            runtime.LastBroadcastUtc = DateTimeOffset.UtcNow;
            Log("STATUS", $"Prepared status payload: {SummarizeStatusPayload(status)} targets={broadcastTargets.Count}", verboseOnly: true);

            var discovery = new DiscoveryMessage(
                ProtocolVersion: status.ProtocolVersion,
                DeviceName: status.DeviceName,
                HostAddress: status.HostAddress,
                HostPort: status.HostPort,
                Endpoint: $"ws://{status.HostAddress}:{status.HostPort}/ws",
                Capabilities: new[]
                {
                    "cpu",
                    "memory",
                    "network",
                    "disk",
                    "top-process"
                },
                TimestampUtc: status.TimestampUtc);

            if (settings.EnableBroadcastDiscovery)
            {
                foreach (var target in broadcastTargets)
                {
                    var discoveryForTarget = discovery with
                    {
                        HostAddress = target.HostAddress,
                        Endpoint = $"ws://{target.HostAddress}:{status.HostPort}/ws"
                    };
                    var discoveryBytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(discoveryForTarget, jsonOptions));
                    var endpoint = new IPEndPoint(target.BroadcastAddress, settings.BroadcastPort);
                    await udp.SendAsync(discoveryBytes, endpoint, cts.Token);
                }

                if (settings.VerboseLogging && (DateTimeOffset.UtcNow - lastBroadcastLogAt) > TimeSpan.FromSeconds(20))
                {
                    lastBroadcastLogAt = DateTimeOffset.UtcNow;
                    Log("UDP", $"Broadcasted discovery to {broadcastTargets.Count} target(s). host={snapshot.HostAddress}:{settings.WebSocketPort}");
                }
            }

            foreach (var pair in clients.ToArray())
            {
                if (pair.Value.Socket.State != WebSocketState.Open)
                {
                    clients.TryRemove(pair.Key, out _);
                    continue;
                }

                try
                {
                    Log("STATUS", $"Push status to client {pair.Key}: {SummarizeStatusPayload(status)}", verboseOnly: true);
                    await SendJsonAsync(pair.Value, status, jsonOptions, cts.Token);
                }
                catch (Exception ex)
                {
                    Log("WS", $"Push failed for client {pair.Key}: {ex.GetType().Name} {ex.Message}", verboseOnly: true);
                    clients.TryRemove(pair.Key, out _);
                }
            }
        }
        catch (OperationCanceledException) when (cts.Token.IsCancellationRequested)
        {
            break;
        }
        catch (Exception ex)
        {
            // 单次迭代失败不应让整条 broadcast loop 静默退出，否则 app 端永远收不到 status
            // 也察觉不到 PC agent 还活着——心跳/重连机制无意义。日志记录后下一轮继续。
            Log("STATUS", $"Broadcast iteration failed: {ex.GetType().Name} {ex.Message}");
        }

        try
        {
            await Task.Delay(settings.SampleIntervalMs, cts.Token);
        }
        catch (OperationCanceledException)
        {
            break;
        }
    }
}, cts.Token);

await app.RunAsync(cts.Token);
await broadcastTask;
await trayService.StopAsync(CancellationToken.None);
trayService.Dispose();
mediaService.Dispose();
neteaseClient.Dispose();
coverHttpClient.Dispose();
logFile?.Dispose();
singleInstanceMutex.ReleaseMutex();
singleInstanceMutex.Dispose();

static string TruncUrl(string? value, int max = 120) =>
    string.IsNullOrWhiteSpace(value) ? "<null>" : (value.Length <= max ? value : value[..max] + "...");

static async Task SendJsonAsync(WsClient client, object payload, JsonSerializerOptions jsonOptions, CancellationToken cancellationToken)
{
    var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload, jsonOptions));
    // WebSocket.SendAsync 不允许并发：周期 broadcast、StateChanged 事件、命令 ack
    // 三条路径都会写同一 socket，必须 per-client semaphore 串行化，否则抛
    // InvalidOperationException 并把链路打断。
    await client.WriteLock.WaitAsync(cancellationToken);
    try
    {
        if (client.Socket.State != WebSocketState.Open) return;
        await client.Socket.SendAsync(bytes, WebSocketMessageType.Text, true, cancellationToken);
    }
    finally
    {
        client.WriteLock.Release();
    }
}

static async Task BroadcastStatusAsync(
    ConcurrentDictionary<Guid, WsClient> clients,
    DeviceStatusMessage payload,
    JsonSerializerOptions jsonOptions,
    CancellationToken cancellationToken)
{
    foreach (var pair in clients.ToArray())
    {
        if (pair.Value.Socket.State != WebSocketState.Open)
        {
            clients.TryRemove(pair.Key, out _);
            continue;
        }

        try
        {
            await SendJsonAsync(pair.Value, payload, jsonOptions, cancellationToken);
        }
        catch
        {
            clients.TryRemove(pair.Key, out _);
        }
    }
}

internal sealed class WsClient
{
    public WsClient(WebSocket socket)
    {
        Socket = socket;
    }

    public WebSocket Socket { get; }
    // WebSocket.SendAsync 单实例并发即抛 InvalidOperationException 并永久打断链路。
    // 周期 broadcast / StateChanged 事件 / 命令 ack 三条路径都会写同一 socket，
    // 必须 per-client semaphore 串行化。
    public SemaphoreSlim WriteLock { get; } = new(1, 1);
}

internal static class Protocol
{
    public const int Version = 2;
}

internal sealed record AgentSettings(
    string? DeviceAlias,
    int BroadcastPort,
    int WebSocketPort,
    int SampleIntervalMs,
    bool EnableBroadcastDiscovery,
    bool VerboseLogging)
{
    public static AgentSettings Load(string[] args)
    {
        var defaults = new AgentSettings(
            DeviceAlias: null,
            BroadcastPort: 50570,
            WebSocketPort: 50571,
            SampleIntervalMs: 1000,
            EnableBroadcastDiscovery: true,
            VerboseLogging: false);

        var settingsPath = ResolveSettingsPath(args);
        if (!File.Exists(settingsPath))
        {
            var seedJson = JsonSerializer.Serialize(defaults, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(settingsPath, seedJson);
            return defaults;
        }

        try
        {
            var json = File.ReadAllText(settingsPath);
            var fileSettings = JsonSerializer.Deserialize<AgentSettings>(
                json,
                new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                });
            return fileSettings is null
                ? defaults
                : defaults with
                {
                    DeviceAlias = string.IsNullOrWhiteSpace(fileSettings.DeviceAlias) ? defaults.DeviceAlias : fileSettings.DeviceAlias,
                    BroadcastPort = fileSettings.BroadcastPort == 0 ? defaults.BroadcastPort : fileSettings.BroadcastPort,
                    WebSocketPort = fileSettings.WebSocketPort == 0 ? defaults.WebSocketPort : fileSettings.WebSocketPort,
                    SampleIntervalMs = fileSettings.SampleIntervalMs == 0 ? defaults.SampleIntervalMs : Math.Max(250, fileSettings.SampleIntervalMs),
                    EnableBroadcastDiscovery = fileSettings.EnableBroadcastDiscovery,
                    VerboseLogging = fileSettings.VerboseLogging
                };
        }
        catch
        {
            return defaults;
        }
    }

    public string GetDeviceName()
    {
        return string.IsNullOrWhiteSpace(DeviceAlias) ? Environment.MachineName : DeviceAlias;
    }

    private static string ResolveSettingsPath(string[] args)
    {
        // 旧版用 args.Chunk(2) 取 --settings，把数组按 [0,1][2,3]... 切片；只要在 --settings 前
        // 多了任何一个 odd-position 参数（典型场景：宿主里塞一个 exe 路径占位），就会切到
        // [prev,--settings][value,...] 错位，整条选项被无声跳过，写入默认 agentsettings.json
        // 路径。改成顺序扫描，--settings 在任何位置都拿得到，且越界配对会被显式拒绝。
        for (var i = 0; i < args.Length - 1; i++)
        {
            if (args[i].Equals("--settings", StringComparison.OrdinalIgnoreCase))
            {
                return Path.GetFullPath(args[i + 1]);
            }
        }

        return Path.Combine(AppContext.BaseDirectory, "agentsettings.json");
    }
}

internal sealed class AgentRuntimeState
{
    public DeviceStatusMessage? LastSnapshot { get; set; }
    public DateTimeOffset? LastBroadcastUtc { get; set; }
}

internal sealed class SnapshotSampler
{
    private readonly Dictionary<int, TimeSpan> _lastProcessCpu = new();
    private readonly Dictionary<string, InterfaceBytes> _lastInterfaceBytes = new();
    private CpuTimes _lastCpuTimes = CpuTimes.Read();
    private DateTimeOffset _lastSampleAt = DateTimeOffset.UtcNow;
    // Process.GetProcesses() 每次会 OpenHandle + GetTotalProcessorTime 全机进程，
    // 在每秒一次的采样里是最贵的一笔（实测可达数十 ms / 几百次 syscall）。
    // top 进程只用作 UI 标签，3 秒刷新足够；其它 CPU/网/盘指标仍保持 1Hz。
    private static readonly TimeSpan TopProcessInterval = TimeSpan.FromSeconds(3);
    private (string Name, double CpuPercent) _topProcessCache = ("idle", 0d);
    private DateTimeOffset _topProcessLastSampledAt = DateTimeOffset.MinValue;

    public SampleResult Sample()
    {
        var now = DateTimeOffset.UtcNow;
        var elapsedSeconds = Math.Max((now - _lastSampleAt).TotalSeconds, 0.001);

        var currentCpuTimes = CpuTimes.Read();
        var cpuUsage = CpuTimes.CalculateUsage(_lastCpuTimes, currentCpuTimes);
        _lastCpuTimes = currentCpuTimes;

        var memoryStatus = MemoryStatus.Read();
        var totalMemoryGb = memoryStatus.TotalPhysicalMemory / 1024d / 1024d / 1024d;
        var freeMemoryGb = memoryStatus.AvailablePhysicalMemory / 1024d / 1024d / 1024d;
        var usedMemoryGb = totalMemoryGb - freeMemoryGb;

        var topProcess = MaybeRefreshTopProcess(now);
        var network = SampleNetwork(elapsedSeconds);
        var disk = SampleSystemDrive();

        _lastSampleAt = now;

        var primaryHostAddress = NetworkDiscovery.ResolvePrimaryHostAddress() ?? "127.0.0.1";

        return new SampleResult(
            CpuUsagePercent: Math.Round(cpuUsage, 1),
            MemoryUsedGb: Math.Round(usedMemoryGb, 1),
            MemoryTotalGb: Math.Round(totalMemoryGb, 1),
            MemoryUsedPercent: totalMemoryGb <= 0 ? 0 : Math.Round(usedMemoryGb / totalMemoryGb * 100d, 1),
            UptimeMinutes: Environment.TickCount64 / 60000,
            TopProcessName: topProcess.Name,
            TopProcessCpuPercent: Math.Round(topProcess.CpuPercent, 1),
            HostAddress: primaryHostAddress,
            NetworkReceiveMbps: Math.Round(network.ReceiveMbps, 2),
            NetworkSendMbps: Math.Round(network.SendMbps, 2),
            SystemDriveUsedGb: Math.Round(disk.UsedGb, 1),
            SystemDriveFreeGb: Math.Round(disk.FreeGb, 1),
            ProcessorCount: Environment.ProcessorCount,
            OsVersion: RuntimeInformation.OSDescription);
    }

    private (string Name, double CpuPercent) MaybeRefreshTopProcess(DateTimeOffset now)
    {
        if (now - _topProcessLastSampledAt < TopProcessInterval) return _topProcessCache;
        // 第一次走默认 1s 假窗口（_lastProcessCpu 也空，结果都会被 continue 跳掉），第二次起
        // 用实际窗口计算 CPU%。
        var elapsed = _topProcessLastSampledAt == DateTimeOffset.MinValue
            ? 1.0
            : Math.Max((now - _topProcessLastSampledAt).TotalSeconds, 0.001);
        _topProcessCache = SampleTopProcess(elapsed);
        _topProcessLastSampledAt = now;
        return _topProcessCache;
    }

    private (string Name, double CpuPercent) SampleTopProcess(double elapsedSeconds)
    {
        var nextCpuMap = new Dictionary<int, TimeSpan>();
        string topName = "idle";
        double topCpu = 0d;

        foreach (var process in Process.GetProcesses())
        {
            try
            {
                nextCpuMap[process.Id] = process.TotalProcessorTime;
                if (!_lastProcessCpu.TryGetValue(process.Id, out var previousCpu))
                {
                    continue;
                }

                var deltaSeconds = Math.Max((process.TotalProcessorTime - previousCpu).TotalSeconds, 0);
                var cpuPercent = deltaSeconds / (elapsedSeconds * Environment.ProcessorCount) * 100d;
                if (cpuPercent > topCpu && !string.IsNullOrWhiteSpace(process.ProcessName))
                {
                    topCpu = cpuPercent;
                    topName = process.ProcessName;
                }
            }
            catch
            {
            }
            finally
            {
                process.Dispose();
            }
        }

        _lastProcessCpu.Clear();
        foreach (var pair in nextCpuMap)
        {
            _lastProcessCpu[pair.Key] = pair.Value;
        }

        return (topName, topCpu);
    }

    private (double ReceiveMbps, double SendMbps) SampleNetwork(double elapsedSeconds)
    {
        double receiveBytes = 0;
        double sendBytes = 0;
        var current = new Dictionary<string, InterfaceBytes>();

        foreach (var networkInterface in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (networkInterface.OperationalStatus != OperationalStatus.Up ||
                networkInterface.NetworkInterfaceType == NetworkInterfaceType.Loopback)
            {
                continue;
            }

            try
            {
                var stats = networkInterface.GetIPv4Statistics();
                var key = networkInterface.Id;
                var snapshot = new InterfaceBytes(stats.BytesReceived, stats.BytesSent);
                current[key] = snapshot;

                if (_lastInterfaceBytes.TryGetValue(key, out var previous))
                {
                    receiveBytes += Math.Max(snapshot.BytesReceived - previous.BytesReceived, 0);
                    sendBytes += Math.Max(snapshot.BytesSent - previous.BytesSent, 0);
                }
            }
            catch
            {
            }
        }

        _lastInterfaceBytes.Clear();
        foreach (var pair in current)
        {
            _lastInterfaceBytes[pair.Key] = pair.Value;
        }

        return (
            ReceiveMbps: receiveBytes * 8d / 1_000_000d / elapsedSeconds,
            SendMbps: sendBytes * 8d / 1_000_000d / elapsedSeconds);
    }

    private static (double UsedGb, double FreeGb) SampleSystemDrive()
    {
        try
        {
            var systemRoot = Path.GetPathRoot(Environment.SystemDirectory);
            if (string.IsNullOrWhiteSpace(systemRoot))
            {
                return (0, 0);
            }

            var drive = new DriveInfo(systemRoot);
            if (!drive.IsReady)
            {
                return (0, 0);
            }

            var freeGb = drive.AvailableFreeSpace / 1024d / 1024d / 1024d;
            var usedGb = (drive.TotalSize - drive.AvailableFreeSpace) / 1024d / 1024d / 1024d;
            return (usedGb, freeGb);
        }
        catch
        {
            return (0, 0);
        }
    }
}

internal static class NetworkDiscovery
{
    public static string? ResolvePrimaryHostAddress()
    {
        return EnumerateCandidates()
            .Select(candidate => candidate.HostAddress)
            .FirstOrDefault();
    }

    public static IReadOnlyList<BroadcastTarget> ResolveBroadcastTargets(string fallbackHostAddress)
    {
        var targets = EnumerateCandidates()
            .DistinctBy(candidate => $"{candidate.HostAddress}/{candidate.BroadcastAddress}")
            .ToList();

        if (targets.Count > 0)
        {
            return targets;
        }

        return new[]
        {
            new BroadcastTarget(
                HostAddress: fallbackHostAddress,
                BroadcastAddress: IPAddress.Broadcast)
        };
    }

    private static IEnumerable<BroadcastTarget> EnumerateCandidates()
    {
        foreach (var networkInterface in NetworkInterface.GetAllNetworkInterfaces()
                     .Where(IsViableInterface)
                     .OrderByDescending(HasIpv4Gateway)
                     .ThenByDescending(networkInterface => networkInterface.NetworkInterfaceType == NetworkInterfaceType.Wireless80211)
                     .ThenByDescending(networkInterface => networkInterface.NetworkInterfaceType == NetworkInterfaceType.Ethernet))
        {
            IPInterfaceProperties properties;
            try
            {
                properties = networkInterface.GetIPProperties();
            }
            catch
            {
                continue;
            }

            foreach (var addressInfo in properties.UnicastAddresses)
            {
                if (addressInfo.Address.AddressFamily != AddressFamily.InterNetwork ||
                    IPAddress.IsLoopback(addressInfo.Address))
                {
                    continue;
                }

                var broadcastAddress = TryResolveBroadcastAddress(addressInfo) ?? IPAddress.Broadcast;
                yield return new BroadcastTarget(
                    HostAddress: addressInfo.Address.ToString(),
                    BroadcastAddress: broadcastAddress);
            }
        }
    }

    private static bool IsViableInterface(NetworkInterface networkInterface)
    {
        return networkInterface.OperationalStatus == OperationalStatus.Up &&
               networkInterface.NetworkInterfaceType is not NetworkInterfaceType.Loopback and not NetworkInterfaceType.Tunnel &&
               !networkInterface.Description.Contains("Virtual", StringComparison.OrdinalIgnoreCase);
    }

    private static bool HasIpv4Gateway(NetworkInterface networkInterface)
    {
        try
        {
            return networkInterface.GetIPProperties().GatewayAddresses
                .Any(gateway => gateway.Address.AddressFamily == AddressFamily.InterNetwork &&
                                !gateway.Address.Equals(IPAddress.Any));
        }
        catch
        {
            return false;
        }
    }

    private static IPAddress? TryResolveBroadcastAddress(UnicastIPAddressInformation addressInfo)
    {
        var mask = addressInfo.IPv4Mask;
        if (mask is null)
        {
            return null;
        }

        var addressBytes = addressInfo.Address.GetAddressBytes();
        var maskBytes = mask.GetAddressBytes();
        if (addressBytes.Length != maskBytes.Length)
        {
            return null;
        }

        var broadcastBytes = new byte[addressBytes.Length];
        for (var index = 0; index < addressBytes.Length; index++)
        {
            broadcastBytes[index] = (byte)(addressBytes[index] | ~maskBytes[index]);
        }

        return new IPAddress(broadcastBytes);
    }
}

internal readonly record struct InterfaceBytes(long BytesReceived, long BytesSent);
internal readonly record struct BroadcastTarget(string HostAddress, IPAddress BroadcastAddress);

internal readonly record struct CpuTimes(ulong Idle, ulong Kernel, ulong User)
{
    public static CpuTimes Read()
    {
        if (!GetSystemTimes(out var idleTime, out var kernelTime, out var userTime))
        {
            return new CpuTimes(0, 0, 0);
        }

        return new CpuTimes(
            Idle: ToUInt64(idleTime),
            Kernel: ToUInt64(kernelTime),
            User: ToUInt64(userTime));
    }

    public static double CalculateUsage(CpuTimes previous, CpuTimes current)
    {
        var idle = current.Idle - previous.Idle;
        var kernel = current.Kernel - previous.Kernel;
        var user = current.User - previous.User;
        var total = kernel + user;

        if (total == 0)
        {
            return 0;
        }

        var busy = total - idle;
        return Math.Clamp((double)busy / total * 100d, 0d, 100d);
    }

    private static ulong ToUInt64(FILETIME time)
    {
        return ((ulong)time.dwHighDateTime << 32) | time.dwLowDateTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemTimes(
        out FILETIME lpIdleTime,
        out FILETIME lpKernelTime,
        out FILETIME lpUserTime);
}

internal readonly record struct MemoryStatus(ulong TotalPhysicalMemory, ulong AvailablePhysicalMemory)
{
    public static MemoryStatus Read()
    {
        var native = new MEMORYSTATUSEX
        {
            dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>()
        };

        if (!GlobalMemoryStatusEx(ref native))
        {
            return new MemoryStatus(0, 0);
        }

        return new MemoryStatus(native.ullTotalPhys, native.ullAvailPhys);
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);
}

[StructLayout(LayoutKind.Sequential)]
internal readonly struct FILETIME
{
    public readonly uint dwLowDateTime;
    public readonly uint dwHighDateTime;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
internal struct MEMORYSTATUSEX
{
    public uint dwLength;
    public uint dwMemoryLoad;
    public ulong ullTotalPhys;
    public ulong ullAvailPhys;
    public ulong ullTotalPageFile;
    public ulong ullAvailPageFile;
    public ulong ullTotalVirtual;
    public ulong ullAvailVirtual;
    public ulong ullAvailExtendedVirtual;
}

internal sealed record SampleResult(
    double CpuUsagePercent,
    double MemoryUsedGb,
    double MemoryTotalGb,
    double MemoryUsedPercent,
    long UptimeMinutes,
    string TopProcessName,
    double TopProcessCpuPercent,
    string HostAddress,
    double NetworkReceiveMbps,
    double NetworkSendMbps,
    double SystemDriveUsedGb,
    double SystemDriveFreeGb,
    int ProcessorCount,
    string OsVersion);

internal sealed record DiscoveryMessage(
    int ProtocolVersion,
    string DeviceName,
    string HostAddress,
    int HostPort,
    string Endpoint,
    IReadOnlyList<string> Capabilities,
    DateTimeOffset TimestampUtc);

internal sealed record DeviceStatusMessage(
    string MessageType,
    int ProtocolVersion,
    string DeviceName,
    string HostAddress,
    int HostPort,
    double CpuUsagePercent,
    double MemoryUsedGb,
    double MemoryTotalGb,
    double MemoryUsedPercent,
    long UptimeMinutes,
    string ActiveProcessName,
    double TopProcessCpuPercent,
    double NetworkReceiveMbps,
    double NetworkSendMbps,
    double SystemDriveUsedGb,
    double SystemDriveFreeGb,
    int ProcessorCount,
    string OsVersion,
    string? MusicTrackId,
    string? MusicTitle,
    string? MusicArtist,
    string? MusicPlaybackState,
    int? MusicVolumePercent,
    double? MusicPositionSeconds,
    double? MusicDurationSeconds,
    bool? MusicIsLiked,
    string? MusicLyric,
    string? MusicCoverImgUrl,
    DateTimeOffset TimestampUtc);

internal sealed record CommandResultMessage(
    string MessageType,
    string ActionId,
    bool Success,
    string Message,
    DateTimeOffset TimestampUtc);

internal sealed record CommandMessage(string ActionId, int? Value)
{
    public static CommandMessage? TryParse(string text)
    {
        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (!root.TryGetProperty("messageType", out var messageType) ||
                !string.Equals(messageType.GetString(), "command", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            if (!root.TryGetProperty("actionId", out var actionId) || string.IsNullOrWhiteSpace(actionId.GetString()))
            {
                return null;
            }

            int? value = null;
            if (root.TryGetProperty("value", out var valueEl) &&
                valueEl.ValueKind == JsonValueKind.Number &&
                valueEl.TryGetInt32(out var parsedValue))
            {
                value = parsedValue;
            }

            return new CommandMessage(actionId.GetString()!, value);
        }
        catch
        {
            return null;
        }
    }
}
