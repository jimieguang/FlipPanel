/// UDP 广播发现消息模型
class DiscoveryMessage {
  final int protocolVersion;
  final String deviceName;
  final String hostAddress;
  final int hostPort;
  final String endpoint;
  final List<String> capabilities;
  final DateTime timestampUtc;

  DiscoveryMessage({
    required this.protocolVersion,
    required this.deviceName,
    required this.hostAddress,
    required this.hostPort,
    required this.endpoint,
    required this.capabilities,
    required this.timestampUtc,
  });

  factory DiscoveryMessage.fromJson(Map<String, dynamic> json) {
    return DiscoveryMessage(
      protocolVersion: json['protocolVersion'] as int? ?? 1,
      deviceName: json['deviceName'] as String? ?? 'Unknown',
      hostAddress: json['hostAddress'] as String? ?? '',
      hostPort: json['hostPort'] as int? ?? 50571,
      endpoint: json['endpoint'] as String? ?? '',
      capabilities: (json['capabilities'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      timestampUtc: DateTime.tryParse(json['timestampUtc'] as String? ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

/// WebSocket 设备状态消息模型
class DeviceStatusMessage {
  final String messageType;
  final int protocolVersion;
  final String deviceName;
  final String hostAddress;
  final int hostPort;
  final double cpuUsagePercent;
  final double memoryUsedGb;
  final double memoryTotalGb;
  final double memoryUsedPercent;
  final int uptimeMinutes;
  final String activeProcessName;
  final double topProcessCpuPercent;
  final double networkReceiveMbps;
  final double networkSendMbps;
  final double systemDriveUsedGb;
  final double systemDriveFreeGb;
  final int processorCount;
  final String osVersion;

  // 音乐状态
  final String? musicTrackId;
  final String? musicTitle;
  final String? musicArtist;
  final String? musicPlaybackState;
  final int? musicVolumePercent;
  final double? musicPositionSeconds;
  final double? musicDurationSeconds;
  final bool? musicIsLiked;
  final String? musicLyric;
  final String? musicCoverImgUrl;

  final DateTime timestampUtc;

  DeviceStatusMessage({
    required this.messageType,
    required this.protocolVersion,
    required this.deviceName,
    required this.hostAddress,
    required this.hostPort,
    required this.cpuUsagePercent,
    required this.memoryUsedGb,
    required this.memoryTotalGb,
    required this.memoryUsedPercent,
    required this.uptimeMinutes,
    required this.activeProcessName,
    required this.topProcessCpuPercent,
    required this.networkReceiveMbps,
    required this.networkSendMbps,
    required this.systemDriveUsedGb,
    required this.systemDriveFreeGb,
    required this.processorCount,
    required this.osVersion,
    this.musicTrackId,
    this.musicTitle,
    this.musicArtist,
    this.musicPlaybackState,
    this.musicVolumePercent,
    this.musicPositionSeconds,
    this.musicDurationSeconds,
    this.musicIsLiked,
    this.musicLyric,
    this.musicCoverImgUrl,
    required this.timestampUtc,
  });

  factory DeviceStatusMessage.fromJson(Map<String, dynamic> json) {
    return DeviceStatusMessage(
      messageType: json['messageType'] as String? ?? 'status',
      protocolVersion: json['protocolVersion'] as int? ?? 1,
      deviceName: json['deviceName'] as String? ?? '',
      hostAddress: json['hostAddress'] as String? ?? '',
      hostPort: json['hostPort'] as int? ?? 50571,
      cpuUsagePercent: (json['cpuUsagePercent'] as num?)?.toDouble() ?? 0,
      memoryUsedGb: (json['memoryUsedGb'] as num?)?.toDouble() ?? 0,
      memoryTotalGb: (json['memoryTotalGb'] as num?)?.toDouble() ?? 0,
      memoryUsedPercent: (json['memoryUsedPercent'] as num?)?.toDouble() ?? 0,
      uptimeMinutes: json['uptimeMinutes'] as int? ?? 0,
      activeProcessName: json['activeProcessName'] as String? ?? '',
      topProcessCpuPercent:
          (json['topProcessCpuPercent'] as num?)?.toDouble() ?? 0,
      networkReceiveMbps:
          (json['networkReceiveMbps'] as num?)?.toDouble() ?? 0,
      networkSendMbps: (json['networkSendMbps'] as num?)?.toDouble() ?? 0,
      systemDriveUsedGb:
          (json['systemDriveUsedGb'] as num?)?.toDouble() ?? 0,
      systemDriveFreeGb:
          (json['systemDriveFreeGb'] as num?)?.toDouble() ?? 0,
      processorCount: json['processorCount'] as int? ?? 0,
      osVersion: json['osVersion'] as String? ?? '',
      musicTrackId: json['musicTrackId'] as String?,
      musicTitle: json['musicTitle'] as String?,
      musicArtist: json['musicArtist'] as String?,
      musicPlaybackState: json['musicPlaybackState'] as String?,
      musicVolumePercent: json['musicVolumePercent'] as int?,
      musicPositionSeconds:
          (json['musicPositionSeconds'] as num?)?.toDouble(),
      musicDurationSeconds:
          (json['musicDurationSeconds'] as num?)?.toDouble(),
      musicIsLiked: json['musicIsLiked'] as bool?,
      musicLyric: json['musicLyric'] as String?,
      musicCoverImgUrl: json['musicCoverImgUrl'] as String?,
      timestampUtc: DateTime.tryParse(json['timestampUtc'] as String? ?? '') ??
          DateTime.now().toUtc(),
    );
  }

  bool get isPlaying =>
      musicPlaybackState == 'playing' ||
      musicPlaybackState == '播放中' ||
      musicPlaybackState?.toLowerCase() == 'playing';
}

/// 命令消息（Flutter -> PC）
class CommandMessage {
  final String messageType;
  final String actionId;
  final int? value;

  CommandMessage({required this.actionId, this.value})
      : messageType = 'command';

  Map<String, dynamic> toJson() => {
        'messageType': messageType,
        'actionId': actionId,
        if (value != null) 'value': value,
      };
}

/// 命令执行结果消息（PC -> Flutter）
class CommandResultMessage {
  final String messageType;
  final String actionId;
  final bool success;
  final String? message;
  final DateTime timestampUtc;

  CommandResultMessage({
    required this.messageType,
    required this.actionId,
    required this.success,
    this.message,
    required this.timestampUtc,
  });

  factory CommandResultMessage.fromJson(Map<String, dynamic> json) {
    return CommandResultMessage(
      messageType: json['messageType'] as String? ?? 'commandResult',
      actionId: json['actionId'] as String? ?? '',
      success: json['success'] as bool? ?? false,
      message: json['message'] as String?,
      timestampUtc: DateTime.tryParse(json['timestampUtc'] as String? ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}
