import 'package:flutter/material.dart';
import '../theme/flip_panel_theme.dart';

/// 进度条组件
/// 显示当前播放进度，带发光效果
class ProgressBar extends StatelessWidget {
  final double progress;
  final String positionText;
  final String durationText;

  const ProgressBar({
    super.key,
    required this.progress,
    required this.positionText,
    required this.durationText,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = progress.clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 进度条
        SizedBox(
          height: 16,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              Container(
                height: 4,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: const Color(0x33FFFFFF),
                ),
              ),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: clamped,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFFE4F8FF),
                        Color(0xFFB6DEFF),
                      ],
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x5099E0FF),
                        blurRadius: 8,
                        spreadRadius: -1,
                      ),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment(clamped * 2 - 1, 0),
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFF7FDFF),
                    border: Border.all(color: const Color(0x889ED7FF)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x2A000000),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // 时间文字
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              positionText,
              style: const TextStyle(
                color: FlipPanelTheme.textMuted,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              durationText,
              style: const TextStyle(
                color: FlipPanelTheme.textMuted,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
