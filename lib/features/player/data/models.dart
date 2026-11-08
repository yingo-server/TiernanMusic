import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/quality.dart';

/// 播放器数据模型。

/// 单曲信息。
class Song {
  const Song({
    required this.hash,
    this.albumId = '',
    this.albumAudioId = '',
    required this.name,
    this.artist = '',
    this.cover = '',
    this.duration = Duration.zero,
    this.quality = AudioQuality.q128,
    this.localPath,
  });

  final String hash;
  final String albumId;
  final String albumAudioId;
  final String name;
  final String artist;
  final String cover;
  final Duration duration;
  final AudioQuality quality;

  /// 本地已下载资源（存在时优先离线播放，不走网络解析）。
  ///
  /// 两种形态：
  /// - 绝对路径（Android ≤9 / 降级到 App 私有目录）：`/storage/.../song.mp3`
  /// - MediaStore Uri（Android 10+）：`content://media/external/audio/media/123`
  ///
  /// 播放器用 [Uri.parse] 统一处理：`file://` 与 `content://` 都支持。
  final String? localPath;

  Song copyWith({
    String? hash,
    String? albumId,
    String? albumAudioId,
    String? name,
    String? artist,
    String? cover,
    Duration? duration,
    AudioQuality? quality,
    String? localPath,
    bool clearLocalPath = false,
  }) {
    return Song(
      hash: hash ?? this.hash,
      albumId: albumId ?? this.albumId,
      albumAudioId: albumAudioId ?? this.albumAudioId,
      name: name ?? this.name,
      artist: artist ?? this.artist,
      cover: cover ?? this.cover,
      duration: duration ?? this.duration,
      quality: quality ?? this.quality,
      // F4-15（审查②-B，P1）：nullable 字段无法用 `localPath: null` 清除
      // （`null ?? this.localPath` 永远是旧值），导致「清理失效本地源」是 no-op。
      // 第 3 条：契约必须显式——清除语义由独立布尔参数表达，编译器也能兜住。
      localPath: clearLocalPath ? null : (localPath ?? this.localPath),
    );
  }

  /// 兼容 /search 和 /privilege/lite 的返回结构。
  ///
  /// 实测字段真值：
  /// - `/search?type=song`：`FileHash` / `OriSongName`（纯歌名）/ `FileName`（"歌手 - 歌名"）
  ///   / `SingerName` / `Duration`（**秒**）/ `Image` / `AlbumID` / `MixSongID`（= album_audio_id）
  ///   / `Audioid`（= audio_id，**不是** album_audio_id）。
  /// - `/privilege/lite`：`hash` / `album_id` / `album_audio_id` / `name`（"歌手 - 歌名"）
  ///   / `singername` / `quality` / `info.duration`（**毫秒**）/ `info.image`。
  factory Song.fromJson(Map<String, dynamic> json) {
    // /search 返回字段常见：FileHash / Audioid / OriSongName / SingerName / Image / Duration
    // /privilege/lite 返回字段：hash / album_id / album_audio_id / name / singername / info.*
    String str(List<String> keys) {
      for (final k in keys) {
        final v = json[k];
        if (v != null && '$v'.isNotEmpty) return '$v';
      }
      return '';
    }

    // 歌手可能来自 singername 或 singer 列表
    var artist = str(['singername', 'SingerName', 'singer_name', 'author_name']);
    if (artist.isEmpty) {
      final singer = json['singer'];
      if (singer is List) {
        artist = singer
            .map((e) => e is Map ? '${e['name'] ?? ''}' : '$e')
            .where((s) => s.isNotEmpty)
            .join('、');
      } else if (singer != null) {
        artist = '$singer';
      }
    }

    final info = json['info'] is Map ? json['info'] as Map : const {};
    var cover = str(['cover', 'Image', 'img', 'album_img']);
    if (cover.isEmpty) cover = '${info['image'] ?? ''}';
    // /privilege/lite 的 trans_param.union_cover 同样是真实封面。
    if (cover.isEmpty) {
      final transParam = json['trans_param'];
      if (transParam is Map) cover = '${transParam['union_cover'] ?? ''}';
    }
    cover = cover.replaceAll('{size}', '400');

    // 歌名：/search 有独立的 OriSongName；/privilege/lite 只有 "歌手 - 歌名" 形式的 name。
    var name = str(['songname', 'SongName', 'song_name', 'OriSongName']);
    if (name.isEmpty) {
      final raw = str(['name', 'filename', 'FileName']);
      // "周杰伦 - 晴天" → 去掉歌手前缀（歌名自身可能含分隔符，只剥一次前缀）。
      final sep = raw.indexOf(' - ');
      if (sep > 0 &&
          (artist.isEmpty || raw.substring(0, sep) == artist)) {
        name = raw.substring(sep + 3).trim();
      } else {
        name = raw;
      }
    }

    // 时长单位按字段区分，避免毫秒/秒混用：
    // - duration / Duration / time_length 为**秒**
    // - timelength / timelen / info.duration 为**毫秒**
    var duration = Duration.zero;
    void setDuration(dynamic raw, {required bool millis}) {
      if (duration > Duration.zero) return;
      if (raw is num) {
        duration = millis
            ? Duration(milliseconds: raw.round())
            : Duration(seconds: raw.round());
      } else if (raw != null) {
        final v = int.tryParse('$raw');
        if (v != null) {
          duration = millis
              ? Duration(milliseconds: v)
              : Duration(seconds: v);
        }
      }
    }

    for (final key in ['duration', 'Duration', 'time_length']) {
      if (json.containsKey(key)) setDuration(json[key], millis: false);
    }
    for (final key in ['timelength', 'timelen', 'timeLength']) {
      if (json.containsKey(key)) setDuration(json[key], millis: true);
    }
    if (info['duration'] != null) setDuration(info['duration'], millis: true);

    return Song(
      hash: str(['hash', 'FileHash', 'file_hash', 'Hash']),
      albumId: str(['album_id', 'albumid', 'AlbumID', 'albumID']),
      // MixSongID 才是 album_audio_id；Audioid/audio_id 是 audio_id（不同语义）。
      albumAudioId:
          str(['album_audio_id', 'albumAudioId', 'MixSongID', 'MixSongId']),
      name: name,
      artist: artist,
      cover: cover,
      duration: duration,
      // quality_vip 可为 null，best_free_quality 在该部署版中不存在。
      quality: AudioQuality.fromString(str(['quality'])),
      localPath:
          (json['localPath'] is String && (json['localPath'] as String).isNotEmpty)
              ? json['localPath'] as String
              : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Song && other.hash == hash && other.hash.isNotEmpty;

  @override
  int get hashCode => hash.hashCode;
}
