import 'package:flutter/material.dart';

/// FlipPanel 洛天依桌搭主题
/// 视觉基调：天依青绿主色调、轻赛博/轻电子风、亚克力拟物感、星尘粒子
class FlipPanelTheme {
  FlipPanelTheme._();

  // ── 洛天依色板 ──
  // 天依标志色：青蓝/薄荷绿（#66CCFF ~ #00B578）
  static const Color tianyiTeal = Color(0xFF66CCFF);        // 天依主色
  static const Color tianyiMint = Color(0xFF00CCAA);         // 薄荷辅色
  static const Color tianyiDeep = Color(0xFF3399CC);         // 深天依蓝
  static const Color tianyiLight = Color(0xFF99DDFF);        // 浅天依蓝
  static const Color tianyiGlow = Color(0xFF80DDFF);         // 发光色

  // ── 核心色板（兼容旧引用） ──
  static const Color primary = Color(0xFF66CCFF);
  static const Color primaryDark = Color(0xFF3399CC);
  static const Color primaryLight = Color(0xFF99DDFF);
  static const Color accent = Color(0xFF80DDFF);
  static const Color accentSecondary = Color(0xFF00CCAA);

  // ── 背景色 ──
  static const Color backgroundDeep = Color(0xFF0A1628);
  static const Color backgroundMid = Color(0xFF102040);
  static const Color surface = Color(0xFF162D50);
  static const Color surfaceLight = Color(0xFF1E3A5F);

  // ── 玻璃/亚克力色 ──
  static const Color glass = Color(0x22FFFFFF);
  static const Color glassBorder = Color(0x3366CCFF);
  static const Color glassHighlight = Color(0x15FFFFFF);

  // ── 文字色 ──
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xB3FFFFFF);
  static const Color textMuted = Color(0x80FFFFFF);
  static const Color textDim = Color(0x66FFFFFF);

  // ── 状态色 ──
  static const Color success = Color(0xFF4ADE80);
  static const Color warning = Color(0xFFFBBF24);
  static const Color error = Color(0xFFF87171);
  static const Color connected = Color(0xFF4ADE80);
  static const Color disconnected = Color(0xFFF87171);

  // ── 阴影/发光 ──
  static const List<BoxShadow> glowShadow = [
    BoxShadow(color: Color(0x4066CCFF), blurRadius: 24, spreadRadius: -4),
  ];
  static const List<BoxShadow> tianyiGlowShadow = [
    BoxShadow(color: Color(0x5066CCFF), blurRadius: 20, spreadRadius: -2),
  ];
  static const List<BoxShadow> subtleShadow = [
    BoxShadow(color: Color(0x20000000), blurRadius: 8, offset: Offset(0, 2)),
  ];
  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x26000000), blurRadius: 18, offset: Offset(0, 8)),
  ];

  // ── 圆角 ──
  static const double radiusSmall = 12.0;
  static const double radiusMedium = 20.0;
  static const double radiusLarge = 28.0;

  // ── 间距 ──
  static const double spacingXs = 4.0;
  static const double spacingSm = 8.0;
  static const double spacingMd = 16.0;
  static const double spacingLg = 24.0;
  static const double spacingXl = 32.0;
  static const double spacing2xl = 40.0;

  static const Duration motionFast = Duration(milliseconds: 160);
  static const Duration motionBase = Duration(milliseconds: 240);

  static const BorderRadius cardRadius = BorderRadius.all(Radius.circular(radiusMedium));
  static const BorderRadius chipRadius = BorderRadius.all(Radius.circular(999));

  /// 构建 MaterialTheme
  static ThemeData get theme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: backgroundDeep,
      colorScheme: const ColorScheme.dark(
        primary: tianyiTeal,
        secondary: tianyiMint,
        surface: surface,
        error: error,
        onPrimary: textPrimary,
        onSecondary: backgroundDeep,
        onSurface: textPrimary,
        onError: textPrimary,
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontSize: 42,
          fontWeight: FontWeight.w700,
          color: textPrimary,
          letterSpacing: -1,
        ),
        displayMedium: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          color: textPrimary,
          letterSpacing: -0.5,
        ),
        headlineMedium: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w500,
          color: textPrimary,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          color: textSecondary,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: textSecondary,
        ),
        labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: textPrimary,
          letterSpacing: 0.5,
        ),
      ),
      iconTheme: const IconThemeData(color: textSecondary),
    );
  }

  /// 亚克力玻璃装饰
  static BoxDecoration get glassDecoration => BoxDecoration(
        color: glass,
        borderRadius: cardRadius,
        border: Border.all(color: glassBorder, width: 1),
        boxShadow: cardShadow,
      );

  /// 带发光效果的玻璃装饰
  static BoxDecoration get glowingGlassDecoration => BoxDecoration(
        color: glass,
        borderRadius: cardRadius,
        border: Border.all(color: glassBorder, width: 1),
        boxShadow: tianyiGlowShadow,
      );

  static BoxDecoration elevatedPanel({
    bool accent = false,
  }) =>
      BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: accent
              ? [
                  const Color(0x2A66CCFF),
                  const Color(0x1A00CCAA),
                ]
              : [
                  const Color(0x22FFFFFF),
                  const Color(0x12FFFFFF),
                ],
        ),
        borderRadius: cardRadius,
        border: Border.all(
          color: accent ? tianyiGlow.withAlpha(140) : glassBorder,
          width: 1,
        ),
        boxShadow: accent ? tianyiGlowShadow : cardShadow,
      );
}
