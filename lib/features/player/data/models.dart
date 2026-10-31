/// 播放器数据模型。

/// 音质等级，按从高到低排序（super > high > flac > 320 > 128）。
enum AudioQuality {
  q128('128', '标准'),
  q320('320', '高品'),
  flac('flac', '无损'),
  high('high', 'Hi-Res'),
  superQuality('super', '臻品母带');

  const AudioQuality(this.value, this.label);
  final String value;
  final String label;

  /// 从高到低的降级顺序。
  static const List<AudioQuality> fallbackOrder = [
    superQuality,
    high,
    flac,
    q320,
    q128,
  ];

  static AudioQuality fromString(String? s) {
    for (final q in values) {
      if (q.value == s) return q;
    }
    return q128;
  }
}

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
  });

  final String hash;
  final String albumId;
  final String albumAudioId;
  final String name;
  final String artist;
  final String cover;
  final Duration duration;
  final AudioQuality quality;

  Song copyWith({
    String? hash,
    String? albumId,
    String? albumAudioId,
    String? name,
    String? artist,
    String? cover,
    Duration? duration,
    AudioQuality? quality,
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
    );
  }

  /// 兼容 /search 和 /privilege/lite 的返回结构。
  factory Song.fromJson(Map<String, dynamic> json) {
    // /search 返回字段常见：FileHash / AudioID / SongName / SingerName / Image / Duration
    // /privilege/lite 返回字段：hash / album_id / album_audio_id / songname / singername / cover / duration(秒或毫秒)
    String str(List<String> keys) {
      for (final k in keys) {
        final v = json[k];
        if (v != null && '$v'.isNotEmpty) return '$v';
      }
      return '';
    }

    // 歌手可能来自 singername 或 singer 列表
    var artist = str(['singername', 'SingerName', 'singer_name', 'author_name']);
    if (artist.isEmpty && json['singer'] is List) {
      artist = (json['singer'] as List)
          .map((e) => e is Map ? '${e['name'] ?? ''}' : '$e')
          .where((s) => s.isNotEmpty)
          .join('、');
    }

    var cover = str(['cover', 'Image', 'img', 'album_img']);
    cover = cover.replaceAll('{size}', '400');

    // 时长：秒或毫秒，尽量兼容
    var duration = Duration.zero;
    final durRaw = json['duration'] ?? json['Duration'];
    if (durRaw is num) {
      // 大于 10000 视为毫秒
      duration = durRaw > 10000
          ? Duration(milliseconds: durRaw.round())
          : Duration(seconds: durRaw.round());
    }

    return Song(
      hash: str(['hash', 'FileHash', 'file_hash', 'Hash']),
      albumId: str(['album_id', 'albumid', 'AlbumID', 'albumID']),
      albumAudioId:
          str(['album_audio_id', 'albumAudioId', 'AudioID', 'audio_id']),
      name: str(['songname', 'SongName', 'song_name', 'filename', 'FileName']),
      artist: artist,
      cover: cover,
      duration: duration,
      quality: AudioQuality.fromString(
          str(['quality', 'best_free_quality', 'quality_vip'])),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Song && other.hash == hash && other.hash.isNotEmpty;

  @override
  int get hashCode => hash.hashCode;
}
