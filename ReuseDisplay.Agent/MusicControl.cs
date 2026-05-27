using ReuseDisplay.Agent.Media;

/// <summary>
/// 把 Flutter 发过来的 actionId 路由到 MediaService。
/// 以前会 shell-out 到 ncm-cli + 解析其 stdout，现在 MediaService 是进程内播放器，所有操作即时。
/// </summary>
internal sealed class MusicController
{
    private readonly MediaService _media;
    private readonly Action<string>? _log;

    public MusicController(MediaService media, Action<string>? log = null)
    {
        _media = media;
        _log = log;
    }

    public Task<MusicPlaybackSnapshot?> GetCurrentStatusAsync(bool forceRefresh, CancellationToken cancellationToken)
    {
        // forceRefresh 参数保留是为了不动 Program.cs；MediaService 状态本来就实时，没缓存需要 invalidate。
        _ = forceRefresh;
        _ = cancellationToken;
        return Task.FromResult<MusicPlaybackSnapshot?>(_media.SnapshotNow());
    }

    public async Task<MusicActionResult> ExecuteActionAsync(string actionId, int? value, CancellationToken cancellationToken)
    {
        try
        {
            switch (actionId)
            {
                case "music.launch":     await _media.LaunchAsync(cancellationToken); break;
                case "music.playPause":  await _media.PlayPauseAsync(cancellationToken); break;
                case "music.pause":      await _media.PauseAsync(cancellationToken); break;
                case "music.resume":     await _media.ResumeAsync(cancellationToken); break;
                case "music.next":       await _media.NextAsync(cancellationToken); break;
                case "music.previous":   await _media.PreviousAsync(cancellationToken); break;
                case "music.stop":       await _media.StopPlaybackAsync(cancellationToken); break;
                case "music.like":       await _media.LikeAsync(cancellationToken); break;
                case "music.dislike":    await _media.DislikeAsync(cancellationToken); break;
                case "music.setVolume":
                    if (value.HasValue) await _media.SetVolumeAsync(value.Value, cancellationToken);
                    break;
                default:
                    return new MusicActionResult(actionId, false, $"unknown action: {actionId}");
            }
            return new MusicActionResult(actionId, true, "ok");
        }
        catch (Exception ex)
        {
            _log?.Invoke($"action {actionId} failed: {ex.Message}");
            return new MusicActionResult(actionId, false, ex.Message);
        }
    }
}

internal sealed record MusicPlaybackSnapshot(
    string? TrackId,
    string? Title,
    string? Artist,
    string PlaybackState,
    int? VolumePercent,
    double? PositionSeconds,
    double? DurationSeconds,
    bool? IsLiked = null,
    string? Lyric = null,
    string? CoverImgUrl = null);

internal sealed record MusicActionResult(string ActionId, bool Success, string Message);
