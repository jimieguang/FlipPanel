namespace ReuseDisplay.Agent.Netease;

internal sealed record TrackInfo(
    long Id,
    string Name,
    string Artists,
    string? Album,
    string? CoverUrl,
    long? DurationMs,
    int? Fee);

internal sealed record SongUrlResult(int Code, string? Url, int? Fee, long Id);

internal sealed record SongLyricResult(int Code, string Lrc);

internal sealed record FavoritePlaylistInfo(long Id, string Name, int TrackCount);

internal sealed record PlaylistDetail(int Code, long Id, string Name, int TrackCount, TrackInfo[] Tracks);

internal sealed record ApiResult(int Code, string? Message);

internal sealed record QrKeyResult(int Code, string? Unikey, string? LoginUrl, string? Message);

internal sealed record QrCheckResult(int Code, string? Message);

internal sealed record AccountInfo(long? UserId, string? Nickname);
