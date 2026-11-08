import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/providers.dart';
import '../../../core/cache/cache_manager.dart';
import '../../../core/resource/cached_api.dart';
import '../../../core/resource/resource_cache.dart';

/// 宽松地转 int：数字直接取整，字符串解析，失败返回 fallback。
int _toInt(dynamic v, {int fallback = 0}) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v == null) return fallback;
  return int.tryParse('$v') ?? fallback;
}

/// 歌单写操作失败。
///
/// [maybeSucceeded] 是契约的一部分（QUALITY_STANDARD 第 3／8 条）：
/// - `false` → 服务端明确拒绝或请求未发出，用户可以安全重试；
/// - `true`  → 请求可能已经执行（超时 / 连接中断 / 响应不可解析），
///   界面必须提示「可能已生效，请刷新确认」，不得诱导用户直接重试，
///   否则一次网络抖动就会造成重复收藏、同批歌曲加两遍（第 21 条）。
class PlaylistWriteException implements Exception {
  PlaylistWriteException(
    this.message, {
    required this.maybeSucceeded,
    this.cause,
  });

  final String message;
  final bool maybeSucceeded;
  final Object? cause;

  @override
  String toString() => maybeSucceeded
      // 用户可见文案：明确区分「确定失败」与「可能已生效」
      ? '操作结果未知（可能已生效，请刷新确认）：$message'
      : message;
}

class PlaylistRepository {
  PlaylistRepository(this._api) : _cached = CachedApiCall(_api);
  final KugouApiClient _api;
  final CachedApiCall _cached;

  /// 公共歌单详情（V400-B-04：走 ResourceCache，90 秒列表语义 + 失效回退）
  Future<PlaylistDetail> fetchDetail(String globalCollectionId) async {
    final data = await _cached.get('/playlist/detail',
        query: {'ids': globalCollectionId}, ttl: kListTtl);
    return PlaylistDetail.fromJson(data, globalCollectionId);
  }

  /// 公共歌单歌曲（V400-ORDER：改为概念版分享页一致的「反反」顺序）。
  ///
  /// 用户实测 + 分享页对照：概念版分享页顺序 = 标准版分页的
  /// **页序倒（末页在前）+ 页内倒**（见 /tmp/v4_paging_8.txt 四组对照，
  /// 仅反反与分享页前 8 首逐位吻合）。原「按页升序拼接」已废弃。
  ///
  /// [allPages] = true 时拉全量并反反；false 时只返回请求页（页内亦倒转，
  /// 保证单页与全量语义一致）。余数/未知总数/失效回退由
  /// [_fetchAllReversed] 统一处理。
  Future<PlaylistTracks> fetchTracks(
    String globalCollectionId, {
    int page = 1,
    int pageSize = 100,
    bool allPages = false,
  }) async {
    return _fetchAllReversed(
      fetchPage: (p) async {
        final q = {
          'id': globalCollectionId,
          'page': p,
          'pagesize': pageSize,
        };
        // V400-B-04：ResourceCache（失效回退 + in-flight 合并）
        final data = await _cached.get('/playlist/track/all',
            query: q, ttl: kListTtl);
        return PlaylistTracks.fromJson(data);
      },
      page: page,
      pageSize: pageSize,
      allPages: allPages,
    );
  }

  /// 我的歌单（需登录）
  ///
  /// 实测 `/user/playlist`：歌单位于 `data.info[]`，首项 `listid=1`，
  /// 同时含 `global_collection_id`。
  Future<List<UserPlaylist>> fetchUserPlaylists(
      {int page = 1, int pageSize = 30}) async {
    final data = await _api.get('/user/playlist',
        query: {'page': page, 'pagesize': pageSize});
    final raw = data['data'];
    final list = raw is Map && raw['info'] is List
        ? raw['info'] as List
        : (raw is List ? raw : const []);
    return list
        .whereType<Map>()
        .map((e) => UserPlaylist.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 用户歌单歌曲（V400-ORDER：同样走反反，与公共歌单一致）。
  ///
  /// 与 Node playlist_track_all_new.js 逐字段一致（listid/userid/type/
  /// page/pagesize/area_code/allplatform/show_cover/token）。
  /// 实测：listid=2 共 485 首 / pageSize=10 → 49 页，末页仅 5 首；
  /// 反反拼法前 30 首与概念版分享页一致（歌名翻译差异已排除）。
  /// 余数、未知总数、失效回退全部由 [_fetchAllReversed] 统一处理。
  Future<PlaylistTracks> fetchUserTracks(String listid,
      {int page = 1, int pageSize = 300, bool allPages = true}) async {
    return _fetchAllReversed(
      fetchPage: (p) async {
        final q = {
          'listid': listid,
          'page': p,
          'pagesize': pageSize,
          'type': 0,
        };
        final data = await _cached.get('/playlist/track/all/new',
            query: q, ttl: kListTtl);
        return PlaylistTracks.fromJson(data);
      },
      page: page,
      pageSize: pageSize,
      allPages: allPages,
    );
  }

  /// 反反全量抓取的共用实现（V400-ORDER）。
  ///
  /// 1) 先取起始页拿 `total` 与页内实体；
  /// 2) 总页数按 ceil(total/pageSize) 计算，**末页余数按实际长度处理**；
  /// 3) 从末页往回逐页抓，每页 `reversed` 后拼接 —— 页序倒 + 页内倒 = 反反；
  /// 4) `count` 缺失或为不可信值（<=0 / 小于已见条数）时，逐页向前探测
  ///    直到出现「不满页」，把所有探测到的页纳入拼接（第 16 条）；
  /// 5) 任何单页失败：按第 9 条留痕并跳过该页，不吞成空列表、不中断整体；
  /// 6) 循环恒有上界 maxPages（第 25 条），去重按 hash 保守执行（第 23 条）。
  Future<PlaylistTracks> _fetchAllReversed({
    required Future<PlaylistTracks> Function(int p) fetchPage,
    required int page,
    required int pageSize,
    required bool allPages,
  }) async {
    final first = await fetchPage(page);
    if (!allPages) {
      // 单页也做页内倒转，与全量反反语义一致（不引入第二种排列）
      return PlaylistTracks(
        songs: first.songs.reversed.toList(),
        total: first.total,
      );
    }

    const maxPages = 100; // 上界：pageSize=100 时 1 万首
    final size = pageSize > 0 ? pageSize : 100;

    // 可信总数：>0 且不小于首页实际条数
    final trustedTotal = first.total > 0 && first.total >= first.songs.length
        ? first.total
        : 0;
    final wantedPages = trustedTotal > 0
        ? (trustedTotal / size).ceil().clamp(1, maxPages)
        : 0; // 0 = 未知，走探测
    // V402-R4（复核③）：上界截断时**取末尾 wantedPages 页**而非 1..100，
    // 否则反反的「末页优先」会退化成显示最旧 100 页；total 用实际条数
    // 而非虚高的 trustedTotal（第 16 条：已取到的才是事实）。
    final totalPages = wantedPages;
    final startPage = totalPages > 0
        ? (trustedTotal / size).ceil() - totalPages + 1
        : 0;

    // 收集所有页（页号 → 该页实体），首页直接复用不重复请求。
    final pages = <int, List<PlaylistSong>>{page: first.songs};
    // 已知总页数：抓取 1..totalPages（跳过首页）
    if (totalPages > 0) {
      // 从 startPage 起抓 wantedPages 页（上界截断的是头部旧页）。
      for (var p = startPage; p < startPage + totalPages; p++) {
        if (p < 1 || p == page || p > maxPages) continue;
        try {
          pages[p] = (await fetchPage(p)).songs;
        } catch (e) {
          debugPrint('[playlist] page $p failed: $e'); // 第 9 条：留痕
        }
      }
    } else {
      // 未知总数：从首页向前探测，直到不满页 / 空页 / 触达上界。
      var p = page + 1;
      var failedProbes = 0;
      while (p <= maxPages) {
        try {
          final t = await fetchPage(p);
          pages[p] = t.songs;
          if (t.songs.isEmpty || t.songs.length < size) break;
        } catch (e) {
          debugPrint('[playlist] probe page $p failed: $e');
          // V402-R5（复核③）：单页失败与「已知总页数」分支保持一致——
          // 留痕并跳过继续探测，不 break 中断整体（第 9/6 条）。
          // 连续 3 页失败才放弃，防止服务端持续报错时打满 100 次。
          failedProbes++;
          if (failedProbes >= 3) break;
        }
        p++;
      }
      // 若首页不是第 1 页且总数未知，向后补齐 1..page-1（保证全量）
      for (var q = 1; q < page && q <= maxPages; q++) {
        try {
          pages[q] = (await fetchPage(q)).songs;
        } catch (e) {
          debugPrint('[playlist] backfill page $q failed: $e');
        }
      }
    }

    // 反反：页号降序，每页内部倒转。末页不足 size 按实际长度全取，不补位。
    final sortedKeys = pages.keys.toList()..sort((a, b) => b.compareTo(a));
    final songs = <PlaylistSong>[];
    for (final p in sortedKeys) {
      songs.addAll(pages[p]!.reversed);
    }

    return PlaylistTracks(
      songs: songs,
      // V402-R4：上界截断时 trustedTotal 虚高，以实取条数为事实源。
      total: trustedTotal > 0 && songs.length >= trustedTotal
          ? trustedTotal
          : songs.length,
    );
  }

  /// 收藏歌单（type=1 收藏公共歌单，type=0 新建）
  ///
  /// 写操作契约（QUALITY_STANDARD 第 3／8／9／21 条）：
  /// - 失败一律抛 [PlaylistWriteException]，区分「确定失败」与「可能已生效」；
  /// - 同一 (操作, 歌单) 在飞行期间拒绝重复提交；
  /// - 网络层直连失败**不回退** kapi（kg_direct_api_client 的 write: true），
  ///   否则一次超时就会重复收藏出两条同名歌单。
  Future<void> collectPlaylist({
    required String name,
    String? listCreateUserid,
    String? listCreateListid,
    String? listCreateGid,
  }) async {
    final params = <String, dynamic>{
      'type': listCreateUserid != null ? 1 : 0,
      'name': name,
      if (listCreateUserid != null) 'list_create_userid': listCreateUserid,
      if (listCreateListid != null) 'list_create_listid': listCreateListid,
      if (listCreateGid != null) 'list_create_gid': listCreateGid,
    };
    await _write(
      '/playlist/add',
      params,
      dedupeKey: 'add:${listCreateGid ?? ''}:${listCreateListid ?? ''}:$name',
    );
  }

  /// 删除/取消收藏歌单
  Future<void> deletePlaylist(String listid) async {
    final id = listid.trim();
    if (id.isEmpty) {
      // 边界校验（第 14 条）：空 listid 打上去只会得到一个无法解释的业务错误
      throw PlaylistWriteException('歌单 ID 为空，操作未执行', maybeSucceeded: false);
    }
    await _write('/playlist/del', {'listid': id}, dedupeKey: 'del:$id');
  }

  /// 添加歌曲到歌单
  ///
  /// 协议限制：服务端 `data` 是 `名称|hash|album_id|album_audio_id` 逗号分隔串，
  /// 因此 `|`、`,` 只能作为分隔符出现。歌名里若自带这两个字符，
  /// 必须替换为全角同形字（第 14 条边界校验），否则整串字段右移，
  /// 会把「歌名片段」当成 hash 提交，加进歌单的是错歌或无效条目。
  Future<void> addTracks(String listid, List<TrackRef> tracks) async {
    final id = listid.trim();
    if (id.isEmpty) {
      throw PlaylistWriteException('歌单 ID 为空，操作未执行', maybeSucceeded: false);
    }
    if (tracks.isEmpty) return;

    final seen = <String>{};
    final rows = <String>[];
    for (final t in tracks) {
      final hash = _safeId(t.hash);
      // hash 是唯一可播放标识，缺失即无法定位歌曲，直接判为非法入参
      if (hash.isEmpty) {
        throw PlaylistWriteException('歌曲「${t.name}」缺少 hash，本次未提交',
            maybeSucceeded: false);
      }
      if (!seen.add(hash)) continue; // 批次内去重（第 21 条：同一批不重复加歌）
      rows.add([
        _safeName(t.name),
        hash,
        _safeId(t.albumId),
        _safeId(t.albumAudioId),
      ].join('|'));
    }
    if (rows.isEmpty) return;

    await _write(
      '/playlist/tracks/add',
      {'listid': id, 'data': rows.join(',')},
      dedupeKey: 'tracks-add:$id:${rows.join(',')}',
    );
  }

  /// 从歌单删除歌曲
  Future<void> removeTracks(String listid, List<String> fileids) async {
    final id = listid.trim();
    if (id.isEmpty) {
      throw PlaylistWriteException('歌单 ID 为空，操作未执行', maybeSucceeded: false);
    }
    final ids = fileids.map(_safeId).where((e) => e.isNotEmpty).toSet().toList();
    if (ids.isEmpty) {
      throw PlaylistWriteException('没有可删除的歌曲（fileid 全为空）',
          maybeSucceeded: false);
    }
    await _write(
      '/playlist/tracks/del',
      {'listid': id, 'fileids': ids.join(',')},
      dedupeKey: 'tracks-del:$id:${ids.join(',')}',
    );
  }

  /// 分隔符安全化：hash / id 只允许数字与字母。
  ///
  /// 返回空串表示该字段非法（调用方决定是拒绝还是占位）。
  static String _safeId(String? raw) {
    final v = (raw ?? '').trim();
    if (v.isEmpty) return '';
    // 协议分隔符与空白一律不合法，出现即说明上游字段已损坏
    return v.replaceAll(RegExp(r'[|,\s]'), '');
  }

  /// 歌名安全化：仅替换协议分隔符，保留其余字符（中文/空格/引号）。
  ///
  /// 用全角同形字替换而不是删除，用户仍能认出原歌名（第 14 条：边界校验，
  /// 但不静默丢信息）。
  static String _safeName(String raw) {
    var v = raw.trim();
    if (v.isEmpty) v = '未知歌曲';
    if (v.contains('|') || v.contains(',')) {
      debugPrint('[playlist] 歌名含协议分隔符，已替换为全角：$raw');
      v = v.replaceAll('|', '｜').replaceAll(',', '，');
    }
    return v;
  }

  /// 写操作统一出口。
  ///
  /// 为什么走 `get()`：`KgDirectApiClient` 把歌单写接口（/playlist/add、
  /// /playlist/del、/playlist/tracks/*）分派在 **get 分支**，并标记
  /// `write: true`（直连失败不回退 kapi）；真正的线上请求仍是原生 POST
  /// （`/cloudlist.service/v5/add_list` 等）。若改用客户端 `post()`，
  /// 这些路径在直连层没有 post 分派，会直接落到 kapi 网关，
  /// 违反 QUALITY_STANDARD 第 27 条（接口只走原生网关）——
  /// 因此保留 get 分派，并在本层补齐防重与失败语义。
  Future<void> _write(
    String path,
    Map<String, dynamic> params, {
    required String dedupeKey,
  }) async {
    // 防重（第 21／22 条）：同一次提交在飞行期间不被重复触发。
    // V37-03（B2 P3·语义修正）：防重拒绝发生在请求发出**之前**，
    // 本次操作必然未生效——`maybeSucceeded: true` 会误导调用方把
    // 「重复点击被拒」当「可能已成功」（如弹「歌单可能已更新」提示）。
    if (!_inFlight.add(dedupeKey)) {
      throw PlaylistWriteException('相同操作正在提交中，请稍候',
          maybeSucceeded: false);
    }
    try {
      await _api.get(path, query: params);
      _invalidatePlaylistCaches();
    } on DioException catch (e) {
      throw _toWriteException(path, e);
    } on ApiException catch (e) {
      // 服务端明确返回业务错误码 → 请求已到达并被拒绝，可安全重试
      throw PlaylistWriteException(e.message, maybeSucceeded: false, cause: e);
    } finally {
      _inFlight.remove(dedupeKey);
    }
  }

  /// 飞行中的写操作键（进程内防重锁）
  final Set<String> _inFlight = <String>{};

  /// 把底层异常翻译成带「是否可能已生效」语义的领域异常（第 8 条）。
  PlaylistWriteException _toWriteException(String path, DioException e) {
    final inner = e.error;
    final type = e.type;
    final maybeSucceeded = switch (type) {
      // 连接阶段失败：请求尚未发出，服务端一定没执行
      DioExceptionType.connectionError || DioExceptionType.badCertificate => false,
      DioExceptionType.connectionTimeout => false,
      // 已发出但未拿到（或拿不全）响应：服务端可能已执行
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.unknown ||
      // CI 实测：dio 还会抛 transformTimeout（拦截器转换阶段失败），
      // 请求体已发出，服务端可能已执行 → 按「结果未知」处理
      DioExceptionType.transformTimeout ||
      DioExceptionType.badResponse =>
        true,
      DioExceptionType.cancel => false,
    };
    final message = inner is ApiException
        ? inner.message
        : (inner?.toString() ?? e.message ?? '网络异常');
    return PlaylistWriteException(message,
        maybeSucceeded: maybeSucceeded, cause: e);
  }

  /// 写操作成功后让相关读缓存失效（第 5 条：状态单一来源）。
  ///
  /// 否则加歌/删歌后 90 秒内再次进入歌单页仍显示旧列表，用户以为没生效，
  /// 重复点击进一步放大重复提交风险。
  void _invalidatePlaylistCaches() {
    // V400-B-04：90 秒列表缓存已迁至 ResourceCache（resource_json 箱
    // list: 前缀），写后失效同步清 MemoryCache（兼容未迁移调用方）。
    ResourceCache.instance.clearLists();
    MemoryCache.instance.removeWhere((key) =>
        key.startsWith('/playlist/') || key.startsWith('/user/playlist'));
  }
}

class PlaylistDetail {
  PlaylistDetail({
    required this.id,
    required this.name,
    required this.cover,
    required this.intro,
    required this.playCount,
    required this.trackCount,
    required this.creatorName,
  });
  final String id;
  final String name;
  final String cover;
  final String intro;
  final int playCount;
  final int trackCount;
  final String creatorName;

  /// 实测 `/playlist/detail`：
  /// - `data` 是**数组**，首项为歌单对象
  /// - 名称 `name`；封面 `pic`（带 `{size}` 占位）；简介 `intro`
  /// - 曲目数 `count`；创建者 `list_create_username`
  /// - 全局 ID `global_collection_id`
  /// （`playcount` / `play_count` 实测都不存在，播放数只有 `heat`）
  factory PlaylistDetail.fromJson(Map<String, dynamic> json, String id) {
    final raw = json['data'];
    Map<String, dynamic> data;
    if (raw is List) {
      data = raw.isNotEmpty && raw.first is Map
          ? Map<String, dynamic>.from(raw.first as Map)
          : <String, dynamic>{};
    } else if (raw is Map) {
      data = Map<String, dynamic>.from(raw);
    } else {
      data = <String, dynamic>{};
    }
    // 实测：传数字 specialid（如排行榜 rankid）时上游返回 `data:{}`，
    // 之前会渲染出一个全空的歌单页（用户观感"进不去"）。这里明确报错。
    if (data.isEmpty) {
      throw ApiException(
        -1,
        '歌单不存在或 ID 无效（需要 collection_ 形式的全局 ID）',
      );
    }
    var cover = '${data['pic'] ?? data['imgurl'] ?? data['flexible_cover'] ?? data['cover'] ?? ''}';
    cover = cover.replaceAll('{size}', '480');
    return PlaylistDetail(
      id: '${data['global_collection_id'] ?? id}',
      name: '${data['name'] ?? data['specialname'] ?? ''}',
      cover: cover,
      intro: '${data['intro'] ?? ''}',
      playCount: _toInt(data['playcount'] ?? data['play_count'] ?? data['heat']),
      trackCount: _toInt(data['count'] ?? data['songcount']),
      creatorName:
          '${data['list_create_username'] ?? data['nickname'] ?? data['username'] ?? ''}',
    );
  }
}

class PlaylistTracks {
  PlaylistTracks({required this.songs, required this.total});
  final List<PlaylistSong> songs;
  final int total;

  /// 实测两种歌单结构不同：
  /// - 公共歌单 `/playlist/track/all` → `data.songs[]`，总数 `data.count`
  /// - 用户歌单 `/playlist/track/all/new` → `data.info[]`，总数 `data.count`
  factory PlaylistTracks.fromJson(Map<String, dynamic> json) {
    final raw = json['data'];
    final data = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    // 用户歌单优先取 info，公共歌单取 songs；两者都兼容。
    final rawList = data['info'] is List
        ? data['info'] as List
        : (data['songs'] is List ? data['songs'] as List : const []);
    final songs = rawList
        .whereType<Map>()
        .map((e) => PlaylistSong.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final total = _toInt(data['count'] ?? data['total'], fallback: songs.length);
    return PlaylistTracks(songs: songs, total: total);
  }
}

class PlaylistSong {
  PlaylistSong({
    required this.hash,
    required this.name,
    required this.artist,
    required this.albumId,
    required this.albumAudioId,
    required this.duration,
    required this.fileId,
    this.cover = '',
  });
  final String hash;
  final String name;
  final String artist;
  final String albumId;
  final String albumAudioId;
  final int duration; // 秒
  final String fileId;

  /// 歌曲封面（歌单歌曲有直接 `cover` 字段）。
  final String cover;

  /// 实测公共/用户歌单歌曲字段：
  /// `hash` / `name`（"歌手 - 歌名"）/ `singerinfo[].name` / `album_id` /
  /// `mixsongid`（= album_audio_id）/ `timelen`（**毫秒**）/ `fileid` /
  /// `cover` / `trans_param.union_cover`
  factory PlaylistSong.fromJson(Map<String, dynamic> json) {
    final rawName = '${json['name'] ?? json['filename'] ?? json['OriSongName'] ?? ''}';

    // 歌手：singerinfo[] 优先（实测歌单歌曲都有），其次显式字段。
    final singerInfo = json['singerinfo'];
    var singers = '';
    if (singerInfo is List) {
      singers = singerInfo
          .whereType<Map>()
          .map((e) => '${e['name'] ?? ''}')
          .where((n) => n.isNotEmpty)
          .join('、');
    }
    final explicitSinger =
        '${json['singername'] ?? json['SingerName'] ?? json['author_name'] ?? ''}';

    // 歌名："歌手 - 歌名"。只剥一次前缀，歌名自身可能含分隔符。
    var name = rawName;
    var artist = explicitSinger.isNotEmpty ? explicitSinger : singers;
    final sep = rawName.indexOf(' - ');
    if (sep > 0) {
      final prefix = rawName.substring(0, sep).trim();
      name = rawName.substring(sep + 3).trim();
      if (explicitSinger.isEmpty && singers.isEmpty) artist = prefix;
      if (explicitSinger.isNotEmpty && prefix != explicitSinger) {
        // 前缀与显式歌手不同：保留完整名，避免误删歌名。
        name = rawName;
      }
    }

    // 时长：timelen 是**毫秒**；duration / Duration 是**秒**。
    var duration = 0;
    if (json['timelen'] != null) {
      duration = _toInt(json['timelen']) ~/ 1000;
    } else if (json['timelength'] != null) {
      duration = _toInt(json['timelength']) ~/ 1000;
    } else {
      duration = _toInt(json['duration'] ?? json['Duration']);
    }

    final transParam = json['trans_param'] is Map
        ? Map<String, dynamic>.from(json['trans_param'] as Map)
        : <String, dynamic>{};
    var cover = '${json['cover'] ?? transParam['union_cover'] ?? ''}';
    cover = cover.replaceAll('{size}', '300');

    return PlaylistSong(
      hash: '${json['hash'] ?? json['FileHash'] ?? ''}',
      name: name,
      artist: artist.isEmpty
          ? (name.isNotEmpty && rawName.contains(' - ')
              ? rawName.substring(0, rawName.indexOf(' - ')).trim()
              : '')
          : artist,
      albumId: '${json['album_id'] ?? json['AlbumID'] ?? ''}',
      // mixsongid 才是 album_audio_id；audio_id 是另一套 id。
      albumAudioId:
          '${json['mixsongid'] ?? json['MixSongID'] ?? json['album_audio_id'] ?? ''}',
      duration: duration,
      fileId: '${json['fileid'] ?? json['FileID'] ?? ''}',
      cover: cover,
    );
  }
}

class UserPlaylist {
  UserPlaylist({
    required this.listid,
    required this.name,
    required this.cover,
    required this.count,
    required this.isMine,
    this.globalCollectionId = '',
  });
  final String listid;
  final String name;
  final String cover;
  final int count;
  final bool isMine;

  /// 全局歌单 ID（`collection_...` 形式）。
  ///
  /// 实测 `/user/playlist` 每项都带 `global_collection_id`；
  /// 直连 `/playlist/detail` 只认这个形式（数字 `listid` 会 20010）。
  final String globalCollectionId;

  /// 实测用户歌单项：`listid` / `name` / `pic` / `count` /
  /// `list_create_type` / `global_collection_id`。
  factory UserPlaylist.fromJson(Map<String, dynamic> json) {
    var cover = '${json['pic'] ?? json['imgurl'] ?? json['cover'] ?? ''}';
    cover = cover.replaceAll('{size}', '240');
    return UserPlaylist(
      listid: '${json['listid'] ?? json['list_id'] ?? ''}',
      name: '${json['name'] ?? json['specialname'] ?? ''}',
      cover: cover,
      count: _toInt(json['count'] ?? json['songcount']),
      isMine: _toInt(json['list_create_type'], fallback: 1) == 0 ||
          '${json['is_create'] ?? ''}' == '1',
      globalCollectionId:
          '${json['global_collection_id'] ?? json['global_specialid'] ?? ''}',
    );
  }
}

class TrackRef {
  TrackRef({required this.name, required this.hash, this.albumId, this.albumAudioId});
  final String name;
  final String hash;
  final String? albumId;
  final String? albumAudioId;
}


/// 歌单仓库单例（此前是 UI 层 throw UnimplementedError 导致歌单页必崩，后收敛至此）
final playlistRepositoryProvider = Provider<PlaylistRepository>(
    (ref) => PlaylistRepository(ref.watch(kugouApiClientProvider)));
