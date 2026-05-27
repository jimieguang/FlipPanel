/// 与 PC 端 ReuseDisplay.Agent 的 WebSocket + UDP 协议常量
class AgentProtocol {
  AgentProtocol._();

  static const int protocolVersion = 2;
  static const int udpBroadcastPort = 50570;
  static const int webSocketPort = 50571;
  static const String wsEndpoint = '/ws';

  static const Duration pingInterval = Duration(seconds: 15);
  static const Duration reconnectDelay = Duration(seconds: 3);
  static const Duration udpTimeout = Duration(seconds: 12);
  static const Duration udpRetryDelay = Duration(milliseconds: 1500);

  // 音乐控制动作 ID（基于 ncm-cli 命令）
  static const String actionLaunch = 'music.launch';
  static const String actionPlayPause = 'music.playPause'; // PC 端根据状态自动选择 pause/resume
  static const String actionPause = 'music.pause';
  static const String actionResume = 'music.resume';
  static const String actionNext = 'music.next';
  static const String actionPrevious = 'music.previous';
  static const String actionStop = 'music.stop';
  static const String actionLike = 'music.like';
  static const String actionDislike = 'music.dislike';
  static const String actionSetVolume = 'music.setVolume';
}
