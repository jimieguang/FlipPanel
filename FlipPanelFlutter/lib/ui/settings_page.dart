import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../network/agent_repository.dart';
import '../state/controllers.dart';
import 'theme/flip_panel_theme.dart';

/// 设置页面
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final connState = context.watch<ConnectionController>();

    return Scaffold(
      backgroundColor: FlipPanelTheme.backgroundDeep,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(FlipPanelTheme.spacingLg),
        children: [
          // 连接状态卡片
          _GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '连接状态',
                  style: TextStyle(
                    color: FlipPanelTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: connState.isConnected
                            ? FlipPanelTheme.connected
                            : FlipPanelTheme.disconnected,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      connState.isConnected
                          ? '已连接: ${connState.deviceName ?? connState.connectedHost ?? ""}'
                          : _connectionStateText(connState.state),
                      style: const TextStyle(
                        color: FlipPanelTheme.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 手动连接卡片
          _GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '手动连接',
                  style: TextStyle(
                    color: FlipPanelTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '自动发现失败时，可手动输入 PC 的 IP 地址进行连接',
                  style: TextStyle(
                    color: FlipPanelTheme.textMuted,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => _showManualIpDialog(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: FlipPanelTheme.primary.withAlpha(50),
                      foregroundColor: FlipPanelTheme.accent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(FlipPanelTheme.radiusSmall),
                        side: const BorderSide(color: FlipPanelTheme.glassBorder),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('输入 IP 地址'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 断开连接
          if (connState.isConnected)
            _GlassCard(
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => connState.disconnect(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: FlipPanelTheme.error.withAlpha(30),
                    foregroundColor: FlipPanelTheme.error,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(FlipPanelTheme.radiusSmall),
                      side: BorderSide(color: FlipPanelTheme.error.withAlpha(80)),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('断开连接'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _connectionStateText(AgentConnectionState state) {
    switch (state) {
      case AgentConnectionState.idle:
        return '未开始';
      case AgentConnectionState.discovering:
        return '正在搜索 PC...';
      case AgentConnectionState.connecting:
        return '正在连接...';
      case AgentConnectionState.connected:
        return '已连接';
      case AgentConnectionState.reconnecting:
        return '重新连接中...';
    }
  }

  void _showManualIpDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: FlipPanelTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FlipPanelTheme.radiusMedium),
          side: const BorderSide(color: FlipPanelTheme.glassBorder),
        ),
        title: const Text('手动连接', style: TextStyle(color: FlipPanelTheme.textPrimary)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: FlipPanelTheme.textPrimary),
          decoration: InputDecoration(
            hintText: '例如: 192.168.1.100',
            hintStyle: const TextStyle(color: FlipPanelTheme.textMuted),
            enabledBorder: OutlineInputBorder(
              borderSide: const BorderSide(color: FlipPanelTheme.glassBorder),
              borderRadius: BorderRadius.circular(FlipPanelTheme.radiusSmall),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: const BorderSide(color: FlipPanelTheme.accent),
              borderRadius: BorderRadius.circular(FlipPanelTheme.radiusSmall),
            ),
          ),
          keyboardType: TextInputType.url,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: FlipPanelTheme.textMuted)),
          ),
          TextButton(
            onPressed: () {
              final host = controller.text.trim();
              if (host.isNotEmpty) {
                context.read<ConnectionController>().connectManual(host);
                Navigator.pop(ctx);
              }
            },
            child: const Text('连接', style: TextStyle(color: FlipPanelTheme.accent)),
          ),
        ],
      ),
    );
  }
}

/// 亚克力玻璃卡片
class _GlassCard extends StatelessWidget {
  final Widget child;

  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(FlipPanelTheme.spacingMd),
      decoration: FlipPanelTheme.glassDecoration,
      child: child,
    );
  }
}
