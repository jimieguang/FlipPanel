import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/controllers.dart';
import 'widgets/widgets.dart';
import 'settings_page.dart';

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final musicState = context.watch<MusicController>().state;
    final connState = context.watch<ConnectionController>();

    return FoldPostureObserver(
      builder: (context, isHalfFolded) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              // 半折叠模式才需要 WaveBackground 提供环境粒子/声波；
              // 展开模式的 _ImmersiveCoverBackdrop 已完全不透明，渲染 WaveBackground 是浪费。
              if (isHalfFolded)
                Positioned.fill(
                  child: WaveBackground(
                    isPlaying: musicState.isPlaying,
                    coverImgUrl: null,
                  ),
                ),
              if (!isHalfFolded)
                _ExpandedLyricsScreen(
                  musicState: musicState,
                  connState: connState,
                )
              else
                Column(
                  children: [
                    Expanded(
                      flex: 1,
                      child: _UpperDisplayLayer(
                        musicState: musicState,
                        connState: connState,
                        onSettingsTap: () => _openSettings(context),
                      ),
                    ),
                    const _HingeTransition(),
                    Expanded(
                      flex: 1,
                      child: _IndustrialControlLayer(
                        musicState: musicState,
                        connState: connState,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

class _HingeTransition extends StatelessWidget {
  const _HingeTransition();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 12,
      child: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x12000000),
                    Color(0x26000000),
                    Color(0x34000000),
                    Color(0x22000000),
                    Color(0x08000000),
                  ],
                  stops: [0.0, 0.26, 0.5, 0.76, 1.0],
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 36),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Color(0x18FFFFFF),
                    Color(0x1438DDEB),
                    Color(0x18FFFFFF),
                    Colors.transparent,
                  ],
                ),
                boxShadow: [BoxShadow(color: Color(0x1038DDEB), blurRadius: 6)],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 42),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Color(0x1038DDEB),
                    Color(0x12FFFFFF),
                    Color(0x1038DDEB),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UpperDisplayLayer extends StatelessWidget {
  final MusicState musicState;
  final ConnectionController connState;
  final VoidCallback onSettingsTap;

  static const _titleShadow = Shadow(color: Color(0x8866CCCC), blurRadius: 14);
  static const _titleStyle = TextStyle(
    fontSize: 46,
    height: 1.05,
    fontWeight: FontWeight.w300,
    letterSpacing: 2.5,
    color: Colors.white,
    shadows: [_titleShadow],
  );
  static const _artistStyle = TextStyle(
    fontSize: 18,
    letterSpacing: 2,
    color: Color(0x99FFFFFF),
  );
  static const _badgeStyle = TextStyle(
    fontSize: 12,
    letterSpacing: .8,
    color: Color(0x88FFFFFF),
  );

  const _UpperDisplayLayer({
    required this.musicState,
    required this.connState,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: _SectionCoverBackdrop(
            // key 锁到 url 本身：URL 改变就强制 unmount 旧 Backdrop 子树，新 URL
            // 走完整 mount 路径，绕开 ImageFiltered / Opacity / FittedBox 这类
            // RenderObject 在父布局不变时复用旧 layer 的 hidden cache 风险。
            key: ValueKey('folded-cover-${musicState.coverImgUrl ?? "_none"}'),
            imageUrl: musicState.coverImgUrl,
            // 单次 BoxFit.cover 取景：在原始解码分辨率上对齐主体，不做小框二次裁切
            coverFocalAlignment: const Alignment(0.72, -0.22),
            blurOverscan: 1.06,
            // σ=10 + opacity 0.32 太重，封面几乎只剩色块。下调到 σ=7、opacity 0.45：
            // 仍能保留印象派磨砂感和文字可读性，但封面主体更能"看出来"。
            // 文字侧有 _titleShadow（blurRadius 14）兜底，进一步降不影响可读。
            blurSigma: 7,
            opacity: 0.45,
            borderRadius: 0,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StatusTopBar(
                isConnected: connState.isConnected,
                onSettingsTap: onSettingsTap,
              ),
              const Spacer(),
              Text(
                musicState.displayTitle.toUpperCase(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _titleStyle,
              ),
              const SizedBox(height: 8),
              Text(musicState.displayArtist, style: _artistStyle),
              const SizedBox(height: 14),
              const Row(
                children: [
                  Icon(
                    Icons.music_note_rounded,
                    size: 16,
                    color: Color(0x88FFFFFF),
                  ),
                  SizedBox(width: 6),
                  Text('NOW PLAYING • MUSIC CLOUD', style: _badgeStyle),
                ],
              ),
              const SizedBox(height: 18),
              ValueListenableBuilder<double>(
                valueListenable:
                    context.read<MusicController>().progressNotifier,
                builder:
                    (context, progress, _) => ProgressBar(
                      progress: progress,
                      positionText: musicState.positionText,
                      durationText: musicState.durationText,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusTopBar extends StatelessWidget {
  final bool isConnected;
  final VoidCallback onSettingsTap;

  const _StatusTopBar({required this.isConnected, required this.onSettingsTap});

  @override
  Widget build(BuildContext context) {
    return _StatusTopBarContent(
      isConnected: isConnected,
      onSettingsTap: onSettingsTap,
    );
  }
}

class _StatusTopBarContent extends StatefulWidget {
  final bool isConnected;
  final VoidCallback onSettingsTap;

  const _StatusTopBarContent({
    required this.isConnected,
    required this.onSettingsTap,
  });

  @override
  State<_StatusTopBarContent> createState() => _StatusTopBarContentState();
}

class _StatusTopBarContentState extends State<_StatusTopBarContent> {
  final Battery _battery = Battery();
  Timer? _pollTimer;
  int? _batteryLevel;

  @override
  void initState() {
    super.initState();
    _refreshBatteryLevel();
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _refreshBatteryLevel();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshBatteryLevel() async {
    try {
      final level = await _battery.batteryLevel;
      if (!mounted) return;
      setState(() {
        _batteryLevel = level.clamp(0, 100);
      });
    } catch (_) {
      // 在不支持的平台保持默认显示
    }
  }

  @override
  Widget build(BuildContext context) {
    final level = _batteryLevel ?? 0;
    final batteryText = '$level%';
    final fillFactor = (level / 100).clamp(0.06, 1.0);
    return Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color:
                widget.isConnected
                    ? const Color(0xFF66CCCC)
                    : const Color(0xFFEE6666),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: (widget.isConnected
                        ? const Color(0xFF66CCCC)
                        : const Color(0xFFEE6666))
                    .withAlpha(170),
                blurRadius: 12,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
        const Spacer(),
        IconButton(
          onPressed: widget.onSettingsTap,
          icon: const Icon(Icons.settings, color: Color(0xB3FFFFFF), size: 18),
        ),
        Text(
          batteryText,
          style: const TextStyle(
            color: Color(0xB3FFFFFF),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          width: 21,
          height: 11,
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xB3FFFFFF), width: 1),
            borderRadius: BorderRadius.circular(3),
          ),
          padding: const EdgeInsets.all(1.2),
          child: const Align(alignment: Alignment.centerRight),
        ),
        Transform.translate(
          offset: const Offset(-20, 0),
          child: SizedBox(
            width: 19,
            height: 9,
            child: Align(
              alignment: Alignment.centerRight,
              child: FractionallySizedBox(
                widthFactor: fillFactor,
                child: const SizedBox.expand(
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: Color(0xB3FFFFFF)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _IndustrialControlLayer extends StatefulWidget {
  final MusicState musicState;
  final ConnectionController connState;

  const _IndustrialControlLayer({
    required this.musicState,
    required this.connState,
  });

  @override
  State<_IndustrialControlLayer> createState() =>
      _IndustrialControlLayerState();
}

class _IndustrialControlLayerState extends State<_IndustrialControlLayer> {
  double? _volumeGestureStartY;
  int? _volumeGestureStartValue;
  int? _previewVolume;

  void _handleScaleUpdate(
    ScaleUpdateDetails details,
    MusicController musicCtrl,
  ) {
    if (details.pointerCount < 2) {
      return;
    }

    _volumeGestureStartY ??= details.focalPoint.dy;
    _volumeGestureStartValue ??= widget.musicState.volumePercent ?? 50;

    final deltaY = (_volumeGestureStartY! - details.focalPoint.dy);
    final nextVolume = (_volumeGestureStartValue! + (deltaY / 4).round()).clamp(
      0,
      100,
    );
    _previewVolume = nextVolume;
    musicCtrl.previewVolume(nextVolume);
  }

  void _handleScaleEnd(MusicController musicCtrl) {
    if (_previewVolume != null) {
      musicCtrl.setVolume(_previewVolume!);
    }
    setState(() {
      _volumeGestureStartY = null;
      _volumeGestureStartValue = null;
      _previewVolume = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final musicCtrl = context.read<MusicController>();
    final musicState = widget.musicState;
    final connState = widget.connState;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleUpdate: (details) => _handleScaleUpdate(details, musicCtrl),
      onScaleEnd: (_) => _handleScaleEnd(musicCtrl),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1D2431), Color(0xFF171D29), Color(0xFF141A25)],
            stops: [0.0, 0.18, 1.0],
          ),
          boxShadow: [
            BoxShadow(
              color: Color(0x34000000),
              blurRadius: 12,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: const [
                        Color(0x18C6F6FF),
                        Color(0x08FFFFFF),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.18, 0.5],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Container(
                  height: 30,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: const [
                        Color(0x168AE9FF),
                        Color(0x081E3A58),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 28,
              right: 28,
              child: IgnorePointer(
                child: Container(
                  height: 1,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        Color(0x1038DDEB),
                        Color(0x18FFFFFF),
                        Color(0x1038DDEB),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _SideArrowButton(
                      icon: Icons.arrow_left_rounded,
                      onTap: musicCtrl.previous,
                    ),
                    _CenterDialButton(
                      isPlaying: musicState.isPlaying,
                      onTap: musicCtrl.playPause,
                    ),
                    _SideArrowButton(
                      icon: Icons.arrow_right_rounded,
                      onTap: musicCtrl.next,
                    ),
                  ],
                ),
              ),
            ),
            if (_previewVolume != null)
              Positioned(
                top: 18,
                right: 18,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xCC0E1320),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x3366CCCC)),
                  ),
                  child: Text(
                    'VOL ${_previewVolume!}',
                    style: const TextStyle(
                      color: Color(0xFFCCFFFF),
                      fontSize: 12,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 14,
              child: Row(
                children: [
                  const Icon(
                    Icons.desktop_windows_outlined,
                    color: Color(0x66FFFFFF),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      connState.isConnected
                          ? (musicState.isPlaying ? '已连接 · 播放中' : '已连接 · 待机')
                          : '未连接',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0x66FFFFFF),
                        fontSize: 11,
                        letterSpacing: .4,
                      ),
                    ),
                  ),
                  Text(
                    '音量 ${musicState.volumePercent ?? 0}',
                    style: const TextStyle(
                      color: Color(0x88FFFFFF),
                      fontSize: 11,
                      letterSpacing: .6,
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () {
                      if (musicState.liked) {
                        musicCtrl.dislike();
                      } else {
                        musicCtrl.like();
                      }
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color:
                            musicState.liked
                                ? const Color(0x3366CCCC)
                                : const Color(0x22000000),
                        border: Border.all(
                          color:
                              musicState.liked
                                  ? const Color(0xFF66CCCC)
                                  : const Color(0x44FFFFFF),
                        ),
                        boxShadow:
                            musicState.liked
                                ? const [
                                  BoxShadow(
                                    color: Color(0x8866CCCC),
                                    blurRadius: 12,
                                    spreadRadius: -2,
                                  ),
                                ]
                                : null,
                      ),
                      child: Icon(
                        musicState.liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        color:
                            musicState.liked
                                ? const Color(0xFF66CCCC)
                                : const Color(0x99FFFFFF),
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpandedLyricsScreen extends StatefulWidget {
  final MusicState musicState;
  final ConnectionController connState;

  const _ExpandedLyricsScreen({
    required this.musicState,
    required this.connState,
  });

  @override
  State<_ExpandedLyricsScreen> createState() => _ExpandedLyricsScreenState();
}

class _ExpandedLyricsScreenState extends State<_ExpandedLyricsScreen> {
  static const _lyricActiveStyle = TextStyle(
    color: Color(0xFFCCFFFF),
    fontSize: 28,
    fontWeight: FontWeight.w600,
    shadows: [Shadow(color: Color(0x8866CCCC), blurRadius: 12)],
  );
  static const _lyricInactiveStyle = TextStyle(
    color: Color(0x80FFFFFF),
    fontSize: 22,
    fontWeight: FontWeight.w400,
  );

  // ListView 顶部 padding + 平均每行高度（active≈50, inactive≈42, 含 padding 16）
  // 用于懒加载列表时估算 offset，把目标行先逼进 build 窗口。
  static const double _topPadding = 32.0;
  static const double _avgLineHeight = 46.0;

  final ScrollController _scrollController = ScrollController();
  List<GlobalKey> _lineKeys = [];
  int _lastCurrentIndex = -1;
  bool _scrollInProgress = false;

  @override
  void initState() {
    super.initState();
    _syncKeys();
  }

  @override
  void didUpdateWidget(covariant _ExpandedLyricsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.musicState.lyricLines.length !=
        oldWidget.musicState.lyricLines.length) {
      _syncKeys();
      _lastCurrentIndex = -1; // 换歌后重新触发滚动
    }
    final lines = widget.musicState.lyricLines;
    final currentIndex = _currentLyricIndex(
      lines,
      widget.musicState.positionSeconds ?? 0,
    );
    if (_lastCurrentIndex != currentIndex) {
      _lastCurrentIndex = currentIndex;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCurrent(currentIndex),
      );
    }
  }

  void _syncKeys() {
    _lineKeys = List.generate(
      widget.musicState.lyricLines.length,
      (_) => GlobalKey(),
    );
  }

  /// 懒加载 ListView 下 `Scrollable.ensureVisible` 单帧静默失败的修复：
  /// 先按估算 offset 把目标行逼进 build 窗口，等 context 真的可用后再用
  /// ensureVisible 精修对齐。多次尝试，直到 mounted/index 失效或成功。
  Future<void> _scrollToCurrent(int targetIndex) async {
    if (_scrollInProgress) return;
    if (targetIndex < 0) return;
    _scrollInProgress = true;
    try {
      for (var attempt = 0; attempt < 6; attempt++) {
        if (!mounted) return;
        if (_lastCurrentIndex != targetIndex) return; // 用户已滑过这一行
        if (targetIndex >= _lineKeys.length) return;

        if (!_scrollController.hasClients) {
          await WidgetsBinding.instance.endOfFrame;
          continue;
        }

        final ctx = _lineKeys[targetIndex].currentContext;
        if (ctx != null) {
          await Scrollable.ensureVisible(
            ctx,
            alignment: 0.5,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
          );
          return;
        }

        final pos = _scrollController.position;
        final viewport = pos.viewportDimension;
        final estimated =
            _topPadding +
            targetIndex * _avgLineHeight -
            viewport / 2 +
            _avgLineHeight / 2;
        final clamped = estimated.clamp(0.0, pos.maxScrollExtent);
        if ((clamped - pos.pixels).abs() < 1.0) {
          // 已到达当前能滚到的最远位置但目标仍未 build —— 等下一帧让 ListView 扩展 extent。
          await WidgetsBinding.instance.endOfFrame;
        } else {
          await pos.animateTo(
            clamped,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
        }
      }
    } finally {
      _scrollInProgress = false;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final musicCtrl = context.read<MusicController>();
    final lines = widget.musicState.lyricLines;
    final currentIndex = _currentLyricIndex(
      lines,
      widget.musicState.positionSeconds ?? 0,
    );
    return Stack(
      children: [
        Positioned.fill(
          child: _ImmersiveCoverBackdrop(
            imageUrl: widget.musicState.coverImgUrl,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
          child: Column(
            children: [
              _StatusTopBar(
                isConnected: widget.connState.isConnected,
                onSettingsTap: () => _openSettings(context),
              ),
              const SizedBox(height: 14),
              Text(
                widget.musicState.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.musicState.displayArtist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 14),
              ),
              const SizedBox(height: 10),
              Expanded(
                child:
                    lines.isEmpty
                        ? const Center(
                          child: Text(
                            '暂无歌词',
                            style: TextStyle(
                              color: Color(0x88FFFFFF),
                              fontSize: 18,
                            ),
                          ),
                        )
                        : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 32),
                          itemCount: lines.length,
                          itemBuilder: (context, index) {
                            final active = index == currentIndex;
                            return Padding(
                              key: _lineKeys[index],
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                lines[index].text,
                                textAlign: TextAlign.center,
                                style:
                                    active
                                        ? _lyricActiveStyle
                                        : _lyricInactiveStyle,
                              ),
                            );
                          },
                        ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: musicCtrl.previous,
                    icon: const Icon(
                      Icons.skip_previous_rounded,
                      color: Colors.white,
                    ),
                  ),
                  IconButton(
                    onPressed: musicCtrl.playPause,
                    icon: Icon(
                      widget.musicState.isPlaying
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                      color: const Color(0xFF66CCCC),
                      size: 56,
                    ),
                  ),
                  IconButton(
                    onPressed: musicCtrl.next,
                    icon: const Icon(
                      Icons.skip_next_rounded,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionCoverBackdrop extends StatelessWidget {
  final String? imageUrl;

  /// 封面在视口内单次 BoxFit.cover 的对齐（在完整解码图上取景，避免小框二次裁切）
  final Alignment coverFocalAlignment;

  /// 略大于 1.0 时为高斯模糊预留边缘，避免硬裁切
  final double blurOverscan;
  final double blurSigma;
  final double opacity;
  final double borderRadius;

  const _SectionCoverBackdrop({
    super.key,
    required this.imageUrl,
    required this.coverFocalAlignment,
    this.blurOverscan = 1.06,
    required this.blurSigma,
    required this.opacity,
    required this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final source = normalizeImageUrl(imageUrl);
    // 切歌过程中 coverImgUrl 会瞬时为 null（_trackChangeResetState），上一版本这里
    // 返回 SizedBox.shrink() 直接把整棵 Backdrop 子树（含 in-flight 的 CoverImage）
    // 卸掉，下一帧拿到新 URL 时即便 fetch 成功，旧 future 由于 unmounted 没把 bytes
    // 写入缓存，新 CoverImage 又得重抓一次，遇到代理慢/丢响应就 visible 不出来；
    // 用户切全屏再切回让 widget tree 强制重建才"修复"。改成保留深色占位 +
    // 给 CoverImage 上 ValueKey(url)，每次 URL 变化拿到全新 State 实例，
    // 不再走 didUpdateWidget 重载，没有竞态空窗。
    if (source == null || source.isEmpty) {
      return const ColoredBox(color: Color(0xFF0A1628));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final hasRoundFrame = borderRadius > 0.1;
        final verticalMaskColors =
            hasRoundFrame
                ? const [
                  Color(0x440A1630),
                  Color(0x5A0A1630),
                  Color(0x700A1630),
                ]
                : const [
                  Color(0x2A0A1630),
                  Color(0x3A0A1630),
                  Color(0x500A1630),
                ];
        final sideVignetteColors =
            hasRoundFrame
                ? const [
                  Color(0x300A1630),
                  Colors.transparent,
                  Color(0x2C0A1630),
                ]
                : const [
                  Color(0x1E0A1630),
                  Colors.transparent,
                  Color(0x1A0A1630),
                ];

        if (!hasRoundFrame) {
          final dpr = MediaQuery.devicePixelRatioOf(context);
          final longest = math.max(constraints.maxWidth, constraints.maxHeight);
          final decodeMax = (longest * dpr * 1.25).round().clamp(640, 1600);
          final overscan = blurOverscan.clamp(1.0, 1.18).toDouble();

          return ClipRect(
            child: IgnorePointer(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Opacity(
                    opacity: opacity.clamp(0.0, 1.0),
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(
                        sigmaX: blurSigma,
                        sigmaY: blurSigma,
                      ),
                      child: Transform.scale(
                        scale: overscan,
                        alignment: Alignment.center,
                        child: SizedBox.expand(
                          child: CoverImage(
                            key: ValueKey(source),
                            url: source,
                            fit: BoxFit.cover,
                            alignment: coverFocalAlignment,
                            cacheWidth: decodeMax,
                            placeholder: const DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color(0xFF0A1628),
                              ),
                            ),
                            errorWidget: const Center(
                              child: Icon(
                                Icons.music_note_rounded,
                                color: Color(0x30FFFFFF),
                                size: 36,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: verticalMaskColors,
                        stops: const [0.0, 0.55, 1.0],
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: sideVignetteColors,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        // 圆角卡片模式（保留旧布局，供将来需要时使用）
        final width = constraints.maxWidth * 0.88;
        final height = constraints.maxHeight * 0.72;
        final blurPadding = blurSigma * 3;
        final scaleX = width > 0 ? (width + blurPadding * 2) / width : 1.0;
        final scaleY = height > 0 ? (height + blurPadding * 2) / height : 1.0;
        final imageScale =
            (scaleX > scaleY ? scaleX : scaleY).clamp(1.0, 1.35).toDouble();
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final decodeMax = (math.max(width, height) * dpr * 1.2).round().clamp(
          512,
          1200,
        );

        return Align(
          alignment: Alignment.center,
          child: IgnorePointer(
            child: Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(borderRadius),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x26000000),
                    blurRadius: 30,
                    spreadRadius: 3,
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Opacity(
                    opacity: opacity.clamp(0.0, 1.0),
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(
                        sigmaX: blurSigma,
                        sigmaY: blurSigma,
                      ),
                      child: Transform.scale(
                        scale: imageScale,
                        child: SizedBox.expand(
                          child: CoverImage(
                            key: ValueKey(source),
                            url: source,
                            fit: BoxFit.cover,
                            alignment: coverFocalAlignment,
                            cacheWidth: decodeMax,
                            placeholder: const DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color(0xFF0A1628),
                              ),
                            ),
                            errorWidget: const Center(
                              child: Icon(
                                Icons.music_note_rounded,
                                color: Color(0x30FFFFFF),
                                size: 36,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: verticalMaskColors,
                        stops: const [0.0, 0.55, 1.0],
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: sideVignetteColors,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 沉浸式封面背景（A 方案）：
/// - 中央 width × width 等比封面，作为视觉锚点
/// - 上下空白区用垂直翻转的同图 + 重模糊做镜像延展，向屏幕边缘淡出到深色
/// - 全局叠极淡青色把暖调封面拉回 app 调性
/// - 中央加横向暗带，保护 active 歌词行可读性（中线最深 alpha≈25%）
class _ImmersiveCoverBackdrop extends StatelessWidget {
  final String? imageUrl;

  const _ImmersiveCoverBackdrop({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    final source = normalizeImageUrl(imageUrl);
    if (source == null) {
      return const ColoredBox(color: Color(0xFF0A1628));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final coverSize = w; // 等比方形，铺满屏宽
        final topExtension = ((h - coverSize) / 2).clamp(0.0, h);
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final coverDecode = (coverSize * dpr).round().clamp(360, 1400);
        // 镜像区被 σ=30 重模糊吃掉细节，用小尺寸纹理足够
        final mirrorDecode = (coverSize * dpr * 0.4).round().clamp(160, 640);

        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF0A1628)),

              // 上方镜像：垂直翻转同图，原图顶边贴在中央封面顶边
              if (topExtension > 0)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: topExtension,
                  child: ClipRect(
                    child: OverflowBox(
                      minWidth: coverSize,
                      maxWidth: coverSize,
                      minHeight: coverSize,
                      maxHeight: coverSize,
                      alignment: Alignment.bottomCenter,
                      child: Transform.scale(
                        scaleY: -1,
                        alignment: Alignment.center,
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                          child: CoverImage(
                            url: source,
                            fit: BoxFit.cover,
                            cacheWidth: mirrorDecode,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              // 上方淡出：屏幕顶 0xCC 实色 → 封面顶边附近完全透明
              if (topExtension > 0)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: topExtension,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xCC0A1628), Color(0x000A1628)],
                        stops: [0.0, 0.85],
                      ),
                    ),
                  ),
                ),

              // 中央等比封面
              Positioned(
                top: topExtension,
                left: 0,
                right: 0,
                height: coverSize,
                child: CoverImage(
                  url: source,
                  fit: BoxFit.cover,
                  cacheWidth: coverDecode,
                  placeholder: const DecoratedBox(
                    decoration: BoxDecoration(color: Color(0xFF0A1628)),
                  ),
                ),
              ),

              // 下方镜像
              if (topExtension > 0)
                Positioned(
                  top: topExtension + coverSize,
                  left: 0,
                  right: 0,
                  height: topExtension,
                  child: ClipRect(
                    child: OverflowBox(
                      minWidth: coverSize,
                      maxWidth: coverSize,
                      minHeight: coverSize,
                      maxHeight: coverSize,
                      alignment: Alignment.topCenter,
                      child: Transform.scale(
                        scaleY: -1,
                        alignment: Alignment.center,
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                          child: CoverImage(
                            url: source,
                            fit: BoxFit.cover,
                            cacheWidth: mirrorDecode,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (topExtension > 0)
                Positioned(
                  top: topExtension + coverSize,
                  left: 0,
                  right: 0,
                  height: topExtension,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x000A1628), Color(0xCC0A1628)],
                        stops: [0.15, 1.0],
                      ),
                    ),
                  ),
                ),

              // 极淡青色去饱和层：把暖调封面拉回 app 主色调
              const Positioned.fill(
                child: ColoredBox(color: Color(0x1466CCFF)),
              ),

              // 中央横向暗带：仅在垂直中线附近加深，保护 active 歌词行
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x000A1628),
                        Color(0x000A1628),
                        Color(0x400A1628),
                        Color(0x000A1628),
                        Color(0x000A1628),
                      ],
                      stops: [0.0, 0.36, 0.5, 0.64, 1.0],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

int _currentLyricIndex(List<LyricLine> lines, double position) {
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

class _SideArrowButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _SideArrowButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0x222C3447), Color(0x33425270)],
            ),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: Icon(icon, color: const Color(0x8D66CCCC), size: 34),
        ),
      ),
    );
  }
}

class _CenterDialButton extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback onTap;
  final double size;

  const _CenterDialButton({
    required this.isPlaying,
    required this.onTap,
    this.size = 190,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A2230), Color(0xFF101520)],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x90000000),
            blurRadius: 20,
            offset: Offset(8, 10),
          ),
          BoxShadow(
            color: Color(0x14FFFFFF),
            blurRadius: 12,
            offset: Offset(-4, -4),
          ),
        ],
      ),
      child: Center(
        child: Container(
          width: size * 0.82,
          height: size * 0.82,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0x3366CCCC), width: 2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x5566CCCC),
                blurRadius: 26,
                spreadRadius: -8,
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: const Color(0xFF66CCCC),
                size: size * 0.38,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void _openSettings(BuildContext context) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const SettingsPage()),
  );
}
