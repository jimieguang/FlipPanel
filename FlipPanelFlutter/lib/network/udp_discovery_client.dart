import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol/protocol.dart';

/// UDP 广播发现客户端
/// 监听 PC Agent 的 UDP 广播，自动发现局域网内的 PC
class UdpDiscoveryClient {
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  final StreamController<DiscoveryMessage> _controller =
      StreamController<DiscoveryMessage>.broadcast();

  bool _isRunning = false;

  Stream<DiscoveryMessage> get discoveries => _controller.stream;

  /// 启动 UDP 发现，绑定端口并持续监听广播
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;

    while (_isRunning) {
      final errorCompleter = Completer<void>();
      try {
        _socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          AgentProtocol.udpBroadcastPort,
          reuseAddress: true,
        );
        _socket!.broadcastEnabled = true;

        _subscription = _socket!.listen(
          (event) {
            if (event == RawSocketEvent.read) {
              final datagram = _socket!.receive();
              if (datagram != null) {
                _handleDatagram(datagram);
              }
            } else if (event == RawSocketEvent.closed) {
              if (!errorCompleter.isCompleted) errorCompleter.complete();
            }
          },
          onError: (_) {
            if (!errorCompleter.isCompleted) errorCompleter.complete();
          },
          onDone: () {
            if (!errorCompleter.isCompleted) errorCompleter.complete();
          },
          cancelOnError: true,
        );

        // 持续监听，直到 stop() 触发 _cleanup 或 socket 出错
        await errorCompleter.future;
        _cleanup();
        if (!_isRunning) break;
        // socket 异常关闭时退避后重新 bind
        await Future.delayed(AgentProtocol.udpRetryDelay);
      } catch (_) {
        _cleanup();
        if (!_isRunning) break;
        await Future.delayed(AgentProtocol.udpRetryDelay);
      }
    }
  }

  void _handleDatagram(Datagram datagram) {
    try {
      final message = utf8.decode(datagram.data);
      final json = jsonDecode(message) as Map<String, dynamic>;
      if (json['protocolVersion'] != null) {
        _controller.add(DiscoveryMessage.fromJson(json));
      }
    } catch (_) {
      // 忽略无效的广播包
    }
  }

  void _cleanup() {
    _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
  }

  Future<void> stop() async {
    _isRunning = false;
    _cleanup();
    // 不关闭 _controller：允许后续重新 start()
  }

  Future<void> dispose() async {
    _isRunning = false;
    _cleanup();
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}
