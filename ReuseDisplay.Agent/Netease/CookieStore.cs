using System.Text.Json;

namespace ReuseDisplay.Agent.Netease;

internal sealed class CookieEntry
{
    public string Name { get; set; } = "";
    public string Value { get; set; } = "";
    public string Path { get; set; } = "/";
    public string Domain { get; set; } = "music.163.com";
    public bool Secure { get; set; }
    public bool HttpOnly { get; set; }
    public string? Expires { get; set; }
    public string? MaxAge { get; set; }
    public string? SameSite { get; set; }
}

/// <summary>
/// 文件持久化 cookie store。兼容 netease-api-analysis 的 cookies.json 格式。
/// 用 UseCookies=false 的 HttpClientHandler 配合手动管 Cookie 头，
/// 避免 .NET 自带 CookieContainer 对 domain/path 的过严校验把 MUSIC_U 丢掉。
/// </summary>
internal sealed class CookieStore : IDisposable
{
    private const int SaveDebounceMs = 250;

    private readonly string _filePath;
    private readonly Dictionary<string, CookieEntry> _cookies = new(StringComparer.Ordinal);
    private readonly object _lock = new();
    private readonly System.Threading.Timer _saveTimer;
    private int _savePending;

    public string FilePath => _filePath;

    public CookieStore(string filePath)
    {
        _filePath = filePath;
        _saveTimer = new System.Threading.Timer(_ => FlushIfPending(), null, Timeout.Infinite, Timeout.Infinite);
        Load();
    }

    public void Dispose()
    {
        FlushIfPending();
        _saveTimer.Dispose();
    }

    private void Load()
    {
        if (!File.Exists(_filePath)) return;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(_filePath));
            if (!doc.RootElement.TryGetProperty("cookies", out var arr) ||
                arr.ValueKind != JsonValueKind.Array)
            {
                return;
            }
            foreach (var entry in arr.EnumerateArray())
            {
                var ck = new CookieEntry();
                if (entry.TryGetProperty("name", out var n)) ck.Name = n.GetString() ?? "";
                if (string.IsNullOrEmpty(ck.Name)) continue;
                if (entry.TryGetProperty("value", out var v)) ck.Value = v.GetString() ?? "";
                if (entry.TryGetProperty("path", out var p)) ck.Path = p.GetString() ?? "/";
                if (entry.TryGetProperty("domain", out var d)) ck.Domain = d.GetString() ?? "music.163.com";
                if (entry.TryGetProperty("secure", out var s) && s.ValueKind == JsonValueKind.True) ck.Secure = true;
                if (entry.TryGetProperty("httpOnly", out var h) && h.ValueKind == JsonValueKind.True) ck.HttpOnly = true;
                if (entry.TryGetProperty("expires", out var e) && e.ValueKind == JsonValueKind.String) ck.Expires = e.GetString();
                if (entry.TryGetProperty("maxAge", out var m) && m.ValueKind == JsonValueKind.String) ck.MaxAge = m.GetString();
                if (entry.TryGetProperty("sameSite", out var ss) && ss.ValueKind == JsonValueKind.String) ck.SameSite = ss.GetString();
                _cookies[ck.Name] = ck;
            }
        }
        catch
        {
            // 损坏的 cookie 文件忽略，等下次 save 时覆盖
        }
    }

    public void Save()
    {
        lock (_lock)
        {
            WriteToDisk();
            Interlocked.Exchange(ref _savePending, 0);
        }
    }

    private void RequestSave()
    {
        Interlocked.Exchange(ref _savePending, 1);
        _saveTimer.Change(SaveDebounceMs, Timeout.Infinite);
    }

    private void FlushIfPending()
    {
        if (Interlocked.Exchange(ref _savePending, 0) == 0) return;
        lock (_lock) WriteToDisk();
    }

    private void WriteToDisk()
    {
        var dir = Path.GetDirectoryName(_filePath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var sorted = _cookies.Values.OrderBy(c => c.Name, StringComparer.Ordinal).ToArray();
        var json = JsonSerializer.Serialize(new { cookies = sorted }, new JsonSerializerOptions
        {
            WriteIndented = true,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        });
        // 原子写：先写 .tmp 再 Move，避免 WriteAllText 写到一半（OS crash / 进程被 kill）
        // 时把 cookies.json 截断成空文件，导致下次启动 MUSIC_U 丢失被迫重新扫码。
        var tmp = _filePath + ".tmp";
        File.WriteAllText(tmp, json);
        File.Move(tmp, _filePath, overwrite: true);
    }

    public void SetFromHeader(string setCookieValue)
    {
        var segments = setCookieValue.Split(';');
        if (segments.Length == 0) return;
        var nameValue = segments[0].Trim();
        var eq = nameValue.IndexOf('=');
        if (eq <= 0) return;

        var cookie = new CookieEntry
        {
            Name = nameValue.Substring(0, eq),
            Value = nameValue.Substring(eq + 1)
        };

        for (int i = 1; i < segments.Length; i++)
        {
            var attr = segments[i].Trim();
            var ae = attr.IndexOf('=');
            var key = (ae > 0 ? attr.Substring(0, ae) : attr).ToLowerInvariant();
            var val = ae > 0 ? attr.Substring(ae + 1) : "";
            switch (key)
            {
                case "path": cookie.Path = val; break;
                case "domain": cookie.Domain = val; break;
                case "secure": cookie.Secure = true; break;
                case "httponly": cookie.HttpOnly = true; break;
                case "expires": cookie.Expires = val; break;
                case "max-age": cookie.MaxAge = val; break;
                case "samesite": cookie.SameSite = val; break;
            }
        }
        lock (_lock)
        {
            _cookies[cookie.Name] = cookie;
        }
    }

    /// <summary>
    /// 从 response Set-Cookie 头吸收新 cookie。.NET 的 HttpClientHandler 需要 UseCookies=false 才能让我们手动管。
    /// </summary>
    public void UpdateFromResponse(HttpResponseMessage response)
    {
        if (!response.Headers.TryGetValues("Set-Cookie", out var values)) return;
        var changed = false;
        foreach (var v in values)
        {
            SetFromHeader(v);
            changed = true;
        }
        if (changed) RequestSave();
    }

    public string GetCookieHeader()
    {
        lock (_lock)
        {
            if (_cookies.Count == 0) return string.Empty;
            return string.Join("; ", _cookies.Values.Select(c => $"{c.Name}={c.Value}"));
        }
    }

    public string? Get(string name)
    {
        lock (_lock)
        {
            return _cookies.TryGetValue(name, out var c) ? c.Value : null;
        }
    }

    public bool Has(string name)
    {
        lock (_lock)
        {
            return _cookies.TryGetValue(name, out var c) && !string.IsNullOrEmpty(c.Value);
        }
    }

    public void Clear()
    {
        lock (_lock) _cookies.Clear();
        Save();
    }
}
