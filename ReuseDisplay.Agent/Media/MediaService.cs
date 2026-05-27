using System.Globalization;
using Microsoft.Extensions.Hosting;
using ReuseDisplay.Agent.Netease;
using Windows.Media;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage.Streams;

namespace ReuseDisplay.Agent.Media;

/// <summary>
/// 用 Windows.Media.Playback.MediaPlayer + SMTC + NeteaseClient 组装的播放器。
/// 一个进程一个实例（IHostedService 在 DI 容器里注册成 singleton）。
/// PC 端独立播放：拥有自己的音频会话，与游戏音频在 Win 混音器里独立调音。
/// </summary>
internal sealed class MediaService : IHostedService, IDisposable
{
    private readonly NeteaseClient _client;
    private readonly Action<string, string>? _log;

    private MediaPlayer? _player;
    private readonly SemaphoreSlim _navLock = new(1, 1);
    private readonly List<TrackInfo> _queue = new();
    private int _index = -1;
    // _queue / _index 写在 _navLock 内；SnapshotNow / CurrentTrack 从 broadcast/SMTC 线程读，
    // 不能用 `_queue[_index]` —— index 越界与 list 增删可能踩到尚未收尾的修改。改为快照式
    // _currentTrack：在 _navLock 内提交一次，外部读 volatile 引用，无锁。
    private volatile TrackInfo? _currentTrack;
    private string _mode = "idle";
    private long? _favoritePlaylistId;
    private long? _currentLoadedTrackId;
    private string? _lastLyric;
    private long? _lastLyricTrackId;
    private readonly HashSet<long> _likedSongIds = new();
    private long? _currentUserId;
    private string _currentSource = "dailySongRecommend";
    private long _currentSourceId;
    private string? _lastEmittedFingerprint;
    private long? _scrobbleTrackId;
    private DateTime _scrobbleStartedUtc;

    public event EventHandler? StateChanged;

    public MediaService(NeteaseClient client, Action<string, string>? log = null)
    {
        _client = client;
        _log = log;
    }

    public TrackInfo? CurrentTrack => _currentTrack;

    public string PlaybackState { get; private set; } = "stopped";

    public int VolumePercent { get; private set; } = 100;

    public Task StartAsync(CancellationToken cancellationToken)
    {
        _player = new MediaPlayer
        {
            AutoPlay = true,
            Volume = VolumePercent / 100.0
        };
        _player.PlaybackSession.PlaybackStateChanged += OnPlaybackStateChanged;
        _player.MediaEnded += OnMediaEnded;
        _player.MediaFailed += OnMediaFailed;

        var cmd = _player.CommandManager;
        cmd.NextBehavior.EnablingRule = MediaCommandEnablingRule.Always;
        cmd.PreviousBehavior.EnablingRule = MediaCommandEnablingRule.Always;
        cmd.NextReceived += OnSmtcNext;
        cmd.PreviousReceived += OnSmtcPrevious;

        _client.LoggedOut += OnClientLoggedOut;
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        try { _player?.Pause(); } catch { }
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        _client.LoggedOut -= OnClientLoggedOut;
        if (_player != null)
        {
            // 必须在 _player.Dispose 之前解绑所有事件，否则 SMTC / PlaybackSession
            // 在析构期间仍可能 fire，回调里会用到已被 Dispose 的 _navLock 触发
            // ObjectDisposedException 抓不住（事件是 _ = Task.Run 异步触发）。
            _player.PlaybackSession.PlaybackStateChanged -= OnPlaybackStateChanged;
            _player.MediaEnded -= OnMediaEnded;
            _player.MediaFailed -= OnMediaFailed;
            var cmd = _player.CommandManager;
            cmd.NextReceived -= OnSmtcNext;
            cmd.PreviousReceived -= OnSmtcPrevious;
            _player.Dispose();
        }
        _navLock.Dispose();
    }

    // ---------------------------------------------------------------------
    // 公共操作
    // ---------------------------------------------------------------------

    public async Task LaunchAsync(CancellationToken ct = default)
    {
        if (_queue.Count == 0)
        {
            await LoadDailyRecommendAsync(ct).ConfigureAwait(false);
            return;
        }
        await ResumeAsync(ct).ConfigureAwait(false);
    }

    public Task PauseAsync(CancellationToken ct = default)
    {
        _player?.Pause();
        return Task.CompletedTask;
    }

    public Task ResumeAsync(CancellationToken ct = default)
    {
        _player?.Play();
        return Task.CompletedTask;
    }

    public async Task PlayPauseAsync(CancellationToken ct = default)
    {
        if (_player is null) return;
        if (_player.PlaybackSession.PlaybackState == MediaPlaybackState.Playing)
        {
            _player.Pause();
        }
        else if (_queue.Count == 0)
        {
            await LoadDailyRecommendAsync(ct).ConfigureAwait(false);
        }
        else
        {
            _player.Play();
        }
    }

    public async Task StopPlaybackAsync(CancellationToken ct = default)
    {
        await _navLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_player is not null)
            {
                _player.Pause();
                _player.Source = null;
            }
            _index = -1;
            _queue.Clear();
            _mode = "idle";
            _currentLoadedTrackId = null;
            _currentTrack = null;
        }
        finally { _navLock.Release(); }
        EmitState();
    }

    public async Task NextAsync(CancellationToken ct = default)
    {
        await _navLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_queue.Count == 0) return;
            var next = _index + 1;
            if (next >= _queue.Count) next = 0;
            await PlayIndexAsync(next, ct).ConfigureAwait(false);
        }
        finally { _navLock.Release(); }
    }

    public async Task PreviousAsync(CancellationToken ct = default)
    {
        await _navLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_queue.Count == 0) return;
            var prev = _index - 1;
            if (prev < 0) prev = _queue.Count - 1;
            await PlayIndexAsync(prev, ct).ConfigureAwait(false);
        }
        finally { _navLock.Release(); }
    }

    public Task SetVolumeAsync(int percent, CancellationToken ct = default)
    {
        percent = Math.Clamp(percent, 0, 100);
        VolumePercent = percent;
        if (_player != null) _player.Volume = percent / 100.0;
        EmitState();
        return Task.CompletedTask;
    }

    public async Task<bool> LikeAsync(CancellationToken ct = default)
    {
        // 单按钮 toggle：当前已喜欢 → 移除，反之 → 添加
        var track = CurrentTrack;
        if (track is null) return false;
        await EnsureUserContextAsync(ct).ConfigureAwait(false);
        var wasLiked = _likedSongIds.Contains(track.Id);
        return await ToggleFavoriteAsync(add: !wasLiked, track, ct).ConfigureAwait(false);
    }

    public async Task<bool> DislikeAsync(CancellationToken ct = default)
    {
        // 显式取消喜欢，已经不在收藏里就 no-op
        var track = CurrentTrack;
        if (track is null) return false;
        await EnsureUserContextAsync(ct).ConfigureAwait(false);
        if (!_likedSongIds.Contains(track.Id)) return true;
        return await ToggleFavoriteAsync(add: false, track, ct).ConfigureAwait(false);
    }

    public async Task LoadDailyRecommendAsync(CancellationToken ct = default)
    {
        await EnsureUserContextAsync(ct).ConfigureAwait(false);
        var tracks = await _client.GetDailyRecommendAsync(ct).ConfigureAwait(false);
        await ReplaceQueueAsync(tracks, "daily", source: "dailySongRecommend", sourceId: 0, ct).ConfigureAwait(false);
    }

    public async Task LoadFavoritePlaylistAsync(CancellationToken ct = default)
    {
        await EnsureUserContextAsync(ct).ConfigureAwait(false);
        var pid = await EnsureFavoritePlaylistIdAsync(ct).ConfigureAwait(false);
        if (pid is null) return;
        var detail = await _client.GetPlaylistAsync(pid.Value, ct).ConfigureAwait(false);
        await ReplaceQueueAsync(detail.Tracks, "favorite", source: "list", sourceId: pid.Value, ct).ConfigureAwait(false);
    }

    /// <summary>非阻塞快照，broadcast loop 每秒拉一次。</summary>
    public MusicPlaybackSnapshot SnapshotNow()
    {
        var track = _currentTrack;
        double? position = null;
        double? duration = null;
        if (_player is not null && track is not null)
        {
            try { position = _player.PlaybackSession.Position.TotalSeconds; } catch { }
            try
            {
                var natural = _player.PlaybackSession.NaturalDuration.TotalSeconds;
                duration = natural > 0 ? natural : (track.DurationMs.HasValue ? track.DurationMs.Value / 1000.0 : null);
            }
            catch { }
        }
        bool? isLiked = null;
        if (track is not null)
        {
            // _likedSongIds 在 EnsureUserContextAsync/ToggleFavoriteAsync/OnClientLoggedOut 都
            // 持锁修改；broadcast 线程裸 Contains 会和 Clear+AddRange 撞 InvalidOperationException。
            lock (_likedSongIds) isLiked = _likedSongIds.Contains(track.Id);
        }
        // 读 lyric / lyricTrackId 一次到本地，避免比较 trackId 后赋值时被另一线程改成别的歌的 lyric。
        var lyricTrackId = _lastLyricTrackId;
        var lyric = _lastLyric;
        return new MusicPlaybackSnapshot(
            TrackId: track?.Id.ToString(CultureInfo.InvariantCulture),
            Title: track?.Name,
            Artist: track?.Artists,
            PlaybackState: PlaybackState,
            VolumePercent: VolumePercent,
            PositionSeconds: position,
            DurationSeconds: duration,
            IsLiked: isLiked,
            Lyric: track != null && lyricTrackId == track.Id ? lyric : null,
            CoverImgUrl: track?.CoverUrl);
    }

    // ---------------------------------------------------------------------
    // 内部
    // ---------------------------------------------------------------------

    private async Task ReplaceQueueAsync(TrackInfo[] tracks, string mode, string source, long sourceId, CancellationToken ct)
    {
        await _navLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            _queue.Clear();
            _queue.AddRange(tracks);
            _mode = mode;
            _currentSource = source;
            _currentSourceId = sourceId;
            _index = -1;
            if (_queue.Count > 0)
            {
                await PlayIndexAsync(0, ct).ConfigureAwait(false);
            }
            else
            {
                _player?.Pause();
                EmitState();
            }
        }
        finally { _navLock.Release(); }
    }

    private async Task PlayIndexAsync(int index, CancellationToken ct)
    {
        if (_player is null) return;
        // 全队列 fee/版权不可用时旧版会递归 PlayIndexAsync 找下一首，2 首队列里
        // 会形成 0→1→0→1 永远互斥的死循环并一路 stack overflow；同时 _navLock
        // 被 NextAsync/PrevAsync 持有，无法被其他导航打断。改为迭代 + visited
        // 集合，保证最多遍历 _queue.Count 次后放弃。
        var visited = new HashSet<int>();
        while (true)
        {
            if (index < 0 || index >= _queue.Count) return;
            if (!visited.Add(index))
            {
                _log?.Invoke("MEDIA", $"all {visited.Count} tracks unavailable, giving up");
                return;
            }
            _index = index;
            var track = _queue[index];
            _currentTrack = track;
            var urlResult = await _client.GetSongUrlAsync(track.Id, ct: ct).ConfigureAwait(false);
            if (string.IsNullOrEmpty(urlResult.Url))
            {
                _log?.Invoke("MEDIA", $"song {track.Id} unavailable (code={urlResult.Code} fee={urlResult.Fee})");
                if (_queue.Count <= 1) return;
                index = index + 1 >= _queue.Count ? 0 : index + 1;
                continue;
            }
            var source = MediaSource.CreateFromUri(new Uri(urlResult.Url));
            var item = new MediaPlaybackItem(source);
            var props = item.GetDisplayProperties();
            props.Type = MediaPlaybackType.Music;
            props.MusicProperties.Title = track.Name;
            props.MusicProperties.Artist = track.Artists;
            if (!string.IsNullOrEmpty(track.Album)) props.MusicProperties.AlbumTitle = track.Album;
            if (!string.IsNullOrEmpty(track.CoverUrl))
            {
                try
                {
                    props.Thumbnail = RandomAccessStreamReference.CreateFromUri(new Uri(track.CoverUrl));
                }
                catch { }
            }
            item.ApplyDisplayProperties(props);
            _player.Source = item;
            _player.Play();
            _currentLoadedTrackId = track.Id;
            _scrobbleTrackId = track.Id;
            _scrobbleStartedUtc = DateTime.UtcNow;
            _ = LoadLyricAsync(track.Id);
            EmitState();
            return;
        }
    }

    private async Task LoadLyricAsync(long trackId)
    {
        try
        {
            var lyric = await _client.GetSongLyricAsync(trackId).ConfigureAwait(false);
            _lastLyric = lyric.Lrc;
            _lastLyricTrackId = trackId;
            EmitState();
        }
        catch { }
    }

    private async Task<long?> EnsureFavoritePlaylistIdAsync(CancellationToken ct)
    {
        if (_favoritePlaylistId.HasValue) return _favoritePlaylistId;
        var fav = await _client.GetFavoritePlaylistAsync(ct).ConfigureAwait(false);
        _favoritePlaylistId = fav?.Id;
        return _favoritePlaylistId;
    }

    private async Task EnsureUserContextAsync(CancellationToken ct)
    {
        if (!_client.HasLoginCookie) return;
        if (_currentUserId.HasValue) return;
        try
        {
            var account = await _client.GetCurrentAccountAsync(ct).ConfigureAwait(false);
            if (account.UserId is null) return;
            _currentUserId = account.UserId;
            var ids = await _client.GetLikelistAsync(account.UserId.Value, ct).ConfigureAwait(false);
            lock (_likedSongIds)
            {
                _likedSongIds.Clear();
                foreach (var id in ids) _likedSongIds.Add(id);
            }
            _log?.Invoke("MEDIA", $"likelist loaded: {ids.Length} song(s)");
            EmitState();
        }
        catch (Exception ex)
        {
            _log?.Invoke("MEDIA", $"user context fetch failed: {ex.Message}");
        }
    }

    private async Task<bool> ToggleFavoriteAsync(bool add, TrackInfo track, CancellationToken ct)
    {
        var pid = await EnsureFavoritePlaylistIdAsync(ct).ConfigureAwait(false);
        if (pid is null) return false;
        var result = await _client.ManipulatePlaylistTracksAsync(
            pid.Value, new[] { track.Id }, add ? "add" : "del", ct).ConfigureAwait(false);
        if (result.Code != 200)
        {
            _log?.Invoke("MEDIA", $"like toggle failed: code={result.Code} msg={result.Message}");
            return false;
        }
        lock (_likedSongIds)
        {
            if (add) _likedSongIds.Add(track.Id);
            else _likedSongIds.Remove(track.Id);
        }
        EmitState();
        return true;
    }

    private void OnClientLoggedOut(object? sender, EventArgs e)
    {
        _currentUserId = null;
        _favoritePlaylistId = null;
        lock (_likedSongIds) _likedSongIds.Clear();
        EmitState();
    }

    private void EmitState()
    {
        // 去重：源切换时 MediaPlaybackState 会瞬间穿过 None→Opening→Paused→Playing，
        // 配合 lyric/likelist 异步刷新，一次 launch 能挤出 8+ 个冗余事件。
        // 用 fingerprint 拦截重复，把广播减半以上。
        var track = CurrentTrack;
        bool liked = false;
        if (track is not null)
        {
            lock (_likedSongIds) liked = _likedSongIds.Contains(track.Id);
        }
        var fp = string.Concat(
            PlaybackState, "|",
            (track?.Id.ToString(CultureInfo.InvariantCulture)) ?? "-", "|",
            VolumePercent.ToString(CultureInfo.InvariantCulture), "|",
            liked ? "1" : "0", "|",
            (track != null && _lastLyricTrackId == track.Id) ? "L" : "-");
        if (fp == _lastEmittedFingerprint) return;
        _lastEmittedFingerprint = fp;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // ---------------------------------------------------------------------
    // 事件处理
    // ---------------------------------------------------------------------

    private void OnPlaybackStateChanged(MediaPlaybackSession session, object args)
    {
        PlaybackState = session.PlaybackState switch
        {
            MediaPlaybackState.Playing => "playing",
            MediaPlaybackState.Paused => "paused",
            MediaPlaybackState.Buffering => "loading",
            MediaPlaybackState.Opening => "loading",
            _ => "stopped"
        };
        EmitState();
    }

    private void OnMediaEnded(MediaPlayer sender, object args)
    {
        var trackId = _scrobbleTrackId;
        var playedSec = (int)Math.Round((DateTime.UtcNow - _scrobbleStartedUtc).TotalSeconds);
        var source = _currentSource;
        var sourceId = _currentSourceId;
        _scrobbleTrackId = null;
        if (trackId.HasValue && playedSec >= 5)
        {
            // 5 秒阈值与 JS 端 ScrobbleAsync 内部判断一致；fire-and-forget。
            _ = Task.Run(async () =>
            {
                try { await _client.ScrobbleAsync(trackId.Value, sourceId, source, playedSec).ConfigureAwait(false); }
                catch (Exception ex) { _log?.Invoke("MEDIA", $"scrobble failed: {ex.Message}"); }
            });
        }
        _ = NextAsync();
    }

    private void OnMediaFailed(MediaPlayer sender, MediaPlayerFailedEventArgs args)
    {
        _log?.Invoke("MEDIA", $"playback failed: {args.Error} {args.ErrorMessage}");
        _ = NextAsync();
    }

    private void OnSmtcNext(MediaPlaybackCommandManager sender, MediaPlaybackCommandManagerNextReceivedEventArgs args)
    {
        var deferral = args.GetDeferral();
        _ = Task.Run(async () =>
        {
            try { await NextAsync().ConfigureAwait(false); }
            finally { deferral.Complete(); }
        });
    }

    private void OnSmtcPrevious(MediaPlaybackCommandManager sender, MediaPlaybackCommandManagerPreviousReceivedEventArgs args)
    {
        var deferral = args.GetDeferral();
        _ = Task.Run(async () =>
        {
            try { await PreviousAsync().ConfigureAwait(false); }
            finally { deferral.Complete(); }
        });
    }
}
