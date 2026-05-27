import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';

import '../protocol/protocol.dart';

/// WebSocket 客户端封装
/// 负责与 PC Agent 建立 WebSocket 长连接，接收状态消息，发送命令
class StatusWebSocketClient {
  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _pingTimer;
  Timer? _staleTimer;
  Timer? _reconnectTimer;

  final StreamController<DeviceStatusMessage> _statusController =
      StreamController<DeviceStatusMessage>.broadcast();
  final StreamController<CommandResultMessage> _resultController =
      StreamController<CommandResultMessage>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  bool _isConnected = false;
  bool _shouldReconnect = true;
  bool _isDisposed = false;
  String? _currentUrl;
  int _reconnectAttempts = 0;
  DateTime? _lastInboundAt;
  static const int _maxReconnectAttempts = 30;

  /// 半断开检测：PC 周期性推送 status（≈ 1-2s），若超过该窗口未收到任何入站
  /// 消息（status / commandResult / ping echo），认为链路半死，主动断开触发重连。
  /// 避免 Wi-Fi 切换 / NAT 老化场景等系统 socket 超时（数十秒到数分钟）。
  static const Duration _staleThreshold = Duration(seconds: 8);
  static const Duration _staleCheckInterval = Duration(seconds: 2);

  Stream<DeviceStatusMessage> get statusStream => _statusController.stream;
  Stream<CommandResultMessage> get resultStream => _resultController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  bool get isConnected => _isConnected;

  Future<void> connect(String host,
      {int port = AgentProtocol.webSocketPort}) async {
    _shouldReconnect = true;
    _currentUrl = 'ws://$host:$port${AgentProtocol.wsEndpoint}';
    await _doConnect();
  }

  Future<void> _doConnect() async {
    if (_currentUrl == null || _isDisposed || !_shouldReconnect) return;

    try {
      final uri = Uri.parse(_currentUrl!);
      _channel = IOWebSocketChannel.connect(
        uri,
        connectTimeout: const Duration(seconds: 10),
      );

      _subscription = _channel!.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: _onError,
      );

      _isConnected = true;
      _reconnectAttempts = 0;
      _lastInboundAt = DateTime.now();
      _safeAddConnection(true);

      _startPing();
      _startStaleWatchdog();
    } catch (_) {
      _isConnected = false;
      _safeAddConnection(false);
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic data) {
    _lastInboundAt = DateTime.now();
    try {
      final json = jsonDecode(data as String) as Map<String, dynamic>;
      final messageType = json['messageType'] as String?;

      if (messageType == 'status') {
        if (!_statusController.isClosed) {
          _statusController.add(DeviceStatusMessage.fromJson(json));
        }
      } else if (messageType == 'commandResult') {
        if (!_resultController.isClosed) {
          _resultController.add(CommandResultMessage.fromJson(json));
        }
      }
    } catch (_) {
      // 忽略无法解析的消息（可能是 ping/pong 文本帧）
    }
  }

  void _onDisconnected() {
    if (!_isConnected) return; // 避免重复触发
    _isConnected = false;
    _safeAddConnection(false);
    _stopPing();
    _stopStaleWatchdog();
    if (_shouldReconnect) {
      _scheduleReconnect();
    }
  }

  void _onError(dynamic error) {
    if (!_isConnected) return;
    _isConnected = false;
    _safeAddConnection(false);
    _stopPing();
    _stopStaleWatchdog();
    if (_shouldReconnect) {
      _scheduleReconnect();
    }
  }

  void _startPing() {
    _stopPing();
    _pingTimer = Timer.periodic(AgentProtocol.pingInterval, (_) {
      if (_isConnected) {
        try {
          _channel?.sink.add('ping');
        } catch (_) {
          _onDisconnected();
        }
      }
    });
  }

  void _stopPing() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  void _startStaleWatchdog() {
    _stopStaleWatchdog();
    _staleTimer = Timer.periodic(_staleCheckInterval, (_) {
      if (!_isConnected) return;
      final last = _lastInboundAt;
      if (last == null) return;
      if (DateTime.now().difference(last) > _staleThreshold) {
        // 半断开：主动断开触发重连，比等系统 socket 超时快得多
        try {
          _channel?.sink.close();
        } catch (_) {}
        _onDisconnected();
      }
    });
  }

  void _stopStaleWatchdog() {
    _staleTimer?.cancel();
    _staleTimer = null;
  }

  /// 在 controller 已 close 时静默丢弃（dispose 与 reconnect timer 之间存在
  /// 微小竞态窗口：cancel 在 timer 已 fire 后无效，回调仍会跑一次 _doConnect）
  void _safeAddConnection(bool value) {
    if (_isDisposed || _connectionController.isClosed) return;
    _connectionController.add(value);
  }

  void _scheduleReconnect() {
    if (_isDisposed || !_shouldReconnect || _currentUrl == null) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) return;

    _reconnectTimer?.cancel();
    final delay = Duration(
      seconds: (AgentProtocol.reconnectDelay.inSeconds *
              (1 + _reconnectAttempts * 0.5))
          .round()
          .clamp(3, 30),
    );
    _reconnectTimer = Timer(delay, () {
      if (_isDisposed || !_shouldReconnect) return;
      _reconnectAttempts++;
      _doConnect();
    });
  }

  void sendCommand(String actionId, {int? value}) {
    if (!_isConnected) return;
    final command = CommandMessage(actionId: actionId, value: value);
    try {
      _channel?.sink.add(jsonEncode(command.toJson()));
    } catch (_) {
      // 发送失败
    }
  }

  Future<void> disconnect() async {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopPing();
    _stopStaleWatchdog();
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _isConnected = false;
    _safeAddConnection(false);
  }

  Future<void> dispose() async {
    _isDisposed = true;
    await disconnect();
    await _statusController.close();
    await _resultController.close();
    await _connectionController.close();
  }
}
