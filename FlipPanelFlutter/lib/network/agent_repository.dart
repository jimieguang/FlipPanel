import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/protocol.dart';
import 'lan_probe_scanner.dart';
import 'udp_discovery_client.dart';
import 'status_websocket_client.dart';

/// 连接状态枚举
enum AgentConnectionState {
  idle,
  discovering,
  connecting,
  connected,
  reconnecting,
}

/// 核心仓库：管理 UDP 发现 + LAN 扫描 + 缓存 IP 三通道并行连接
///
/// 连接优先级：
/// 1. 上次缓存的 IP 直连（最快，秒级）
/// 2. LAN 子网 HTTP /health 扫描（可靠，~2-10 秒）
/// 3. UDP 广播监听（辅助，依赖 Android WiFi 多播）
class AgentRepository {
  static const Duration _sameHostConnectHold = Duration(seconds: 12);
  static const Duration _sameHostRetryCooldown = Duration(seconds: 3);

  final UdpDiscoveryClient _discoveryClient = UdpDiscoveryClient();
  final LanProbeScanner _lanScanner = LanProbeScanner();
  StatusWebSocketClient? _wsClient;

  final StreamController<AgentConnectionState> _connectionStateController =
      StreamController<AgentConnectionState>.broadcast();
  final StreamController<DeviceStatusMessage> _statusController =
      StreamController<DeviceStatusMessage>.broadcast();
  final StreamController<CommandResultMessage> _resultController =
      StreamController<CommandResultMessage>.broadcast();

  AgentConnectionState _state = AgentConnectionState.idle;
  String? _connectedHost;
  String? _connectingHost;
  StreamSubscription? _discoverySubscription;
  StreamSubscription? _lanScanSubscription;
  StreamSubscription? _statusSubscription;
  StreamSubscription? _resultSubscription;
  StreamSubscription? _connectionSubscription;
  bool _isDisposed = false;
  bool _discoveryStarted = false;
  bool _lanScanStarted = false;
  String? _lastConnectAttemptHost;
  DateTime? _lastConnectAttemptAt;

  static const _prefKeyLastHost = 'last_connected_host';

  AgentConnectionState get connectionState => _state;
  String? get connectedHost => _connectedHost;

  Stream<AgentConnectionState> get connectionStateStream =>
      _connectionStateController.stream;
  Stream<DeviceStatusMessage> get statusStream => _statusController.stream;
  Stream<CommandResultMessage> get resultStream => _resultController.stream;

  /// 启动自动发现并连接
  Future<void> startAutoDiscovery() async {
    if (_isDisposed) return;
    _updateState(AgentConnectionState.discovering);

    // ── 通道 1：订阅 UDP 广播 ──
    _discoverySubscription?.cancel();
    _discoverySubscription =
        _discoveryClient.discoveries.listen((discovery) {
      if (_state == AgentConnectionState.discovering ||
          _state == AgentConnectionState.connecting ||
          _state == AgentConnectionState.reconnecting) {
        // fire-and-forget：三通道并发竞速，由 _connectTo 内部的同 host 去重 + _connectLock 串行化收尾
        unawaited(_connectTo(discovery.hostAddress));
      }
    });

    if (!_discoveryStarted) {
      _discoveryStarted = true;
      _discoveryClient.start().catchError((e) {
        _discoveryStarted = false;
      });
    }

    // ── 通道 2：LAN 子网 HTTP 扫描 ──
    _lanScanSubscription?.cancel();
    _lanScanSubscription = _lanScanner.discoveries.listen((ip) {
      if (_state == AgentConnectionState.discovering ||
          _state == AgentConnectionState.connecting ||
          _state == AgentConnectionState.reconnecting) {
        unawaited(_connectTo(ip));
      }
    });

    if (!_lanScanStarted) {
      _lanScanStarted = true;
      _lanScanner.start().catchError((e) {
        _lanScanStarted = false;
      });
    }

    // ── 通道 3：缓存 IP 直连 ──
    unawaited(_tryConnectLastHost());
  }

  /// 尝试直连上次保存的 IP
  Future<void> _tryConnectLastHost() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastHost = prefs.getString(_prefKeyLastHost);
      if (lastHost != null && lastHost.isNotEmpty) {
        if (_state == AgentConnectionState.connected) {
          return;
        }
        await _connectTo(lastHost);
      }
    } catch (_) {}
  }

  /// 使用手动 IP 连接
  Future<void> connectManual(String host) async {
    await _wsClient?.disconnect();
    await _connectTo(host);
  }

  /// 并发 _connectTo 互斥：teardown→ws 分配序列不能交错，否则前一个 _wsClient 实例会被孤立
  Completer<void>? _connectLock;

  Future<void> _connectTo(String host) async {
    if (_isDisposed) return;

    // 同 host 已连接 / 正在连接 / 重试冷却的快速去重（无需进锁）
    if (_state == AgentConnectionState.connected &&
        _connectedHost == host) {
      return;
    }

    final now = DateTime.now();
    if (_state == AgentConnectionState.connecting &&
        _connectingHost == host &&
        _lastConnectAttemptAt != null &&
        now.difference(_lastConnectAttemptAt!) < _sameHostConnectHold) {
      return;
    }

    if (_lastConnectAttemptHost == host &&
        _lastConnectAttemptAt != null &&
        now.difference(_lastConnectAttemptAt!) < _sameHostRetryCooldown) {
      return;
    }

    // 串行化 teardown + 新连接，避免两个回调同时跑导致 _wsClient 实例漂移
    while (_connectLock != null) {
      await _connectLock!.future;
      // 锁释放后重新检查上面那几个守卫条件可能已变化
      if (_isDisposed) return;
      if (_state == AgentConnectionState.connected && _connectedHost == host) {
        return;
      }
    }
    final lock = Completer<void>();
    _connectLock = lock;
    try {
      _lastConnectAttemptHost = host;
      _lastConnectAttemptAt = DateTime.now();
      _updateState(AgentConnectionState.connecting);
      _connectingHost = host;

      // 断开旧连接
      await _statusSubscription?.cancel();
      await _resultSubscription?.cancel();
      await _connectionSubscription?.cancel();
      await _wsClient?.dispose();

      _wsClient = StatusWebSocketClient();

      _statusSubscription = _wsClient!.statusStream.listen((status) {
        _statusController.add(status);
      });

      _resultSubscription = _wsClient!.resultStream.listen((result) {
        _resultController.add(result);
      });

      _connectionSubscription =
          _wsClient!.connectionStream.listen((connected) {
        if (connected) {
          _connectedHost = host;
          _connectingHost = null;
          _updateState(AgentConnectionState.connected);
          _saveLastHost(host);
          _stopPassiveDiscovery();
        } else {
          _connectedHost = null;
          _connectingHost = null;
          if (_state == AgentConnectionState.connected) {
            _updateState(AgentConnectionState.reconnecting);
          } else {
            _updateState(AgentConnectionState.discovering);
          }
        }
      });

      await _wsClient!.connect(host);
    } finally {
      _connectLock = null;
      lock.complete();
    }
  }

  /// 保存上次连接成功的 IP
  void _saveLastHost(String host) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyLastHost, host);
    } catch (_) {}
  }

  /// 发送音乐控制命令
  void sendAction(String actionId, {int? value}) {
    _wsClient?.sendCommand(actionId, value: value);
  }

  /// 断开连接
  Future<void> disconnect() async {
    await _discoveryClient.stop();
    _discoveryStarted = false;
    await _lanScanner.stop();
    _lanScanStarted = false;
    await _discoverySubscription?.cancel();
    await _lanScanSubscription?.cancel();
    await _statusSubscription?.cancel();
    await _resultSubscription?.cancel();
    await _connectionSubscription?.cancel();
    await _wsClient?.dispose();
    _wsClient = null;
    _connectedHost = null;
    _connectingHost = null;
    _updateState(AgentConnectionState.idle);
  }

  /// 连接成功后停止 UDP 和 LAN 后台扫描，避免已连接状态下的资源浪费
  void _stopPassiveDiscovery() {
    // 取消 listener 后再 stop 底层 source：避免重连周期重新 startAutoDiscovery
    // 时旧 sub + 新 sub 并存，同一发现事件被处理多次。
    _discoverySubscription?.cancel();
    _discoverySubscription = null;
    _lanScanSubscription?.cancel();
    _lanScanSubscription = null;
    _discoveryClient.stop();
    _discoveryStarted = false;
    _lanScanner.stop();
    _lanScanStarted = false;
  }

  void _updateState(AgentConnectionState newState) {
    _state = newState;
    _connectionStateController.add(newState);
  }

  Future<void> dispose() async {
    _isDisposed = true;
    await disconnect();
    await _discoveryClient.dispose();
    await _lanScanner.dispose();
    await _connectionStateController.close();
    await _statusController.close();
    await _resultController.close();
  }
}
