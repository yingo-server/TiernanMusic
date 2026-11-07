/// 下载任务模型与状态枚举。
library;

/// 下载内容类型。
enum DownloadTaskType {
  /// 音频（歌曲本体）
  audio,

  /// 封面图
  cover,

  /// 歌词（KRC 原文 + 翻译文本）
  lyric,

  /// MV 视频
  mv,
}

extension DownloadTaskTypeX on DownloadTaskType {
  /// 文件扩展名。
  String get fileExtension => switch (this) {
        DownloadTaskType.audio => '.mp3',
        DownloadTaskType.cover => '.jpg',
        DownloadTaskType.lyric => '.txt',
        DownloadTaskType.mv => '.mp4',
      };
}

/// 任务状态。
enum DownloadTaskStatus {
  /// 排队等待
  queued,

  /// 下载中
  running,

  /// 已暂停
  paused,

  /// 已完成
  completed,

  /// 失败
  failed,
}

/// 单个下载任务。
class DownloadTask {
  const DownloadTask({
    required this.hash,
    required this.type,
    this.title = '',
    this.artist = '',
    this.coverUrl = '',
    this.mvHash = '',
    this.albumId = '',
    this.albumAudioId = '',
    this.quality = '128',
    this.durationSec = 0,
    this.targetLanguage = 'zh_CN',
    this.filePath = '',
    this.mediaUri = '',
    this.displayName = '',
    this.displayPath = '',
    this.received = 0,
    this.total = 0,
    this.realTempPath = '',
    // V399-B4：所选下载片段类型（'full'/'trial'/'climax'，下载择优记录）
    this.segment = 'full',
    this.status = DownloadTaskStatus.queued,
    this.error,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  /// 歌曲 hash（MV 用歌曲 hash，文件名加后缀区分）
  final String hash;
  final DownloadTaskType type;
  final String title;
  final String artist;
  final String coverUrl;

  /// MV 视频 hash（仅 MV 任务使用）
  final String mvHash;
  final String albumId;
  final String albumAudioId;
  final String quality;
  final int durationSec;

  /// 歌词翻译目标语言
  final String targetLanguage;

  /// 本地文件绝对路径（Android 9 及以下 / 降级目录）
  final String filePath;

  /// MediaStore Uri（Android 10+）
  final String mediaUri;

  /// 公共目录中的文件名
  final String displayName;

  /// 展示给用户的存放位置
  final String displayPath;

  /// 已下载字节
  final int received;

  /// 总字节（未知时为 0）
  final int total;

  /// V34-05（v3.4 审查①，P1）：真实临时文件路径（audio 由服务端
  /// extName 决定扩展名，可能非 .mp3）——remove() 按它清理，防泄漏。
  final String realTempPath;

  /// V399-B4：非 VIP 下载择优后所选片段类型（'full'/'trial'/'climax'）。
  /// 元信息记录，UI 无需变化（任务书 B4）。
  final String segment;

  final DownloadTaskStatus status;

  /// 失败原因
  final String? error;

  final int createdAt;
  final int updatedAt;

  /// 任务唯一 id：类型 + hash
  String get id => '${type.name}_$hash';

  /// 进度（0~1），总大小未知时为 null。
  double? get progress {
    if (total <= 0) return null;
    final v = received / total;
    return v.clamp(0.0, 1.0);
  }

  bool get isActive =>
      status == DownloadTaskStatus.queued ||
      status == DownloadTaskStatus.running;

  DownloadTask copyWith({
    String? hash,
    DownloadTaskType? type,
    String? title,
    String? artist,
    String? coverUrl,
    String? mvHash,
    String? albumId,
    String? albumAudioId,
    String? quality,
    int? durationSec,
    String? targetLanguage,
    String? filePath,
    String? mediaUri,
    String? displayName,
    String? displayPath,
    int? received,
    int? total,
    String? realTempPath,
    String? segment,
    DownloadTaskStatus? status,
    String? error,
    bool clearError = false,
    int? createdAt,
    int? updatedAt,
  }) {
    return DownloadTask(
      hash: hash ?? this.hash,
      type: type ?? this.type,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      coverUrl: coverUrl ?? this.coverUrl,
      mvHash: mvHash ?? this.mvHash,
      albumId: albumId ?? this.albumId,
      albumAudioId: albumAudioId ?? this.albumAudioId,
      quality: quality ?? this.quality,
      durationSec: durationSec ?? this.durationSec,
      targetLanguage: targetLanguage ?? this.targetLanguage,
      filePath: filePath ?? this.filePath,
      mediaUri: mediaUri ?? this.mediaUri,
      displayName: displayName ?? this.displayName,
      displayPath: displayPath ?? this.displayPath,
      received: received ?? this.received,
      total: total ?? this.total,
      realTempPath: realTempPath ?? this.realTempPath,
      segment: segment ?? this.segment,
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'hash': hash,
        'type': type.name,
        'title': title,
        'artist': artist,
        'coverUrl': coverUrl,
        'mvHash': mvHash,
        'albumId': albumId,
        'albumAudioId': albumAudioId,
        'quality': quality,
        'durationSec': durationSec,
        'targetLanguage': targetLanguage,
        'filePath': filePath,
        'mediaUri': mediaUri,
        'displayName': displayName,
        'displayPath': displayPath,
        'received': received,
        'total': total,
        'realTempPath': realTempPath,
        'segment': segment,
        'status': status.name,
        'error': error,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory DownloadTask.fromJson(Map<dynamic, dynamic> json) {
    final typeName = '${json['type'] ?? ''}';
    final statusName = '${json['status'] ?? ''}';
    return DownloadTask(
      hash: '${json['hash'] ?? ''}',
      type: DownloadTaskType.values.firstWhere(
        (t) => t.name == typeName,
        orElse: () => DownloadTaskType.audio,
      ),
      title: '${json['title'] ?? ''}',
      artist: '${json['artist'] ?? ''}',
      coverUrl: '${json['coverUrl'] ?? ''}',
      mvHash: '${json['mvHash'] ?? ''}',
      albumId: '${json['albumId'] ?? ''}',
      albumAudioId: '${json['albumAudioId'] ?? ''}',
      quality: '${json['quality'] ?? '128'}',
      durationSec: (json['durationSec'] is int)
          ? json['durationSec'] as int
          : int.tryParse('${json['durationSec'] ?? 0}') ?? 0,
      targetLanguage: '${json['targetLanguage'] ?? 'zh_CN'}',
      filePath: '${json['filePath'] ?? ''}',
      mediaUri: '${json['mediaUri'] ?? ''}',
      displayName: '${json['displayName'] ?? ''}',
      displayPath: '${json['displayPath'] ?? ''}',
      received: (json['received'] is int)
          ? json['received'] as int
          : int.tryParse('${json['received'] ?? 0}') ?? 0,
      total: (json['total'] is int)
          ? json['total'] as int
          : int.tryParse('${json['total'] ?? 0}') ?? 0,
      realTempPath: '${json['realTempPath'] ?? ''}',
      segment: json['segment'] is String && (json['segment'] as String).isNotEmpty
          ? json['segment'] as String
          : 'full',
      status: DownloadTaskStatus.values.firstWhere(
        (s) => s.name == statusName,
        orElse: () => DownloadTaskStatus.queued,
      ),
      error: json['error'] == null ? null : '${json['error']}',
      createdAt: (json['createdAt'] is int)
          ? json['createdAt'] as int
          : int.tryParse('${json['createdAt'] ?? 0}') ?? 0,
      updatedAt: (json['updatedAt'] is int)
          ? json['updatedAt'] as int
          : int.tryParse('${json['updatedAt'] ?? 0}') ?? 0,
    );
  }
}
