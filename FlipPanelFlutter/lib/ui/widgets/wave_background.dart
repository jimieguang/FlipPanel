import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/flip_panel_theme.dart';
import 'network_image.dart';

/// 天依风格星尘声波背景
/// 播放时微动、暂停时呼吸态、防烧屏像素微动
/// 融入洛天依气质：薄荷绿粒子、青蓝星尘
class WaveBackground extends StatefulWidget {
  final bool isPlaying;
  final String? coverImgUrl;

  const WaveBackground({
    super.key,
    required this.isPlaying,
    this.coverImgUrl,
  });

  @override
  State<WaveBackground> createState() => _WaveBackgroundState();
}

class _WaveBackgroundState extends State<WaveBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  double _driftX = 0;
  double _driftY = 0;
  int _driftStep = 0;

  static const List<double> _driftOffsets = [0, 2, -1, 3, -2, 1, -3, 2];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    if (widget.isPlaying) _controller.repeat();
    _startDriftTimer();
  }

  @override
  void didUpdateWidget(WaveBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      // 暂停时停 controller：AnimatedBuilder 不再 tick，粒子/声波冻结在最后一帧；
      // 复播时 repeat() 从原 animationValue 续跑，平滑衔接。
      if (widget.isPlaying) {
        if (!_controller.isAnimating) _controller.repeat();
      } else {
        _controller.stop();
      }
    }
  }

  void _startDriftTimer() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 90));
      if (!mounted) return false;
      setState(() {
        _driftStep = (_driftStep + 1) % _driftOffsets.length;
        _driftX = _driftOffsets[_driftStep];
        _driftY = _driftOffsets[(_driftStep + 3) % _driftOffsets.length];
      });
      return true;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 专辑封面模糊背景层
        if (widget.coverImgUrl != null && widget.coverImgUrl!.isNotEmpty)
          _BlurCoverLayer(coverImgUrl: widget.coverImgUrl!),
        // 星尘粒子层（用 RepaintBoundary 隔离动画重绘）
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Transform.translate(
                offset: Offset(_driftX, _driftY),
                child: CustomPaint(
                  painter: _StarDustPainter(
                    animationValue: _controller.value,
                  ),
                  size: Size.infinite,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 专辑封面模糊背景组件
/// 使用低分辨率缓存 + 轻量模糊，降低 GPU 开销
class _BlurCoverLayer extends StatelessWidget {
  final String coverImgUrl;
  const _BlurCoverLayer({required this.coverImgUrl});

  @override
  Widget build(BuildContext context) {
    final url = normalizeImageUrl(coverImgUrl);
    if (url == null) return const SizedBox.shrink();
    return Stack(
      fit: StackFit.expand,
      children: [
        CoverImage(
          url: url,
          cacheWidth: 256,
          cacheHeight: 256,
          placeholder: DecoratedBox(
            decoration: BoxDecoration(color: FlipPanelTheme.backgroundDeep),
          ),
          errorWidget: const Center(
            child: Icon(Icons.music_note_rounded, color: Color(0x30FFFFFF), size: 48),
          ),
        ),
        ClipRect(
          clipBehavior: Clip.antiAliasWithSaveLayer, // 更平滑的裁切边缘
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 36, sigmaY: 36), // 略微降低 sigma 减少开销
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x660A1628), // 顶部遮罩较轻，封面可见度约60%
                    Color(0x7A0A1628), // 中部遮罩适中
                    Color(0x900A1628), // 底部稍深，为内容区域提供对比
                  ],
                  stops: [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 星尘粒子 + 声波绘制器
class _StarDustPainter extends CustomPainter {
  final double animationValue;

  // 预生成的粒子数据，避免每帧重新随机
  static final List<_StarParticle> _particles = List.generate(40, (i) {
    final rng = Random(i * 7 + 42);
    return _StarParticle(
      x: rng.nextDouble(),
      y: rng.nextDouble(),
      size: rng.nextDouble() * 2.5 + 0.5,
      speed: rng.nextDouble() * 0.3 + 0.1,
      phase: rng.nextDouble() * 2 * pi,
      isMint: i % 5 == 0, // 每5个粒子有1个薄荷色
    );
  });

  // 缓存 Paint 实例，避免每帧重复创建（仅重建可变颜色）
  late final List<Paint> _particlePaints =
      List.generate(_particles.length, (_) => _createParticlePaint());
  late final List<Paint> _wavePaints =
      List.generate(3, (_) => _createWavePaint());

  Paint _createParticlePaint() => Paint()
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);

  Paint _createWavePaint() => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2;

  _StarDustPainter({
    required this.animationValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 光斑（天依青蓝）
    _drawGlow(canvas, Offset(w * 0.3, h * 0.25), 120,
        FlipPanelTheme.tianyiTeal.withAlpha(18));
    _drawGlow(canvas, Offset(w * 0.7, h * 0.6), 100,
        FlipPanelTheme.tianyiMint.withAlpha(12));

    // 星尘粒子
    _drawParticles(canvas, size);

    // 声波
    _drawWaves(canvas, size);
  }

  void _drawGlow(Canvas canvas, Offset center, double radius, Color color) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color, Colors.transparent],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  void _drawParticles(Canvas canvas, Size size) {
    const speed = 1.0;

    for (var idx = 0; idx < _particles.length; idx++) {
      final p = _particles[idx];
      // 粒子缓慢漂浮
      final dx = p.x * size.width +
          sin(animationValue * speed * 2 * pi + p.phase) * 8;
      final dy = p.y * size.height +
          cos(animationValue * speed * 1.5 * pi + p.phase) * 6;

      // 呼吸透明度
      final breathAlpha =
          (sin(animationValue * speed * 2 * pi + p.phase) * 0.3 + 0.4);
      final alpha = (breathAlpha * 255).round().clamp(40, 200);

      final color = p.isMint
          ? FlipPanelTheme.tianyiMint.withAlpha(alpha)
          : FlipPanelTheme.tianyiTeal.withAlpha(alpha);

      final paint = _particlePaints[idx]..color = color;
      canvas.drawCircle(Offset(dx, dy), p.size, paint);
    }
  }

  void _drawWaves(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    const speed = 1.0;
    const amplitude = 12.0;

    for (int i = 0; i < 3; i++) {
      final alpha = 20 - i * 5;
      final color = (i == 0
              ? FlipPanelTheme.tianyiTeal
              : FlipPanelTheme.tianyiMint)
          .withAlpha(alpha);

      final paint = _wavePaints[i]..color = color;

      final path = Path();
      final yOffset = h * 0.5 + i * 20 - 20;
      path.moveTo(0, yOffset);

      for (double x = 0; x <= w; x += 2) {
        final normalizedX = x / w;
        final wave1 =
            sin((normalizedX * 4 + animationValue * speed * 2 + i * 0.5) * pi) *
                amplitude;
        final wave2 =
            sin((normalizedX * 7 + animationValue * speed * 3 + i * 0.8) * pi) *
                amplitude *
                0.5;
        path.lineTo(x, yOffset + wave1 + wave2);
      }

      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StarDustPainter oldDelegate) =>
      // 量化到 30fps：controller 周期 8s × 30fps = 240 步
      (oldDelegate.animationValue * 240).floor() !=
      (animationValue * 240).floor();
}

/// 粒子数据
class _StarParticle {
  final double x;
  final double y;
  final double size;
  final double speed;
  final double phase;
  final bool isMint;

  const _StarParticle({
    required this.x,
    required this.y,
    required this.size,
    required this.speed,
    required this.phase,
    required this.isMint,
  });
}
