import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol/agent_protocol.dart';

/// 局域网主动探测扫描器
/// 通过 HTTP /health 端点扫描局域网内运行 PC Agent 的设备
/// 比 UDP 广播更可靠（Android WiFi 栈对 UDP 广播支持不稳定）
class LanProbeScanner {
  bool _isRunning = false;
  HttpClient? _client;
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  /// 发现的 Agent IP 地址流
  Stream<String> get discoveries => _controller.stream;

  /// 启动局域网扫描
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    _client ??= HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 800)
      ..idleTimeout = const Duration(seconds: 3);
    var foundAnyAgent = false;

    while (_isRunning) {
      try {
        final localIps = await _resolveLocalIps();
        for (final localIp in localIps) {
          if (!_isRunning) break;
          foundAnyAgent = await _scanSubnet(localIp) || foundAnyAgent;
        }
      } catch (_) {}

      if (_isRunning) {
        await Future.delayed(foundAnyAgent
            ? const Duration(seconds: 15)
            : const Duration(seconds: 3));
      }
    }
  }

  /// 获取本机局域网 IP
  Future<List<String>> _resolveLocalIps() async {
    final candidates = <({String ip, int score})>[];

    try {
      for (final interface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      )) {
        final name = interface.name.toLowerCase();
        final isWifiLike = name.contains('wlan') ||
            name.contains('wifi') ||
            name.contains('wi-fi');
        final isVirtualLike = name.contains('virtual') ||
            name.contains('vmware') ||
            name.contains('vbox') ||
            name.contains('hyper-v') ||
            name.contains('loopback') ||
            name.contains('tun');

        for (final addr in interface.addresses) {
          final ip = addr.address;
          if (!_isEligibleLanIp(ip)) {
            continue;
          }

          var score = 0;
          if (isWifiLike) score += 100;
          if (ip.startsWith('192.168.')) score += 20;
          if (ip.startsWith('10.')) score += 15;
          if (_is172Private(ip)) score += 10;
          if (isVirtualLike) score -= 100;
          candidates.add((ip: ip, score: score));
        }
      }
    } catch (_) {}

    candidates.sort((a, b) => b.score.compareTo(a.score));
    final seen = <String>{};
    return candidates
        .map((entry) => entry.ip)
        .where((ip) => seen.add(ip))
        .toList();
  }

  /// 扫描同一 /24 子网的所有 IP
  Future<bool> _scanSubnet(String localIp) async {
    final parts = localIp.split('.');
    if (parts.length != 4) return false;
    final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
    var found = false;

    // 分批并发扫描，每批 30 个 IP，避免网络风暴
    const batchSize = 30;
    for (var start = 1; start <= 254 && _isRunning; start += batchSize) {
      final end = (start + batchSize - 1).clamp(1, 254);
      final futures = <Future<bool>>[];

      for (var i = start; i <= end; i++) {
        final ip = '$subnet.$i';
        if (ip == localIp) continue; // 跳过自己
        futures.add(_probeHost(ip));
      }

      final results = await Future.wait(futures, eagerError: false);
      if (results.any((matched) => matched)) {
        found = true;
      }
    }

    return found;
  }

  /// 探测单个主机
  Future<bool> _probeHost(String ip) async {
    if (!_isRunning) return false;
    final client = _client;
    if (client == null) return false;

    try {
      final request = await client.getUrl(
        Uri.parse('http://$ip:${AgentProtocol.webSocketPort}/health'),
      );
      final response = await request.close().timeout(
            const Duration(seconds: 1),
          );

      if (response.statusCode == 200) {
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 1));
        final json = jsonDecode(body) as Map<String, dynamic>;

        // 验证是我们的 Agent（通过 protocolVersion 字段）
        if (json['protocolVersion'] != null && _isRunning) {
          _controller.add(ip);
          return true;
        }
      } else {
        // 非 200 也要排空 body，让 socket 回到 keep-alive 池
        await response.drain<void>();
      }
    } catch (_) {
      // 连接失败 / 超时 / 解析失败：直接忽略
    }
    return false;
  }

  /// 停止扫描
  Future<void> stop() async {
    _isRunning = false;
    _client?.close(force: true);
    _client = null;
    // 不关闭 _controller：允许后续重新 start()
  }

  Future<void> dispose() async {
    _isRunning = false;
    _client?.close(force: true);
    _client = null;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  bool _isEligibleLanIp(String ip) {
    if (ip.startsWith('127.') ||
        ip.startsWith('169.254.') ||
        ip.startsWith('100.')) {
      return false;
    }

    return ip.startsWith('192.168.') || ip.startsWith('10.') || _is172Private(ip);
  }

  bool _is172Private(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4 || parts[0] != '172') {
      return false;
    }
    final second = int.tryParse(parts[1]) ?? -1;
    return second >= 16 && second <= 31;
  }
}
