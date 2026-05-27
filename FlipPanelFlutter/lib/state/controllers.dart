import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../network/agent_repository.dart';
import '../protocol/protocol.dart';

/// 音乐播放状态数据模型
class MusicState {
  final String? trackId;
  final String? title;
  final String? artist;
  final String? playbackState;
  final int? volumePercent;
  final double? positionSeconds;
  final double? durationSeconds;
  final bool? isLiked;
  final String? lyric;
  final String? coverImgUrl;
  final List<LyricLine> _lyricLines;

  const MusicState({
    this.trackId,
    this.title,
    this.artist,
    this.playbackState,
    this.volumePercent,
    this.positionSeconds,
    this.durationSeconds,
    this.isLiked,
    this.lyric,
    this.coverImgUrl,
    List<LyricLine> lyricLines = const [],
  }) : _lyricLines = lyricLines;

  MusicState copyWith({
    String? trackId,
    String? title,
    String? artist,
    String? playbackState,
    int? volumePercent,
    double? positionSeconds,
    double? durationSeconds,
    bool? isLiked,
    String? lyric,
    String? coverImgUrl,
    bool keepTrackId = true,
    bool keepTitle = true,
    bool keepArtist = true,
    bool keepPlaybackState = true,
    bool keepVolumePercent = true,
    bool keepPositionSeconds = true,
    bool keepDurationSeconds = true,
    bool keepIsLiked = true,
    bool keepLyric = true,
    bool keepCoverImgUrl = true,
  }) {
    final nextLyric = keepLyric ? (lyric ?? this.lyric) : lyric;
    return MusicState(
      trackId: keepTrackId ? (trackId ?? this.trackId) : trackId,
      title: keepTitle ? (title ?? this.title) : title,
      artist: keepArtist ? (artist ?? this.artist) : artist,
      playbackState: keepPlaybackState
          ? (playbackState ?? this.playbackState)
          : playbackState,
      volumePercent: keepVolumePercent
          ? (volumePercent ?? this.volumePercent)
          : volumePercent,
      positionSeconds: keepPositionSeconds
          ? (positionSeconds ?? this.positionSeconds)
          : positionSeconds,
      durationSeconds: keepDurationSeconds
          ? (durationSeconds ?? this.durationSeconds)
          : durationSeconds,
      isLiked: keepIsLiked ? (isLiked ?? this.isLiked) : isLiked,
      lyric: nextLyric,
      coverImgUrl:
          keepCoverImgUrl ? (coverImgUrl ?? this.coverImgUrl) : coverImgUrl,
      lyricLines: identical(nextLyric, this.lyric)
          ? _lyricLines
          : _parseLyric(nextLyric),
    );
  }

  bool get isPlaying =>
      playbackState == 'playing' ||
      playbackState == '播放中' ||
      playbackState?.toLowerCase() == 'playing';

  String get displayTitle => title ?? '未知曲目';
  String get displayArtist => artist ?? '未知艺术家';
  String get displayState => playbackState ?? '未知';

  String get positionText => _formatDuration(positionSeconds ?? 0);
  String get durationText => _formatDuration(durationSeconds ?? 0);
  bool get liked => isLiked ?? false;
  List<LyricLine> get lyricLines => _lyricLines;
  String get currentLyricLine {
    final lines = lyricLines;
    if (lines.isEmpty) return '';
    final p = positionSeconds ?? 0;
    var current = lines.first.text;
    for (final line in lines) {
      if (line.second <= p) {
        current = line.text;
      } else {
        break;
      }
    }
    return current;
  }

  double get progress {
    final d = durationSeconds;
    final p = positionSeconds;
    if (d == null || d <= 0 || p == null) return 0;
    return (p / d).clamp(0.0, 1.0);
  }

  static String _formatDuration(double seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toInt().toString().padLeft(2, '0');
    return '$m:$s';
  }

  factory MusicState.fromStatus(DeviceStatusMessage msg) {
    // position 直接取 PC 推过来的真实播放位置。
    // 之前这里用 `DateTime.now().toUtc() - msg.timestampUtc` 算 latency 然后往 position 加，
    // 想补偿 PC 算 position 到手机收到之间的网络延迟。但这个差等于两台设备 wall clock 的差
    // （手机和 PC 没 NTP 同步），手机 clock 通常快几秒到几十秒 → position 被无端前移那么多
    // → 播放时歌词整体提前；暂停时不走这分支，position 立刻"回退"对齐 PC。
    // 真正的网络延迟在局域网内 <100ms，远小于歌词一行的粒度，本地 250ms tick 已足以推进，
    // 不需要、也无法基于跨设备时间戳做补偿。
    final positionSeconds = msg.musicPositionSeconds;

    return MusicState(
      trackId: msg.musicTrackId,
      title: msg.musicTitle,
      artist: msg.musicArtist,
      playbackState: msg.musicPlaybackState,
      volumePercent: msg.musicVolumePercent,
      positionSeconds: positionSeconds,
      durationSeconds: msg.musicDurationSeconds,
      isLiked: msg.musicIsLiked,
      lyric: msg.musicLyric,
      coverImgUrl: msg.musicCoverImgUrl,
      lyricLines: _parseLyricCached(msg.musicTrackId, msg.musicLyric),
    );
  }

  static final RegExp _lrcTagPattern =
      RegExp(r'\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]');

  // PC 每 1-2s 推一次 status，相同曲目歌词 string 反复传，避免重复跑 regex。
  // 单条目缓存就够：换歌时 trackId 变就重新解析。
  static String? _cachedLyricTrackId;
  static String? _cachedLyricRaw;
  static List<LyricLine> _cachedLyricLines = const [];

  static List<LyricLine> _parseLyricCached(String? trackId, String? lyricText) {
    if (lyricText == null || lyricText.isEmpty) return const [];
    if (trackId != null &&
        trackId == _cachedLyricTrackId &&
        identical(lyricText, _cachedLyricRaw)) {
      return _cachedLyricLines;
    }
    if (trackId != null &&
        trackId == _cachedLyricTrackId &&
        lyricText == _cachedLyricRaw) {
      // 同曲、内容相等但 String 实例不同（jsonDecode 每次新分配）：复用解析结果，刷新 raw 引用以走 identical 快路径。
      _cachedLyricRaw = lyricText;
      return _cachedLyricLines;
    }
    final lines = _parseLyric(lyricText);
    _cachedLyricTrackId = trackId;
    _cachedLyricRaw = lyricText;
    _cachedLyricLines = lines;
    return lines;
  }

  static List<LyricLine> _parseLyric(String? lyricText) {
    if (lyricText == null || lyricText.isEmpty) return const [];
    final lines = <LyricLine>[];
    for (final raw in lyricText.split('\n')) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final matches = _lrcTagPattern.allMatches(trimmed).toList();
      if (matches.isEmpty) continue;
      final text = trimmed.substring(matches.last.end).trim();
      for (final m in matches) {
        final minute = int.tryParse(m.group(1) ?? '0') ?? 0;
        final second = int.tryParse(m.group(2) ?? '0') ?? 0;
        final msRaw = m.group(3);
        final int ms;
        if (msRaw == null || msRaw.isEmpty) {
          ms = 0;
        } else if (msRaw.length == 1) {
          ms = (int.tryParse(msRaw) ?? 0) * 100;
        } else if (msRaw.length == 2) {
          ms = (int.tryParse(msRaw) ?? 0) * 10;
        } else {
          ms = int.tryParse(msRaw) ?? 0;
        }
        final time = minute * 60 + second + ms / 1000.0;
        lines.add(LyricLine(time, text));
      }
    }
    if (lines.isEmpty) return const [];
    lines.sort((a, b) => a.second.compareTo(b.second));
    return lines;
  }
}

class LyricLine {
  final double second;
  final String text;
  const LyricLine(this.second, this.text);
}

/// 连接状态管理
class ConnectionController extends ChangeNotifier {
  final AgentRepository _repository;
  StreamSubscription? _connSub;
  StreamSubscription? _statusSub;

  AgentConnectionState _state = AgentConnectionState.idle;
  String? _connectedHost;
  String? _deviceName;

  AgentConnectionState get state => _state;
  String? get connectedHost => _connectedHost;
  String? get deviceName => _deviceName;
  bool get isConnected => _state == AgentConnectionState.connected;

  ConnectionController(this._repository) {
    _connSub = _repository.connectionStateStream.listen((state) {
      _state = state;
      if (state == AgentConnectionState.connected) {
        _connectedHost = _repository.connectedHost;
      }
      notifyListeners();
    });
    _statusSub = _repository.statusStream.listen((status) {
      if (_deviceName != status.deviceName && status.deviceName.isNotEmpty) {
        _deviceName = status.deviceName;
        notifyListeners();
      }
    });
  }

  void startDiscovery() => _repository.startAutoDiscovery();

  void connectManual(String host) => _repository.connectManual(host);

  void disconnect() => _repository.disconnect();

  @override
  void dispose() {
    _connSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }
}

/// 音乐状态管理
class MusicController extends ChangeNotifier {
  final AgentRepository _repository;
  Timer? _ticker;
  StreamSubscription? _statusSub;
  StreamSubscription? _resultSub;
  StreamSubscription? _connSub;
  DateTime? _lastStatusReceivedAt;
  bool _volumePreviewActive = false;
  bool _playbackStateTrusted = false;

  /// 暂停/续播乐观更新保护窗口。命令发出后，PC 的周期性 status 心跳可能仍
  /// 在采样旧的 playbackState（SMTC 响应有 200-500ms 延迟），直接覆盖会让
  /// 按钮图标"点击后闪回再翻转"。窗口内保留本地乐观值；收到与本地一致的
  /// PC snapshot 时提前解除；超时也解除（防止 PC 真的没响应导致永久滞留）。
  DateTime? _playbackStateOptimisticUntil;
  static const Duration _playbackStateOptimisticWindow =
      Duration(milliseconds: 1200);

  /// 硬件音量键：连接 PC 后通过 MethodChannel 接 Android dispatchKeyEvent，
  /// 长按时持续累加本地预览音量，停按 ~250ms 后单次 commit 到 PC，避免长按
  /// 发出几十条 setVolume 命令压垮 SMTC。
  static const MethodChannel _volumeKeyChannel =
      MethodChannel('com.reuse.flippanel/volumekey');
  static const int _volumeKeyStep = 5;
  static const Duration _volumeKeyCommitDelay = Duration(milliseconds: 250);
  Timer? _volumeKeyCommitTimer;

  MusicState _state = const MusicState();
  MusicState get state => _state;

  /// 独立的播放位置流，0.0 ~ 1.0，高频更新但不触发全局 rebuild
  final ValueNotifier<double> progressNotifier = ValueNotifier(0.0);

  MusicController(this._repository) {
    _statusSub = _repository.statusStream.listen(_onStatus);
    _resultSub = _repository.resultStream.listen(_onResult);
    _connSub =
        _repository.connectionStateStream.listen(_onConnectionStateChanged);
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _tickPlayback();
    });
    _volumeKeyChannel.setMethodCallHandler(_onVolumeKeyCall);
  }

  void _onStatus(DeviceStatusMessage msg) {
    final nextState = MusicState.fromStatus(msg);
    var merged = _volumePreviewActive && _state.volumePercent != null
        ? nextState.copyWith(volumePercent: _state.volumePercent)
        : nextState;

    final optimisticUntil = _playbackStateOptimisticUntil;
    if (optimisticUntil != null) {
      if (!DateTime.now().isBefore(optimisticUntil) ||
          nextState.playbackState == _state.playbackState) {
        // 超时或 PC 已跟上：信任 PC，解除保护
        _playbackStateOptimisticUntil = null;
      } else {
        // 窗口内且 PC 仍滞后：保留本地乐观 playbackState
        merged = merged.copyWith(playbackState: _state.playbackState);
      }
    }

    _state = merged;
    _lastStatusReceivedAt = DateTime.now();
    _playbackStateTrusted = true;
    notifyListeners();
  }

  void _onConnectionStateChanged(AgentConnectionState state) {
    final connected = state == AgentConnectionState.connected;
    if (!connected) {
      _playbackStateTrusted = false;
      _lastStatusReceivedAt = null;
      _playbackStateOptimisticUntil = null;
      _volumeKeyCommitTimer?.cancel();
      _volumeKeyCommitTimer = null;
    }
    _setVolumeKeyInterceptEnabled(connected);
  }

  Future<void> _setVolumeKeyInterceptEnabled(bool enabled) async {
    try {
      await _volumeKeyChannel.invokeMethod('setEnabled', enabled);
    } catch (_) {
      // 非 Android 平台或 channel 未就绪
    }
  }

  Future<dynamic> _onVolumeKeyCall(MethodCall call) async {
    if (call.method != 'volumeKey') return null;
    final direction = call.arguments as String?;
    if (direction != 'up' && direction != 'down') return null;
    final base = _state.volumePercent ?? 50;
    final raw =
        direction == 'up' ? base + _volumeKeyStep : base - _volumeKeyStep;
    final next = raw < 0 ? 0 : (raw > 100 ? 100 : raw);
    if (next == base) return null;

    // 长按期间只更新本地预览（同时激活 _volumePreviewActive 让 status 心跳
    // 不会把本地音量回滚），停按后单次 commit 到 PC。
    previewVolume(next);
    _volumeKeyCommitTimer?.cancel();
    _volumeKeyCommitTimer = Timer(_volumeKeyCommitDelay, () {
      final committed = _state.volumePercent;
      if (committed != null) setVolume(committed);
    });
    return null;
  }

  void _onResult(CommandResultMessage result) {
    if (!result.success) {
      return;
    }

    if (result.actionId == AgentProtocol.actionLaunch ||
        result.actionId == AgentProtocol.actionNext ||
        result.actionId == AgentProtocol.actionPrevious) {
      _state = _trackChangeResetState();
    } else if (result.actionId == AgentProtocol.actionStop) {
      _state = _state.copyWith(
        playbackState: 'stopped',
        positionSeconds: 0,
      );
    } else if (result.actionId == AgentProtocol.actionDislike) {
      _state = _state.copyWith(isLiked: false);
    } else if (result.actionId == AgentProtocol.actionSetVolume) {
      _volumePreviewActive = false;
    }
    // actionPlayPause / actionLike 不在这里乐观更新：
    //  - playPause 在 playPause() 里已按本地状态翻转好
    //  - like 是 toggle，结果以 PC snapshot 为准（StateChanged 推送 ≤ 100ms 到达）
    notifyListeners();
  }

  void _tickPlayback() {
    if (!_playbackStateTrusted) return;
    if (!_state.isPlaying) return;
    final position = _state.positionSeconds;
    final duration = _state.durationSeconds;
    if (position == null || duration == null || duration <= 0) return;
    if (_lastStatusReceivedAt == null) return;

    final nextPosition = (position + 0.25).clamp(0.0, duration);
    if ((nextPosition - position).abs() < 0.001) return;
    final oldLine = _lyricIndexAt(position);
    _state = _state.copyWith(positionSeconds: nextPosition);
    progressNotifier.value = _state.progress;
    // 歌词行切换时才触发全局 rebuild（歌词高亮）+ 整秒边界（时间文本）
    final newLine = _lyricIndexAt(nextPosition);
    if (oldLine != newLine || (position ~/ 1) != (nextPosition ~/ 1)) {
      notifyListeners();
    }
  }

  /// 计算给定时间对应的歌词行索引
  int _lyricIndexAt(double position) {
    final lines = _state.lyricLines;
    if (lines.isEmpty) return 0;
    var result = 0;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].second <= position) {
        result = i;
      } else {
        break;
      }
    }
    return result;
  }

  /// 切歌乐观更新：清空旧曲元数据，仅保留音量等无关字段。避免新位置 0 与旧歌词
  /// /标题/封面错配出现 50-100ms 闪烁；紧接的 status 推送会填充新数据。
  MusicState _trackChangeResetState() {
    return _state.copyWith(
      playbackState: 'playing',
      positionSeconds: 0,
      keepTrackId: false,
      trackId: null,
      keepTitle: false,
      title: null,
      keepArtist: false,
      artist: null,
      keepLyric: false,
      lyric: null,
      keepCoverImgUrl: false,
      coverImgUrl: null,
      keepIsLiked: false,
      isLiked: null,
      keepDurationSeconds: false,
      durationSeconds: null,
    );
  }

  void launch() => _repository.sendAction(AgentProtocol.actionLaunch);
  void playPause() {
    if (!_playbackStateTrusted) {
      _state = _trackChangeResetState();
      notifyListeners();
      _repository.sendAction(AgentProtocol.actionLaunch);
      return;
    }

    if (_state.isPlaying) {
      _state = _state.copyWith(playbackState: 'paused');
      _playbackStateOptimisticUntil =
          DateTime.now().add(_playbackStateOptimisticWindow);
      notifyListeners();
      _repository.sendAction(AgentProtocol.actionPause);
      return;
    }

    final playbackState = _state.playbackState;
    if (playbackState == 'paused' ||
        playbackState == '已暂停' ||
        playbackState?.toLowerCase() == 'paused') {
      _state = _state.copyWith(playbackState: 'playing');
      _playbackStateOptimisticUntil =
          DateTime.now().add(_playbackStateOptimisticWindow);
      notifyListeners();
      _repository.sendAction(AgentProtocol.actionResume);
      return;
    }

    _state = _trackChangeResetState();
    notifyListeners();
    _repository.sendAction(AgentProtocol.actionLaunch);
  }

  void next() {
    _state = _trackChangeResetState();
    notifyListeners();
    _repository.sendAction(AgentProtocol.actionNext);
  }

  void previous() {
    _state = _trackChangeResetState();
    notifyListeners();
    _repository.sendAction(AgentProtocol.actionPrevious);
  }

  void stop() {
    _state = _state.copyWith(
      playbackState: 'stopped',
      positionSeconds: 0,
    );
    notifyListeners();
    _repository.sendAction(AgentProtocol.actionStop);
  }
  void like() => _repository.sendAction(AgentProtocol.actionLike);
  void dislike() => _repository.sendAction(AgentProtocol.actionDislike);

  void previewVolume(int value) {
    _volumePreviewActive = true;
    _state = _state.copyWith(volumePercent: value.clamp(0, 100));
    notifyListeners();
  }

  void setVolume(int value) {
    final normalized = value.clamp(0, 100);
    _volumePreviewActive = false;
    _state = _state.copyWith(volumePercent: normalized);
    _repository.sendAction(AgentProtocol.actionSetVolume, value: normalized);
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _volumeKeyCommitTimer?.cancel();
    _statusSub?.cancel();
    _resultSub?.cancel();
    _connSub?.cancel();
    _volumeKeyChannel.setMethodCallHandler(null);
    _setVolumeKeyInterceptEnabled(false);
    progressNotifier.dispose();
    super.dispose();
  }
}
