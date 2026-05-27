using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Web;

namespace ReuseDisplay.Agent.Netease;

/// <summary>
/// 网易云 web 接口客户端，端口自 netease-api-analysis/src/client.js。
/// 只保留 MediaService 需要的端点（登录、播单、歌曲、心动、scrobble）。
/// </summary>
internal sealed class NeteaseClient : IDisposable
{
    private const string BaseUrl = "https://music.163.com";
    private const string WebUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36";
    private const string MobileUserAgent =
        "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)";

    private readonly HttpClient _http;
    private readonly SocketsHttpHandler _handler;

    public CookieStore Cookies { get; }

    public NeteaseClient(string? cookieFilePath = null)
        : this(new CookieStore(cookieFilePath ?? DefaultCookieFile()))
    {
    }

    public NeteaseClient(CookieStore store)
    {
        Cookies = store;
        // SocketsHttpHandler 直用：拿到 PooledConnectionLifetime（HttpClientHandler 是它的包装但
        // 不暴露该字段），让长跑进程能定期换 TCP 连接，避免 DNS 漂移后还死抱旧 IP。
        _handler = new SocketsHttpHandler
        {
            UseCookies = false,
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.All,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            PooledConnectionIdleTimeout = TimeSpan.FromMinutes(2)
        };
        _http = new HttpClient(_handler)
        {
            Timeout = TimeSpan.FromSeconds(15)
        };
    }

    public static string DefaultCookieFile() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".reusedisplay",
        "cookies.json");

    public string CsrfToken => Cookies.Get("__csrf") ?? string.Empty;

    public bool HasLoginCookie => Cookies.Has("MUSIC_U") || Cookies.Has("MUSIC_A");

    /// <summary>登录态被清空时触发，MediaService 用来失效 userId/likelist/收藏歌单 id 缓存。</summary>
    public event EventHandler? LoggedOut;

    public void Dispose()
    {
        _http.Dispose();
        _handler.Dispose();
        Cookies.Dispose();
    }

    // ---------------------------------------------------------------------
    // 公共 API
    // ---------------------------------------------------------------------

    public async Task<QrKeyResult> GetQrKeyAsync(CancellationToken ct = default)
    {
        var data = await RequestApiClientAsync("/api/login/qrcode/unikey",
            new Dictionary<string, string> { ["type"] = "3" }, ct).ConfigureAwait(false);
        var code = data.TryGetProperty("code", out var c) ? c.GetInt32() : 0;
        var unikey = data.TryGetProperty("unikey", out var u) ? u.GetString() : null;
        var message = data.TryGetProperty("message", out var m) ? m.GetString() : null;
        var loginUrl = string.IsNullOrEmpty(unikey)
            ? null
            : $"https://music.163.com/login?codekey={unikey}";
        return new QrKeyResult(code, unikey, loginUrl, message);
    }

    public async Task<QrCheckResult> CheckQrAsync(string key, CancellationToken ct = default)
    {
        var data = await RequestApiClientAsync("/api/login/qrcode/client/login",
            new Dictionary<string, string> { ["key"] = key, ["type"] = "3" }, ct).ConfigureAwait(false);
        var code = data.TryGetProperty("code", out var c) ? c.GetInt32() : 0;
        var message = data.TryGetProperty("message", out var m) ? m.GetString() : null;
        return new QrCheckResult(code, message);
    }

    public async Task<AccountInfo> GetCurrentAccountAsync(CancellationToken ct = default)
    {
        var data = await RequestAsync(HttpMethod.Get, "/api/w/nuser/account/get",
            query: null, form: null, headers: null, useCookie: true, ct).ConfigureAwait(false);
        long? userId = null;
        string? nickname = null;
        if (data.TryGetProperty("profile", out var profile) && profile.ValueKind == JsonValueKind.Object)
        {
            if (profile.TryGetProperty("userId", out var uid) && uid.ValueKind == JsonValueKind.Number)
            {
                userId = uid.GetInt64();
            }
            if (profile.TryGetProperty("nickname", out var nn) && nn.ValueKind == JsonValueKind.String)
            {
                nickname = nn.GetString();
            }
        }
        return new AccountInfo(userId, nickname);
    }

    public async Task<FavoritePlaylistInfo?> GetFavoritePlaylistAsync(CancellationToken ct = default)
    {
        var account = await GetCurrentAccountAsync(ct).ConfigureAwait(false);
        if (account.UserId is null) return null;
        var data = await RequestAsync(HttpMethod.Get, "/api/user/playlist/",
            query: new Dictionary<string, string>
            {
                ["uid"] = account.UserId.Value.ToString(CultureInfo.InvariantCulture),
                ["limit"] = "30",
                ["offset"] = "0"
            },
            form: null, headers: null, useCookie: true, ct).ConfigureAwait(false);
        if (!data.TryGetProperty("playlist", out var arr) || arr.ValueKind != JsonValueKind.Array)
        {
            return null;
        }
        foreach (var item in arr.EnumerateArray())
        {
            if (!item.TryGetProperty("creator", out var creator) ||
                creator.ValueKind != JsonValueKind.Object) continue;
            if (!creator.TryGetProperty("userId", out var cuid) ||
                cuid.GetInt64() != account.UserId.Value) continue;
            var special = item.TryGetProperty("specialType", out var st) && st.ValueKind == JsonValueKind.Number
                ? st.GetInt32() : 0;
            if (special != 5) continue;
            return new FavoritePlaylistInfo(
                item.GetProperty("id").GetInt64(),
                item.TryGetProperty("name", out var nn) ? nn.GetString() ?? "" : "",
                item.TryGetProperty("trackCount", out var tc) ? tc.GetInt32() : 0);
        }
        return null;
    }

    public async Task<PlaylistDetail> GetPlaylistAsync(long id, CancellationToken ct = default)
    {
        var data = await RequestAsync(HttpMethod.Get, "/api/v6/playlist/detail",
            query: new Dictionary<string, string>
            {
                ["id"] = id.ToString(CultureInfo.InvariantCulture)
            },
            form: null, headers: null, useCookie: true, ct).ConfigureAwait(false);
        var code = data.TryGetProperty("code", out var c) ? c.GetInt32() : 0;
        if (!data.TryGetProperty("playlist", out var pl) || pl.ValueKind != JsonValueKind.Object)
        {
            return new PlaylistDetail(code, id, "", 0, Array.Empty<TrackInfo>());
        }
        var name = pl.TryGetProperty("name", out var nn) ? nn.GetString() ?? "" : "";
        var trackCount = pl.TryGetProperty("trackCount", out var tc) ? tc.GetInt32() : 0;
        var tracks = Array.Empty<TrackInfo>();
        if (pl.TryGetProperty("tracks", out var tr) && tr.ValueKind == JsonValueKind.Array)
        {
            var list = new List<TrackInfo>(tr.GetArrayLength());
            foreach (var t in tr.EnumerateArray())
            {
                var info = BuildTrackInfo(t);
                if (info != null) list.Add(info);
            }
            tracks = list.ToArray();
        }
        return new PlaylistDetail(code, id, name, trackCount, tracks);
    }

    public async Task<TrackInfo[]> GetDailyRecommendAsync(CancellationToken ct = default)
    {
        var data = await RequestAsync(HttpMethod.Get, "/api/v1/discovery/recommend/songs",
            query: null, form: null, headers: null, useCookie: true, ct).ConfigureAwait(false);
        if (!data.TryGetProperty("data", out var inner) || inner.ValueKind != JsonValueKind.Object)
        {
            if (data.TryGetProperty("recommend", out var legacy) && legacy.ValueKind == JsonValueKind.Array)
            {
                return ExtractTracks(legacy);
            }
            return Array.Empty<TrackInfo>();
        }
        if (inner.TryGetProperty("dailySongs", out var ds) && ds.ValueKind == JsonValueKind.Array)
        {
            return ExtractTracks(ds);
        }
        if (inner.TryGetProperty("recommend", out var rc) && rc.ValueKind == JsonValueKind.Array)
        {
            return ExtractTracks(rc);
        }
        return Array.Empty<TrackInfo>();
    }

    public async Task<SongUrlResult> GetSongUrlAsync(long id, string level = "standard",
        string encodeType = "mp3", CancellationToken ct = default)
    {
        var data = await RequestAsync(HttpMethod.Get, "/api/song/enhance/player/url/v1",
            query: new Dictionary<string, string>
            {
                ["ids"] = $"[{id.ToString(CultureInfo.InvariantCulture)}]",
                ["level"] = level,
                ["encodeType"] = encodeType
            },
            form: null, headers: null, useCookie: true, ct).ConfigureAwait(false);
        var code = data.TryGetProperty("code", out var c) ? c.GetInt32() : 0;
        if (!data.TryGetProperty("data", out var arr) || arr.ValueKind != JsonValueKind.Array ||
            arr.GetArrayLength() == 0)
        {
            return new SongUrlResult(code, null, null, id);
        }
        var first = arr[0];
        var url = first.TryGetProperty("url", out var u) && u.ValueKind == JsonValueKind.String
            ? u.GetString() : null;
        int? fee = first.TryGetProperty("fee", out var f) && f.ValueKind == JsonValueKind.Number
            ? f.GetInt32() : null;
        return new SongUrlResult(code, url, fee, id);
    }

    public async Task<SongLyricResult> GetSongLyricAsync(long id, CancellationToken ct = default)
    {
        var data = await RequestAsync(HttpMethod.Get, "/api/song/lyric",
            query: new Dictionary<string, string>
            {
                ["id"] = id.ToString(CultureInfo.InvariantCulture),
                ["lv"] = "-1",
                ["kv"] = "-1",
                ["tv"] = "-1"
            },
            form: null, headers: null, useCookie: true, ct).ConfigureAwait(false);
        var code = data.TryGetProperty("code", out var c) ? c.GetInt32() : 0;
        var lrc = "";
        if (data.TryGetProperty("lrc", out var lrcEl) && lrcEl.ValueKind == JsonValueKind.Object &&
            lrcEl.TryGetProperty("lyric", out var lyric) && lyric.ValueKind == JsonValueKind.String)
        {
            lrc = lyric.GetString() ?? "";
        }
        return new SongLyricResult(code, lrc);
    }

    public async Task<long[]> GetLikelistAsync(long uid, CancellationToken ct = default)
    {
        var data = await RequestAsync(HttpMethod.Get, "/api/song/like/get",
            query: new Dictionary<string, string>
            {
                ["uid"] = uid.ToString(CultureInfo.InvariantCulture)
            },
            form: null, headers: null, useCookie: true, ct).ConfigureAwait(false);
        if (!data.TryGetProperty("ids", out var arr) || arr.ValueKind != JsonValueKind.Array)
        {
            return Array.Empty<long>();
        }
        var list = new List<long>(arr.GetArrayLength());
        foreach (var el in arr.EnumerateArray())
        {
            if (el.ValueKind == JsonValueKind.Number && el.TryGetInt64(out var id))
            {
                list.Add(id);
            }
        }
        return list.ToArray();
    }

    public async Task<ApiResult> ManipulatePlaylistTracksAsync(long pid, long[] trackIds, string op,
        CancellationToken ct = default)
    {
        var idsJson = "[" + string.Join(",", trackIds.Select(i => i.ToString(CultureInfo.InvariantCulture))) + "]";
        var form = new Dictionary<string, string>
        {
            ["op"] = op,
            ["pid"] = pid.ToString(CultureInfo.InvariantCulture),
            ["trackIds"] = idsJson,
            ["imme"] = "true",
            ["csrf_token"] = CsrfToken
        };
        var data = await RequestAsync(HttpMethod.Post, "/api/playlist/manipulate/tracks",
            query: null, form: form, headers: null, useCookie: true, ct).ConfigureAwait(false);
        var code = data.TryGetProperty("code", out var c) ? c.GetInt32() : 0;
        var msg = data.TryGetProperty("message", out var m) ? m.GetString() : null;
        return new ApiResult(code, msg);
    }

    public async Task<TrackInfo[]> GetHeartbeatAsync(long songId, long playlistId,
        string type = "fromPlayOne", int count = 20, CancellationToken ct = default)
    {
        count = Math.Clamp(count, 1, 150);
        var form = new Dictionary<string, string>
        {
            ["songId"] = songId.ToString(CultureInfo.InvariantCulture),
            ["type"] = type,
            ["playlistId"] = playlistId.ToString(CultureInfo.InvariantCulture),
            ["startMusicId"] = songId.ToString(CultureInfo.InvariantCulture),
            ["count"] = count.ToString(CultureInfo.InvariantCulture)
        };
        var data = await RequestAsync(HttpMethod.Post, "/api/playmode/intelligence/list",
            query: null, form: form, headers: null, useCookie: true, ct).ConfigureAwait(false);
        if (!data.TryGetProperty("data", out var inner)) return Array.Empty<TrackInfo>();
        if (inner.ValueKind == JsonValueKind.Array) return ExtractTracksFromHeartbeat(inner);
        if (inner.ValueKind == JsonValueKind.Object &&
            inner.TryGetProperty("songList", out var sl) && sl.ValueKind == JsonValueKind.Array)
        {
            return ExtractTracksFromHeartbeat(sl);
        }
        return Array.Empty<TrackInfo>();
    }

    public async Task ScrobbleAsync(long songId, long? sourceId, string source, int time,
        string end = "playend", CancellationToken ct = default)
    {
        if (time < 5) return; // 与 JS 端 5 秒阈值保持一致
        var json = new
        {
            download = 0,
            end,
            id = songId,
            time,
            type = "song",
            wifi = 0,
            source,
            sourceId = sourceId ?? 0
        };
        var payload = new Dictionary<string, object?>
        {
            ["logs"] = JsonSerializer.Serialize(new[] { new { action = "play", json } })
        };
        await RequestWeapiAsync("/weapi/feedback/weblog", payload, ct).ConfigureAwait(false);
    }

    public void Logout()
    {
        Cookies.Clear();
        LoggedOut?.Invoke(this, EventArgs.Empty);
    }

    // ---------------------------------------------------------------------
    // 内部请求实现
    // ---------------------------------------------------------------------

    private async Task<JsonElement> RequestAsync(
        HttpMethod method,
        string endpoint,
        IDictionary<string, string>? query,
        IDictionary<string, string>? form,
        IDictionary<string, string>? headers,
        bool useCookie,
        CancellationToken ct)
    {
        var url = BuildUrl(endpoint, query);
        using var req = new HttpRequestMessage(method, url);
        ApplyDefaultHeaders(req);
        if (headers != null)
        {
            foreach (var kv in headers) SetHeader(req, kv.Key, kv.Value);
        }
        if (useCookie)
        {
            var cookieHeader = Cookies.GetCookieHeader();
            if (!string.IsNullOrEmpty(cookieHeader))
            {
                req.Headers.TryAddWithoutValidation("Cookie", cookieHeader);
            }
        }
        if (form != null)
        {
            req.Content = new FormUrlEncodedContent(form);
        }
        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct)
            .ConfigureAwait(false);
        Cookies.UpdateFromResponse(resp);
        var text = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (string.IsNullOrEmpty(text))
        {
            return default;
        }
        using var doc = JsonDocument.Parse(text);
        return doc.RootElement.Clone();
    }

    private async Task<JsonElement> RequestApiClientAsync(string endpoint,
        IDictionary<string, string> form, CancellationToken ct)
    {
        var url = BuildUrl(endpoint, null);
        using var req = new HttpRequestMessage(HttpMethod.Post, url);
        ApplyDefaultHeaders(req);
        SetHeader(req, "User-Agent", MobileUserAgent);
        var cookieHeader = BuildClientCookieHeader();
        req.Headers.TryAddWithoutValidation("Cookie", cookieHeader);
        req.Content = new FormUrlEncodedContent(form);
        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct)
            .ConfigureAwait(false);
        Cookies.UpdateFromResponse(resp);
        var text = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (string.IsNullOrEmpty(text)) return default;
        using var doc = JsonDocument.Parse(text);
        return doc.RootElement.Clone();
    }

    private async Task<JsonElement> RequestWeapiAsync(string endpoint,
        IDictionary<string, object?> payload, CancellationToken ct)
    {
        var csrf = CsrfToken;
        payload["csrf_token"] = csrf;
        var plainJson = JsonSerializer.Serialize(payload);
        var (paramsField, encSecKey) = Weapi.Encrypt(plainJson);
        var query = new Dictionary<string, string> { ["csrf_token"] = csrf };
        var form = new Dictionary<string, string>
        {
            ["params"] = paramsField,
            ["encSecKey"] = encSecKey
        };
        var headers = new Dictionary<string, string>
        {
            ["Accept"] = "*/*",
            ["sec-fetch-site"] = "same-origin",
            ["sec-fetch-mode"] = "cors",
            ["sec-fetch-dest"] = "empty"
        };
        return await RequestAsync(HttpMethod.Post, endpoint, query, form, headers, useCookie: true, ct)
            .ConfigureAwait(false);
    }

    private static string BuildUrl(string endpoint, IDictionary<string, string>? query)
    {
        var sb = new StringBuilder(BaseUrl);
        if (!endpoint.StartsWith('/')) sb.Append('/');
        sb.Append(endpoint);
        if (query == null || query.Count == 0) return sb.ToString();
        sb.Append('?');
        var first = true;
        foreach (var kv in query)
        {
            if (!first) sb.Append('&');
            first = false;
            sb.Append(HttpUtility.UrlEncode(kv.Key));
            sb.Append('=');
            sb.Append(HttpUtility.UrlEncode(kv.Value));
        }
        return sb.ToString();
    }

    private static void ApplyDefaultHeaders(HttpRequestMessage req)
    {
        req.Headers.TryAddWithoutValidation("Accept", "application/json, text/plain, */*");
        req.Headers.TryAddWithoutValidation("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8");
        req.Headers.TryAddWithoutValidation("Origin", BaseUrl);
        req.Headers.TryAddWithoutValidation("Referer", BaseUrl + "/");
        req.Headers.TryAddWithoutValidation("User-Agent", WebUserAgent);
    }

    private static void SetHeader(HttpRequestMessage req, string name, string value)
    {
        req.Headers.Remove(name);
        req.Headers.TryAddWithoutValidation(name, value);
    }

    private string BuildClientCookieHeader()
    {
        var requestId =
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture)
            + "_" + RandomNumberGenerator.GetInt32(0, 10000).ToString("D4", CultureInfo.InvariantCulture);
        var fields = new List<KeyValuePair<string, string>>
        {
            new("osver", "Microsoft-Windows-10-Professional-build-22631-64bit"),
            new("deviceId", ""),
            new("os", "pc"),
            new("appver", "3.0.18.203152"),
            new("versioncode", "140"),
            new("mobilename", ""),
            new("buildver", DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture)),
            new("resolution", "1920x1080"),
            new("__csrf", CsrfToken),
            new("channel", "netease"),
            new("requestId", requestId)
        };
        var musicU = Cookies.Get("MUSIC_U");
        if (!string.IsNullOrEmpty(musicU))
        {
            fields.Add(new KeyValuePair<string, string>("MUSIC_U", musicU));
        }
        return string.Join("; ",
            fields.Select(f => $"{HttpUtility.UrlEncode(f.Key)}={HttpUtility.UrlEncode(f.Value)}"));
    }

    // ---------------------------------------------------------------------
    // Track JSON 提取
    // ---------------------------------------------------------------------

    private static TrackInfo[] ExtractTracks(JsonElement arr)
    {
        var list = new List<TrackInfo>(arr.GetArrayLength());
        foreach (var t in arr.EnumerateArray())
        {
            var info = BuildTrackInfo(t);
            if (info != null) list.Add(info);
        }
        return list.ToArray();
    }

    private static TrackInfo[] ExtractTracksFromHeartbeat(JsonElement arr)
    {
        var list = new List<TrackInfo>(arr.GetArrayLength());
        foreach (var item in arr.EnumerateArray())
        {
            JsonElement song;
            if (item.TryGetProperty("songInfo", out var si) && si.ValueKind == JsonValueKind.Object)
            {
                song = si;
            }
            else if (item.TryGetProperty("song", out var s) && s.ValueKind == JsonValueKind.Object)
            {
                song = s;
            }
            else
            {
                song = item;
            }
            var info = BuildTrackInfo(song);
            if (info != null) list.Add(info);
        }
        return list.ToArray();
    }

    private static TrackInfo? BuildTrackInfo(JsonElement song)
    {
        if (song.ValueKind != JsonValueKind.Object) return null;
        if (!song.TryGetProperty("id", out var idEl) || idEl.ValueKind != JsonValueKind.Number) return null;
        var id = idEl.GetInt64();
        var name = song.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String
            ? n.GetString() ?? "" : "";

        var artists = ExtractArtistNames(song);

        string? album = null;
        string? cover = null;
        if (song.TryGetProperty("al", out var al) && al.ValueKind == JsonValueKind.Object)
        {
            if (al.TryGetProperty("name", out var an) && an.ValueKind == JsonValueKind.String) album = an.GetString();
            if (al.TryGetProperty("picUrl", out var pu) && pu.ValueKind == JsonValueKind.String) cover = pu.GetString();
        }
        else if (song.TryGetProperty("album", out var album2) && album2.ValueKind == JsonValueKind.Object)
        {
            if (album2.TryGetProperty("name", out var an) && an.ValueKind == JsonValueKind.String) album = an.GetString();
            if (album2.TryGetProperty("picUrl", out var pu) && pu.ValueKind == JsonValueKind.String) cover = pu.GetString();
        }

        long? duration = null;
        if (song.TryGetProperty("dt", out var dt) && dt.ValueKind == JsonValueKind.Number) duration = dt.GetInt64();
        else if (song.TryGetProperty("duration", out var du) && du.ValueKind == JsonValueKind.Number) duration = du.GetInt64();

        int? fee = song.TryGetProperty("fee", out var f) && f.ValueKind == JsonValueKind.Number ? f.GetInt32() : null;

        return new TrackInfo(id, name, artists, album, cover, duration, fee);
    }

    private static string ExtractArtistNames(JsonElement song)
    {
        JsonElement arr;
        if (song.TryGetProperty("ar", out var ar) && ar.ValueKind == JsonValueKind.Array) arr = ar;
        else if (song.TryGetProperty("artists", out var artists) && artists.ValueKind == JsonValueKind.Array) arr = artists;
        else return "";
        var names = new List<string>(arr.GetArrayLength());
        foreach (var a in arr.EnumerateArray())
        {
            if (a.ValueKind != JsonValueKind.Object) continue;
            if (a.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String)
            {
                var s = n.GetString();
                if (!string.IsNullOrWhiteSpace(s)) names.Add(s);
            }
        }
        return string.Join(" / ", names);
    }
}
