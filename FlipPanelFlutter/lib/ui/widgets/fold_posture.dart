import 'dart:ui' show DisplayFeatureType, DisplayFeatureState;
import 'package:flutter/material.dart';

/// 折叠姿态检测
/// 使用 MediaQuery.displayFeatures 检测 Z Flip 4 半折叠状态
class FoldPostureObserver extends StatelessWidget {
  final Widget Function(BuildContext context, bool isHalfFolded) builder;

  const FoldPostureObserver({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    final displayFeatures = MediaQuery.of(context).displayFeatures;
    bool isHalfFolded = false;

    for (final feature in displayFeatures) {
      if (feature.type == DisplayFeatureType.fold &&
          feature.state == DisplayFeatureState.postureHalfOpened) {
        isHalfFolded = true;
        break;
      }
    }

    return builder(context, isHalfFolded);
  }
}
