import '../../../core/api/kugou_api_client.dart';
import '../../../core/cache/cache_manager.dart';
import '../../../core/config/app_config.dart';

class MvRepository {
  MvRepository(this._api);
  final KugouApiClient _api;

  /// 歌曲关联 MV
  ///
  /// 实测：`/kmr/audio/mv` 的 `data` 是**嵌套数组** `List<List<Mv>>`，
  /// 每项含 `mv_name` / `authors[]` / `video_id` / `duration`（**毫秒**）
  /// / `mkv` / `h264` / `h265` 三套 hash 容器。
  /// 该接口要 **mixsongid**（传 audio_id 会返回 `[{}]`）。
  Future<List<MvInfo>> findBySong(String albumAudioId) async {
    final q = {
      'album_audio_id': albumAudioId,
      'fields': 'mkv,tags,h264,h265,authors',
    };
    final cacheKey = MemoryCache.keyOf('/kmr/audio/mv', q);
    final cached = MemoryCache.instance.get<Map<String, dynamic>>(cacheKey);
    final data = cached ?? await _api.get('/kmr/audio/mv', query: q);
    if (cached == null) MemoryCache.instance.set(cacheKey, data);

    final raw = data['data'];
    final groups = raw is List ? raw : const [];
    final result = <MvInfo>[];
    for (final group in groups) {
      if (group is List) {
        for (final item in group) {
          if (item is Map) {
            result.add(MvInfo.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      } else if (group is Map) {
        result.add(MvInfo.fromJson(Map<String, dynamic>.from(group)));
      }
    }
    return result;
  }

  /// 视频详情
  ///
  /// 实测：`/video/detail` 的 `data` 是**数组**（不是对象），首项为视频信息；
  /// 清晰度 hash 平铺在顶层（`hd_hash` / `sd_hash` / `qhd_hash` / `fhd_hash`
  /// / `ld_hash`），mkv 容器的 hash 另名为 `mkv_sd_hash` / `mkv_qhd_hash`。
  Future<MvDetail> fetchDetail(String videoId) async {
    final cacheKey = MemoryCache.keyOf('/video/detail', {'id': videoId});
    final cached = MemoryCache.instance.get<Map<String, dynamic>>(cacheKey);
    final data =
        cached ?? await _api.get('/video/detail', query: {'id': videoId});
    if (cached == null) MemoryCache.instance.set(cacheKey, data);
    return MvDetail.fromJson(data);
  }

  /// 解析播放地址（HTTP → 代理 HTTPS）
  ///
  /// [videoIdOrHash] 可以是 video_id（117613）或视频 hash（C95D…）。
  /// `/video/url` 只认 **hash**（传 video_id 返回 `Not found`），
  /// `/video/detail` 只认 **video_id**（传 hash 返回 `invalid param`），
  /// 因此这里做一次互转兜底。
  Future<String> resolvePlayUrl(String videoIdOrHash) async {
    var hash = videoIdOrHash;
    if (!_looksLikeHash(hash)) {
      // video_id → 通过详情接口换成视频 hash。
      final detail = await fetchDetail(videoIdOrHash);
      final resolved = detail.bestHash;
      if (resolved == null || resolved.isEmpty) {
        throw ApiException(-1, 'MV 暂无播放地址');
      }
      hash = resolved;
    }
    final data = await _api.get('/video/url', query: {'hash': hash});
    final d = data['data'];
    if (d is! Map) throw ApiException(-1, 'MV 解析失败');
    final entry =
        d[hash.toLowerCase()] ??
        d[hash.toUpperCase()] ??
        (d.isEmpty ? null : d.values.first);
    if (entry is! Map) throw ApiException(-1, 'MV 解析失败');
    final down = entry['downurl'];
    final backup = entry['backupdownurl'];
    var url = '';
    if (down is String && down.isNotEmpty) {
      url = down;
    } else if (backup is List && backup.isNotEmpty) {
      url = '${backup.first}';
    } else if (backup is String && backup.isNotEmpty) {
      url = backup;
    }
    if (url.isEmpty) throw ApiException(-1, 'MV 暂无播放地址');
    // 优先直连原始 HTTP 地址：
    // - network_security_config 已对 kugou.com（含子域）放行 cleartext；
    // - 酷狗 CDN 支持 Range，ExoPlayer 才能边下边播 / 拖动；
    // - 走前缀代理时，代理不转发 Range 请求，实测表现就是「只能播开头」。
    return url;
  }

  /// 32 位十六进制 hash（视频 hash 均为大写十六进制）。
  static bool _looksLikeHash(String s) =>
      s.length == 32 && RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(s);

  /// V33-10（修复②）：MV 缩略图地址补全。
  ///
  /// 酷狗 MV 缩略图支持尺寸档 `{size}` ∈ {240,320,480,720}，按控件实际需要的
  /// 最小够用档请求（第 25 条：解码/带宽上限）。既能处理已带 `{size}` 的整 URL，
  /// 也能把裸文件名 pic 拼成 `mvthumb/{size}/pic`；统一升级 https。
  static String _mvThumb(String raw, {int size = 320}) {
    if (raw.isEmpty) return '';
    var u = raw.replaceAll('{size}', '$size');
    if (!u.startsWith('http')) {
      u = 'http://imge.kugou.com/mvthumb/$size/$u';
    }
    if (u.startsWith('http://')) u = 'https://${u.substring(7)}';
    return u;
  }
}

class MvInfo {
  MvInfo({
    required this.videoId,
    required this.name,
    required this.artist,
    required this.thumb,
    required this.duration,
    this.sdHash,
    this.hdHash,
    this.qhdHash,
    this.sqHash,
  });
  final String videoId;
  final String name;
  final String artist;
  final String thumb;
  final int duration; // 秒
  final String? sdHash;
  final String? hdHash;
  final String? qhdHash;
  final String? sqHash;

  String? get bestHash => [
    sqHash,
    qhdHash,
    hdHash,
    sdHash,
  ].whereType<String>().where((hash) => hash.isNotEmpty).firstOrNull;

  /// 实测 `/kmr/audio/mv` 单项字段：
  /// `mv_name` / `authors[].author_name` / `singer` / `user_name` /
  /// `video_id` / `duration`（**毫秒**）/ `thumb` / `hdpic` /
  /// `mkv{sd,hd,qhd}_hash` 与 `h264{sd,hd,qhd,fhd,ld}_hash` / `h265{...}`。
  factory MvInfo.fromJson(Map<String, dynamic> json) {
    final mkv = json['mkv'] is Map
        ? Map<String, dynamic>.from(json['mkv'] as Map)
        : <String, dynamic>{};
    final h264 = json['h264'] is Map
        ? Map<String, dynamic>.from(json['h264'] as Map)
        : <String, dynamic>{};
    final h265 = json['h265'] is Map
        ? Map<String, dynamic>.from(json['h265'] as Map)
        : <String, dynamic>{};

    // 标题：mv_name 是实测字段（不是 name/songname）。
    final name =
        '${json['mv_name'] ?? json['songname'] ?? json['name'] ?? json['filename'] ?? ''}';

    // 艺人：优先 authors[]，其次 singer / user_name（用户视频只有后者）。
    final authors = json['authors'];
    var artist = '';
    if (authors is List) {
      artist = authors
          .whereType<Map>()
          .map((a) => '${a['author_name'] ?? a['name'] ?? ''}')
          .where((s) => s.isNotEmpty)
          .join('、');
    }
    if (artist.isEmpty) {
      artist =
          '${json['singer'] ?? json['singername'] ?? json['user_name'] ?? ''}';
    }

    // V33-10：MV 关联缩略图（列表/卡片用），列表项约 48px，320 档已足够，
    // 等比取最小够用档（第 25 条），禁止拉伸。
    var thumb = MvRepository._mvThumb(
      '${json['thumb'] ?? json['hdpic'] ?? json['imgurl'] ?? ''}',
      size: 320,
    );

    // duration 实测为毫秒（317400），这里统一换算成秒。
    final durRaw = json['duration'] ?? json['timelength'] ?? mkv['timelength'];
    final durationMs = durRaw is num
        ? durRaw.round()
        : (int.tryParse('${durRaw ?? ''}') ?? 0);
    // duration 在 kmr/audio/mv 与 video/detail 实测恒为毫秒
    // （docs/api_report_comment_mv_lyric.md），直接换算秒。
    // 不再用 ">10000 才当毫秒" 启发式：<10 秒的短视频 MV（实测 8~9 秒项）
    // 会被误保留成毫秒。0 视为无时长，保持 0。
    final duration = durationMs <= 0 ? 0 : durationMs ~/ 1000;

    String? pick(String key) {
      final v = h264[key] ?? h265[key] ?? mkv[key];
      if (v == null) return null;
      final s = '$v';
      return s.isEmpty ? null : s;
    }

    return MvInfo(
      videoId: '${json['video_id'] ?? json['mv_hash'] ?? json['id'] ?? ''}',
      name: name,
      artist: artist,
      thumb: thumb,
      duration: duration,
      sdHash: pick('sd_hash'),
      hdHash: pick('hd_hash'),
      qhdHash: pick('qhd_hash'),
      // sq（Super Quality）实测不存在；mkv 有 qhd/sd，h264 有 fhd。
      sqHash: pick('sq_hash'),
    );
  }
}

class MvDetail {
  MvDetail({
    required this.videoId,
    required this.name,
    required this.artist,
    required this.cover,
    required this.duration,
    required this.hashes,
  });
  final String videoId;
  final String name;
  final String artist;
  final String cover;
  final int duration; // 秒
  final Map<String, String> hashes; // quality -> hash

  /// 最高画质的 hash（用于首次播放）。
  String? get bestHash {
    for (final q in const ['fhd', 'sq', 'qhd', 'hd', 'sd', 'ld']) {
      final h = hashes[q];
      if (h != null && h.isNotEmpty) return h;
    }
    return null;
  }

  /// 实测 `/video/detail`：
  /// - `data` 是**数组**（首项为视频对象）
  /// - 标题 `video_name`，艺人 `author_name` / `authors[]`
  /// - 封面 `cover` / `hdpic` / `pic`（pic 是裸文件名）
  /// - 时长 `timelength`（**毫秒**，MV 时长）；`audio_timelength` 是音频时长
  /// - 清晰度 hash 平铺在顶层：`hd_hash` / `sd_hash` / `qhd_hash` / `fhd_hash` /
  ///   `ld_hash`，mkv 容器另名 `mkv_sd_hash` / `mkv_qhd_hash`
  factory MvDetail.fromJson(Map<String, dynamic> json) {
    final raw = json['data'];
    Map<String, dynamic> data;
    if (raw is List) {
      data = raw.isNotEmpty && raw.first is Map
          ? Map<String, dynamic>.from(raw.first as Map)
          : <String, dynamic>{};
    } else if (raw is Map) {
      data = Map<String, dynamic>.from(raw);
    } else {
      data = json;
    }

    // V33-10：详情页封面，720× 设备像素仍清晰，按 480 档取（第 25 条）。
    // 复用 _mvThumb 统一处理 {size} 占位 / 裸 pic 文件名 / http 升级。
    var cover = MvRepository._mvThumb(
      '${data['cover'] ?? data['hdpic'] ?? data['thumb'] ?? ''}',
      size: 480,
    );
    if (cover.isEmpty) {
      final pic = '${data['pic'] ?? ''}';
      if (pic.isNotEmpty) {
        cover = MvRepository._mvThumb(pic, size: 480);
      }
    }

    final hashes = <String, String>{};
    // 顶层平铺 hash 优先；mkv_* 是另一套（mkv 容器画质）。
    void put(String key, String value) {
      if (value.isNotEmpty && !hashes.containsKey(key)) hashes[key] = value;
    }

    put('hd', '${data['hd_hash'] ?? ''}');
    put('sd', '${data['sd_hash'] ?? ''}');
    put('qhd', '${data['qhd_hash'] ?? ''}');
    put('fhd', '${data['fhd_hash'] ?? ''}');
    put('ld', '${data['ld_hash'] ?? ''}');
    put('sq', '${data['sq_hash'] ?? ''}');
    // h264/h265 变体（部分视频只有这些）。
    for (final key in ['hd', 'sd', 'qhd', 'fhd', 'ld']) {
      final v = data['${key}_hash_265'] ?? data['${key}_hash'];
      if (v != null) put(key, '$v');
    }
    // mkv 容器的同画质 hash 作为兜底（仅在顶层缺失时补）。
    put('sd', '${data['mkv_sd_hash'] ?? ''}');
    put('qhd', '${data['mkv_qhd_hash'] ?? ''}');

    var artist = '${data['author_name'] ?? data['singername'] ?? ''}';
    if (artist.isEmpty) {
      final authors = data['authors'];
      if (authors is List) {
        artist = authors
            .whereType<Map>()
            .map((a) => '${a['author_name'] ?? a['name'] ?? ''}')
            .where((s) => s.isNotEmpty)
            .join('、');
      }
    }

    // timelength 为毫秒（MV 时长），统一转秒。
    final durRaw = data['timelength'] ?? data['duration'];
    final durationMs = durRaw is num
        ? durRaw.round()
        : (int.tryParse('${durRaw ?? ''}') ?? 0);
    // timelength 实测恒为毫秒（MV 时长，docs/api_report_comment_mv_lyric.md），
    // 直接换算秒（MvInfo.fromJson 同此口径）；备用字段 duration 同为毫秒口径。
    final duration = durationMs <= 0 ? 0 : durationMs ~/ 1000;

    return MvDetail(
      videoId: '${data['video_id'] ?? data['id'] ?? ''}',
      name:
          '${data['video_name'] ?? data['mv_name'] ?? data['songname'] ?? data['name'] ?? ''}',
      artist: artist,
      cover: cover,
      duration: duration,
      hashes: hashes,
    );
  }
}
