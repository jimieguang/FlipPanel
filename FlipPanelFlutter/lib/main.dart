import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'network/network.dart';
import 'state/state.dart';
import 'ui/theme/theme.dart';
import 'ui/main_screen.dart';

const _platformChannel = MethodChannel('com.reuse.flippanel/multicast');

Future<void> _acquireMulticastLock() async {
  try {
    await _platformChannel.invokeMethod('acquireMulticastLock');
  } catch (_) {
    // 非 Android 平台或旧设备，忽略
  }
}

Future<void> _startForegroundService() async {
  try {
    await _platformChannel.invokeMethod('startForegroundService');
  } catch (_) {
    // 非 Android 平台或旧设备，忽略
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 强制竖屏（Z Flip 4 半折叠态为竖屏）
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // 真全屏：隐藏系统栏，自绘顶部指示器
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // 屏幕常亮
  WakelockPlus.enable();

  // 获取 WiFi 多播锁（Android 必须，否则收不到 UDP 广播）
  await _acquireMulticastLock();

  // 拉起前台服务（WakeLock + WifiLock + 通知栏常驻）
  await _startForegroundService();

  // 初始化核心仓库
  final repository = AgentRepository();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => ConnectionController(repository),
        ),
        ChangeNotifierProvider(
          create: (_) => MusicController(repository),
        ),
      ],
      child: FlipPanelApp(repository: repository),
    ),
  );
}

class FlipPanelApp extends StatefulWidget {
  final AgentRepository repository;

  const FlipPanelApp({super.key, required this.repository});

  @override
  State<FlipPanelApp> createState() => _FlipPanelAppState();
}

class _FlipPanelAppState extends State<FlipPanelApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 启动 UDP 自动发现
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ConnectionController>().startDiscovery();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.repository.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 从后台恢复时，如果断开则重新连接
      final connState = context.read<ConnectionController>();
      if (!connState.isConnected) {
        connState.startDiscovery();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FlipPanel',
      theme: FlipPanelTheme.theme,
      debugShowCheckedModeBanner: false,
      home: const MainScreen(),
    );
  }
}
