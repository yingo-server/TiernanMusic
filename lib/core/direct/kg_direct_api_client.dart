/// 内容接口直连适配器
///
/// 继承 [KugouApiClient]，覆写 get/post，把已移植的接口直接打到酷狗网关，
/// 未移植的路径回退到父类（kapi 中转）。这样所有既有 Repository 无需改动。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'kg_client.dart';
import 'kg_crypto.dart';
import '../api/kugou_api_client.dart';

class KgDirectApiClient extends KugouApiClient {
  KgDirectApiClient(this.kg, {super.baseUrl});

  final KgClient kg;

  /// 依据响应构造与 kapi 一致的 Map（业务失败抛 ApiException）
  Map<String, dynamic> _wrap(KgResponse r) {
    final body = r.body;
    final status = body['status'];
    final rawCode = body['error_code'] ?? body['errcode'] ?? 0;
    final errorCode =
        rawCode is int ? rawCode : int.tryParse('$rawCode') ?? 0;
    if (status == 0 || status == 2 || errorCode != 0) {
      throw ApiException(
        errorCode,
        '${body['error'] ?? body['error_msg'] ?? body['errmsg'] ?? body['info'] ?? '请求失败'}',
        ssaCode: r.ssaCode,
        body: body,
      );
    }
    return body;
  }

  /// 直连失败时是否自动回退 kapi 中转（真机网络/风控差异的兜底）
  static bool fallbackToKapi = true;

  /// 记录最近一次错误（供"网络诊断"页展示）
  static final List<String> lastErrors = <String>[];

  void _logError(String where, Object e) {
    final msg = '[${DateTime.now().toIso8601String()}] $where: $e';
    lastErrors.insert(0, msg);
    if (lastErrors.length > 20) lastErrors.removeLast();
    debugPrint(msg);
  }

  /// 先直连，失败则回退 kapi
  Future<Map<String, dynamic>> _directOrFallback(
    Future<KgResponse> Function() direct,
    Future<Map<String, dynamic>> Function() kapi,
    String label,
  ) async {
    try {
      return _wrap(await direct());
    } catch (e) {
      _logError(label, e);
      if (!fallbackToKapi) rethrow;
      try {
        return await kapi();
      } catch (e2) {
        _logError('$label (kapi 回退)', e2);
        rethrow;
      }
    }
  }

  @override
  Future<Map<String, dynamic>> get(String path,
      {Map<String, dynamic>? query}) async {
    final q = query ?? const <String, dynamic>{};
    final n = _norm(path);
    final kapi = () => super.get(path, query: query);
    switch (n) {
      case 'search':
        return _directOrFallback(() => _search(q), kapi, '/search');
      case 'search/lyric':
        return _directOrFallback(() => _searchLyric(q), kapi, '/search/lyric');
      case 'lyric':
        return _directOrFallback(() => _lyric(q), kapi, '/lyric');
      case 'comment/count':
        return _directOrFallback(() => _commentCount(q), kapi, '/comment/count');
      case 'yueku':
        return _directOrFallback(() => _yueku(), kapi, '/yueku');
      case 'rank/list':
        return _directOrFallback(() => _rankList(q), kapi, '/rank/list');
      case 'playlist/track/all':
        return _directOrFallback(
            () => _playlistTrackAll(q), kapi, '/playlist/track/all');
      case 'video/url':
        return _directOrFallback(() => _videoUrl(q), kapi, '/video/url');
      case 'comment/floor':
        return _directOrFallback(() => _commentFloor(q), kapi, '/comment/floor');
      case 'song/url':
        return _directOrFallback(() => _songUrl(q), kapi, '/song/url');
      case 'playlist/detail':
        return _directOrFallback(
            () => _playlistDetail(q), kapi, '/playlist/detail');
      case 'kmr/audio/mv':
        return _directOrFallback(() => _kmrAudioMv(q), kapi, '/kmr/audio/mv');
      case 'comment/music':
        return _directOrFallback(() => _commentMusic(q), kapi, '/comment/music');
      case 'top/playlist':
        return _directOrFallback(() => _topPlaylist(q), kapi, '/top/playlist');
      case 'everyday/recommend':
        return _directOrFallback(
            () => _everydayRecommend(q), kapi, '/everyday/recommend');
      case 'privilege/lite':
        return _directOrFallback(() => _privilege(q), kapi, '/privilege/lite');
    }
    return super.get(path, query: query);
  }

  @override
  Future<Map<String, dynamic>> post(String path, dynamic data,
      {Map<String, dynamic>? query}) async {
    final q = query ?? const <String, dynamic>{};
    final n = _norm(path);
    final kapi = () => super.post(path, data, query: query);
    switch (n) {
      case 'comment/music':
        return _directOrFallback(() => _commentMusic(q), kapi, '/comment/music');
      case 'kmr/audio/mv':
        return _directOrFallback(() => _kmrAudioMv(q), kapi, '/kmr/audio/mv');
      case 'everyday/recommend':
        return _directOrFallback(
            () => _everydayRecommend(q), kapi, '/everyday/recommend');
      case 'top/playlist':
        return _directOrFallback(() => _topPlaylist(q), kapi, '/top/playlist');
      case 'privilege/lite':
        return _directOrFallback(() => _privilege(q), kapi, '/privilege/lite');
      case 'search':
        return _directOrFallback(() => _search(q), kapi, '/search');
      case 'comment/floor':
        return _directOrFallback(() => _commentFloor(q), kapi, '/comment/floor');
      case 'playlist/detail':
        return _directOrFallback(
            () => _playlistDetail(q), kapi, '/playlist/detail');
    }
    return super.post(path, data, query: query);
  }

  static String _norm(String p) =>
      p.startsWith('/') ? p.substring(1) : p;

  // ---------------- 搜索 ----------------

  Future<KgResponse> _search(Map<String, dynamic> q) async {
    final type = ['special', 'lyric', 'song', 'album', 'author', 'mv']
            .contains(q['type'])
        ? q['type'] as String
        : 'song';
    final keyword = '${q['keywords'] ?? q['keyword'] ?? ''}';

    if (type == 'song') {
      return kg.request('/v2/search/song',
          method: 'GET',
          headers: {'x-router': 'complexsearch.kugou.com'},
          params: {
            'keyword': keyword,
            'page': q['page'] ?? 1,
            'pagesize': q['pagesize'] ?? 30,
            'platform': 'AndroidFilter',
            'iscorrection': q['iscorrection'] ?? 1,
            'privilegefilter': q['privilegefilter'] ?? 0,
            'area_code': q['area_code'] ?? 1,
            'dopicfull': 1,
            if (q['tag'] != null) 'tag': q['tag'],
            if (kg.lite) 'clientver': 201,
          });
    }
    if (type == 'album') {
      return kg.request('/v1/search/album',
          method: 'GET',
          headers: {'x-router': 'complexsearch.kugou.com'},
          params: {
            'keyword': keyword,
            'page': q['page'] ?? 1,
            'pagesize': q['pagesize'] ?? 20,
            'platform': 'AndroidFilter',
            'iscorrection': q['iscorrection'] ?? 1,
            'category': q['category'] ?? '1',
            'sorttype': '${q['sorttype']}' == '1' ? 1 : 0,
            'searchsong': '${q['searchsong']}' == '1' ? 1 : 0,
            if (q['tag'] != null) 'tag': q['tag'],
            if (kg.lite) 'clientver': 201,
          });
    }
    // special / author / mv / lyric
    return kg.request('/v1/search/$type',
        method: 'GET',
        headers: {'x-router': 'complexsearch.kugou.com'},
        params: {
          'keyword': keyword,
          'page': q['page'] ?? 1,
          'pagesize': q['pagesize'] ?? 20,
          'platform': 'AndroidFilter',
          if (q['tag'] != null) 'tag': q['tag'],
          if (kg.lite) 'clientver': 201,
        });
  }

  /// 歌词搜索。
  ///
  /// 实测：lyrics.kugou.com 上 `/v1/search` 恒返回**空响应体 + HTTP 200**，
  /// 响应头 `x-kg-errcode: 20010`（10 种参数/UA/Referer/签名组合全部一样空），
  /// 加 `x-router` 头也一样空。真正存在的路径是 `/search`（无版本前缀），
  /// 返回 `x-kg-errcode: 200` 与 candidates 数组。
  /// 该接口不校验 signature，保持 clearDefaultParams + notSignature。
  /// duration 传毫秒：搜索结果 Duration 是秒，服务端候选 duration=269792。
  Future<KgResponse> _searchLyric(Map<String, dynamic> q) {
    final durationSec = int.tryParse('${q['duration'] ?? 0}') ?? 0;
    return kg.request('/search',
        baseUrl: 'https://lyrics.kugou.com',
        method: 'GET',
        clearDefaultParams: true,
        notSignature: true,
        params: {
          'appid': kg.lite ? KgConfig.liteAppid : KgConfig.appid,
          'clientver': kg.lite ? KgConfig.liteClientver : KgConfig.clientver,
          'keyword': '${q['keywords'] ?? ''}',
          'lrctxt': 1,
          'man': '${q['man'] ?? 'no'}',
          if (durationSec > 0)
            'duration': q['duration_ms'] ?? durationSec * 1000,
          if (q['hash'] != null && '${q['hash']}'.isNotEmpty) 'hash': q['hash'],
          if (q['album_audio_id'] != null &&
              '${q['album_audio_id']}'.isNotEmpty &&
              '${q['album_audio_id']}' != '0')
            'album_audio_id': q['album_audio_id'],
        });
  }

  Future<KgResponse> _lyric(Map<String, dynamic> q) async {
    final fmt = '${q['fmt'] ?? 'krc'}';
    final r = await kg.request('/download',
        baseUrl: 'https://lyrics.kugou.com',
        method: 'GET',
        params: {
          'ver': 1,
          'client': q['client'] ?? 'android',
          'id': q['id'],
          'accesskey': q['accesskey'],
          'fmt': fmt,
          'charset': 'utf8',
        });
    // decode=true 时在客户端解密（KRC）或 Base64 解码（LRC）
    if ('${q['decode']}' == 'true') {
      final body = r.body;
      final content = body['content'];
      if (content is String && content.isNotEmpty) {
        final contenttype = body['contenttype'];
        if (fmt == 'lrc' || contenttype != 0) {
          try {
            body['decodeContent'] =
                utf8.decode(base64.decode(content), allowMalformed: true);
          } catch (_) {}
        }
      }
    }
    return r;
  }

  // ---------------- 评论 ----------------

  Future<KgResponse> _commentMusic(Map<String, dynamic> q) {
    return kg.request('/mcomment/v1/cmtlist',
        method: 'POST',
        params: {
          'ver': 6,
          'mixsongid': q['mixsongid'],
          'need_show_image': 1,
          'p': q['page'] ?? 1,
          'pagesize': q['pagesize'] ?? 30,
          'show_classify': q['show_classify'] ?? 1,
          'show_hotword_list': q['show_hotword_list'] ?? 1,
          'extdata': '0',
          'code': 'fc4be23b4e972707f36b8a828a93ba8a',
        });
  }

  Future<KgResponse> _commentCount(Map<String, dynamic> q) {
    return kg.request('/index.php',
        method: 'GET',
        encryptType: 'web',
        headers: {'x-router': 'sum.comment.service.kugou.com'},
        params: {
          'r': 'comments/getcommentsnum',
          'code': 'fc4be23b4e972707f36b8a828a93ba8a',
          if (q['hash'] != null) 'hash': q['hash'],
          if (q['hash'] == null && q['special_id'] != null)
            'childrenid': q['special_id'],
        });
  }

  Future<KgResponse> _commentFloor(Map<String, dynamic> q) {
    final resourceType = '${q['resource_type'] ?? 'song'}';
    final isPlaylistOrAlbum =
        resourceType == 'playlist' || resourceType == 'album';
    return kg.request(
        isPlaylistOrAlbum
            ? '/m.comment.service/v1/hot_replylist'
            : '/mcomment/v1/hot_replylist',
        method: 'POST',
        params: {
          'childrenid': q['special_id'],
          'need_show_image': 1,
          'p': q['page'] ?? 1,
          'pagesize': q['pagesize'] ?? 30,
          'show_classify': q['show_classify'] ?? 1,
          'show_hotword_list': q['show_hotword_list'] ?? 1,
          'code': 'fc4be23b4e972707f36b8a828a93ba8a',
          'tid': q['tid'],
          if (q['mixsongid'] != null) 'mixsongid': q['mixsongid'],
        });
  }

  // ---------------- 首页 ----------------

  Future<KgResponse> _yueku() {
    return kg.request('/v1/yueku/recommend_v2',
        method: 'GET',
        headers: {'x-router': 'service.mobile.kugou.com'},
        params: {
          'operator': 7,
          'plat': 0,
          'type': 11,
          'area_code': 1,
          'req_multi': 1,
        });
  }

  Future<KgResponse> _rankList(Map<String, dynamic> q) {
    return kg.request('/ocean/v6/rank/list',
        method: 'GET',
        params: {
          'plat': 2,
          'withsong': q['withsong'] ?? 1,
          'parentid': 0,
        });
  }

  Future<KgResponse> _everydayRecommend(Map<String, dynamic> q) {
    return kg.request('/everyday_song_recommend',
        method: 'POST',
        headers: {'x-router': 'everydayrec.service.kugou.com'},
        params: {'platform': q['platform'] ?? 'ios'});
  }

  Future<KgResponse> _topPlaylist(Map<String, dynamic> q) {
    final now = DateTime.now();
    final dateTime =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}${now.hour.toString().padLeft(2, '0')}';
    return kg.request('/v2/special_recommend',
        method: 'POST',
        headers: {'x-router': 'specialrec.service.kugou.com'},
        data: {
          'appid': kg.lite ? KgConfig.liteAppid : KgConfig.appid,
          'mid': kg.device.mid,
          'clientver':
              kg.lite ? KgConfig.liteClientver : KgConfig.clientver,
          'platform': 'android',
          'clienttime': dateTime,
          'userid': kg.userid,
          'module_id': q['module_id'] ?? 1,
          'page': q['page'] ?? 1,
          'pagesize': q['pagesize'] ?? 30,
          'key': KgSignature.paramsKey(dateTime, lite: kg.lite),
          'special_recommend': {
            'withtag': q['withtag'] ?? 1,
            'withsong': q['withsong'] ?? 1,
            'categoryid': q['category_id'] ?? 0,
            'tagids': q['tagids'] ?? '',
          },
          'req_multi': 1,
          'retrun_min': 5,
          'return_special_falg': 1,
        });
  }

  // ---------------- 歌单 ----------------

  /// 歌单详情。
  ///
  /// 实测：载荷必须是 `{"data": [{"global_collection_id": "<gid>"}]}`。
  /// 旧写法 `{"listid": [...]}` 不管传 gid 还是数字 specialid、不管 v1/v2/v3
  /// 都返回 `status=0 error_code=20010`（v2 附带 errmsg `data len need in [1, 10]`）。
  /// 数字 listid（用户歌单）不被接受，只认 `collection_x_uid_xx` 形式的 gid。
  Future<KgResponse> _playlistDetail(Map<String, dynamic> q) {
    final ids = '${q['ids'] ?? q['global_collection_id'] ?? ''}'
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return kg.request('/v3/get_list_info',
        method: 'POST',
        headers: {'x-router': 'pubsongs.kugou.com'},
        data: {
          // data 必须 1..10 项，每项用 global_collection_id 定位
          'data': [
            for (final id in ids.take(10)) {'global_collection_id': id},
          ],
        });
  }

  Future<KgResponse> _playlistTrackAll(Map<String, dynamic> q) {
    final pagesize = q['pagesize'] ?? 30;
    final page = int.tryParse('${q['page'] ?? 1}') ?? 1;
    return kg.request('/pubsongs/v2/get_other_list_file_nofilt',
        method: 'GET',
        params: {
          'area_code': 1,
          'begin_idx': (page - 1) * (pagesize is int ? pagesize : 30),
          'plat': 1,
          'type': 1,
          'mode': 1,
          'personal_switch': 1,
          'extend_fields': 'abtags,hot_cmt,popularization',
          'pagesize': pagesize,
          'global_collection_id': q['id'],
        });
  }

  // ---------------- MV ----------------

  Future<KgResponse> _kmrAudioMv(Map<String, dynamic> q) {
    // B 代理实测：该接口要 mixsongid（传 album_audio_id 返回 [{}]）
    final ids = '${q['mixsongid'] ?? q['album_audio_id'] ?? ''}'.split(',');
    return kg.request('/kmr/v1/audio/mv',
        method: 'POST',
        headers: {'x-router': 'openapi.kugou.com', 'KG-TID': '38'},
        data: {
          'data': ids.map((s) => {'mixsongid': s}).toList(),
          'fields': q['fields'] ?? '',
        });
  }

  Future<KgResponse> _videoUrl(Map<String, dynamic> q) async {
    final hash = '${q['hash'] ?? ''}';
    final r = await kg.request('/v2/interface/index',
        method: 'GET',
        headers: {'x-router': 'trackermv.kugou.com'},
        params: {
          'backupdomain': 1,
          'cmd': 123,
          'ext': 'mp4',
          'ismp3': 0,
          'hash': hash,
          'pid': 1,
          'type': 1,
          'key': KgSignature.keyOf(
            hash: hash,
            mid: kg.device.mid,
            userid: kg.userid,
            lite: kg.lite,
          ),
        });
    return r;
  }

  // ---------------- 播放/权益（供 kapi 回退路径复用） ----------------

  Future<KgResponse> _songUrl(Map<String, dynamic> q) {
    return kg.request('/v5/url',
        method: 'GET',
        headers: {'x-router': 'trackercdn.kugou.com'},
        params: {
          'album_id': int.tryParse('${q['album_id'] ?? 0}') ?? 0,
          'area_code': 1,
          'hash': '${q['hash'] ?? ''}'.toLowerCase(),
          'ssa_flag': 'is_fromtrack',
          'version': 11430,
          'page_id': kg.lite ? 967177915 : 151369488,
          'quality': q['quality'] ?? '128',
          'album_audio_id': int.tryParse('${q['album_audio_id'] ?? 0}') ?? 0,
          'behavior': 'play',
          'pid': kg.lite ? 411 : 2,
          'cmd': 26,
          'pidversion': 3001,
          'IsFreePart': '${q['free_part']}' == '1' ? 1 : 0,
          'ppage_id': kg.lite
              ? '356753938,823673182,967485191'
              : '463467626,350369493,788954147',
          'cdnBackup': 1,
          'module': '',
          'clientver': 11430,
          'key': KgSignature.keyOf(
            hash: '${q['hash'] ?? ''}'.toLowerCase(),
            mid: kg.device.mid,
            userid: kg.userid,
            lite: kg.lite,
          ),
        });
  }

  Future<KgResponse> _privilege(Map<String, dynamic> q) {
    final hashes = '${q['hash'] ?? ''}'.split(',');
    final albums = '${q['album_id'] ?? ''}'.split(',');
    final resource = <Map<String, dynamic>>[];
    for (var i = 0; i < hashes.length; i++) {
      if (hashes[i].isEmpty) continue;
      resource.add({
        'type': 'audio',
        'page_id': 1,
        'hash': hashes[i].toLowerCase(),
        'album_id': i < albums.length ? albums[i] : '0',
      });
    }
    return kg.request('/v2/get_res_privilege/lite',
        method: 'POST',
        data: {
          'appid': kg.lite ? KgConfig.liteAppid : KgConfig.appid,
          'area_code': 1,
          'behavior': 'play',
          'clientver':
              kg.lite ? KgConfig.liteClientver : KgConfig.clientver,
          'need_hash_offset': 1,
          'relate': 1,
          'support_verify': 1,
          'resource': resource,
          'qualities': const [
            '128', '320', 'flac', 'high',
            'viper_atmos', 'viper_tape', 'viper_clear', 'super', 'multitrack',
          ],
        });
  }
}
