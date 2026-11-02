/// 内容接口直连适配器
///
/// 继承 [KugouApiClient]，覆写 get/post，把已移植的接口直接打到酷狗网关，
/// 未移植的路径回退到父类（kapi 中转）。这样所有既有 Repository 无需改动。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'kg_client.dart';
import 'kg_crypto.dart';
import 'kg_play_api.dart';
import '../api/kugou_api_client.dart';

class KgDirectApiClient extends KugouApiClient {
  KgDirectApiClient(this.kg, {super.baseUrl});

  final KgClient kg;

  /// 依据响应构造与 kapi 一致的 Map（业务失败抛 ApiException）
  ///
  /// 成功判定看 **`status == 1`**。
  /// `errcode`/`error_code` 为 151/152 等**警告码**时，只要响应里**有数据**
  /// （data 非空）就不算失败 —— 实测这两个码常与有效数据同时出现，
  /// 按「errcode != 0 即失败」判定会误杀正常响应。
  Map<String, dynamic> _wrap(KgResponse r) {
    final body = r.body;
    final status = body['status'];
    final rawCode = body['error_code'] ?? body['errcode'] ?? 0;
    final errorCode =
        rawCode is int ? rawCode : int.tryParse('$rawCode') ?? 0;

    // status == 1 → 成功
    if (status == 1) {
      // ⚠️ mcomment 系列接口用 `err_code` 表达业务错误（不是 error_code/errcode）。
      //    实测「歌单/专辑楼中楼」用错端点或错 code 时返回：
      //      status=1, err_code=60102, list 为空
      //    若不检查 err_code，会被判成成功 → 不回退 kapi → 页面恒显示「暂无回复」。
      final errCode = body['err_code'];
      if (errCode is int && errCode != 0) {
        throw ApiException(
          errCode,
          '${body['error'] ?? body['error_msg'] ?? body['errmsg'] ?? body['info'] ?? '请求失败'}',
          ssaCode: r.ssaCode,
          body: body,
        );
      }
      // 警告码 + 有数据 → 放过；无数据且有错码 → 视为失败
      if (errorCode == 0 || _hasData(body)) return body;
      throw ApiException(
        errorCode,
        '${body['error'] ?? body['error_msg'] ?? body['errmsg'] ?? body['info'] ?? '请求失败'}',
        ssaCode: r.ssaCode,
        body: body,
      );
    }

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

  /// 响应里是否带有有效数据（用于判断 151/152 警告码是否可忽略）
  static bool _hasData(Map<String, dynamic> body) {
    final d = body['data'];
    if (d == null) return false;
    if (d is List) return d.isNotEmpty;
    if (d is Map) return d.isNotEmpty;
    return true;
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
      // 风控/验证（20028）不回退：回退等于同一业务请求打两次，会加重风控。
      if (e is ApiException && e.needsVerification) rethrow;
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
      case 'rank/audio':
        return _directOrFallback(() => _rankAudio(q), kapi, '/rank/audio');
      case 'top/song':
        return _directOrFallback(() => _topSong(q), kapi, '/top/song');
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
      case 'register/dev':
        return _directOrFallback(() => _registerDev(), kapi, '/register/dev');
      case 'captcha/sent':
        return _directOrFallback(() => _captchaSent(q), kapi, '/captcha/sent');
      case 'login/cellphone':
        return _directOrFallback(
            () => _loginCellphone(q), kapi, '/login/cellphone');
      case 'login/token':
        return _directOrFallback(() => _loginToken(q), kapi, '/login/token');
      case 'login/qr/key':
        return _directOrFallback(() => _loginQrKey(q), kapi, '/login/qr/key');
      case 'login/qr/create':
        return _directOrFallback(
            () => _loginQrCreate(q), kapi, '/login/qr/create');
      case 'login/qr/check':
        return _directOrFallback(
            () => _loginQrCheck(q), kapi, '/login/qr/check');
      case 'user/detail':
        return _directOrFallback(() => _userDetail(q), kapi, '/user/detail');
      case 'get/verify/info':
        return _directOrFallback(
            () => _getVerifyInfo(q), kapi, '/get/verify/info');
      case 'search/hot':
        return _directOrFallback(() => _searchHot(q), kapi, '/search/hot');
      case 'yueku/banner':
        return _directOrFallback(() => _yuekuBanner(q), kapi, '/yueku/banner');
      case 'video/detail':
        return _directOrFallback(() => _videoDetail(q), kapi, '/video/detail');
      case 'artist/audios':
        return _directOrFallback(() => _artistAudios(q), kapi, '/artist/audios');
      case 'artist/detail':
        return _directOrFallback(() => _artistDetail(q), kapi, '/artist/detail');
      case 'artist/albums':
        return _directOrFallback(() => _artistAlbums(q), kapi, '/artist/albums');
      case 'album/detail':
        return _directOrFallback(() => _albumDetail(q), kapi, '/album/detail');
      case 'album/songs':
        return _directOrFallback(() => _albumSongs(q), kapi, '/album/songs');
    }
    return super.get(path, query: query);
  }

  @override
  Future<Map<String, dynamic>> post(String path, dynamic data,
      {Map<String, dynamic>? query}) async {
    final q = query ?? const <String, dynamic>{};
    final d = data is Map<String, dynamic> ? data : const <String, dynamic>{};
    final n = _norm(path);
    final kapi = () => super.post(path, data, query: query);
    switch (n) {
      case 'rank/audio':
        return _directOrFallback(() => _rankAudio(q), kapi, '/rank/audio');
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
      case 'login':
        return _directOrFallback(() => _login(q, d), kapi, '/login');
      case 'verify/user/info':
        return _directOrFallback(
            () => _verifyUserInfo(d), kapi, '/verify/user/info');
      case 'artist/detail':
        return _directOrFallback(
            () => _artistDetail({...q, ...d}), kapi, '/artist/detail');
      case 'artist/albums':
        return _directOrFallback(
            () => _artistAlbums({...q, ...d}), kapi, '/artist/albums');
      case 'album/detail':
        return _directOrFallback(
            () => _albumDetail({...q, ...d}), kapi, '/album/detail');
      case 'album/songs':
        return _directOrFallback(
            () => _albumSongs({...q, ...d}), kapi, '/album/songs');
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
      // 实测：kapi /search 返回的是 version=3 结构（/v3/search/song），
      // 与 gateway /v2 逐字段差异大（v2 无 HQ/SQ/Res.Hash，多 40+ Android 字段）。
      // 改打原生域名 complexsearch + /v3，与 kapi 结构完全一致（0 差异）。
      return kg.request('/v3/search/song',
          method: 'GET',
          baseUrl: 'https://complexsearch.kugou.com',
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
          baseUrl: 'https://complexsearch.kugou.com',
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
        baseUrl: 'https://complexsearch.kugou.com',
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
    // 源码（comment_music.js）无 x-router/baseURL → 上游即打 gateway.kugou.com
    // 的 /mcomment/v1/cmtlist（mcomment 服务本身挂在 gateway 根路径下，两标签）。
    // 实测匿名/VIP 均 200 status=1；与 kapi 差异仅运行时字段（like.count ±1、
    // config.input_hint、canUploadImg 等 A/B 文案），Repository 无感知。
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
        // 实测 sum.comment.service.kugou.com 为三标签域名，*.kugou.com 单层
        // 通配证书不覆盖（openssl SAN 仅 *.kugou.com/*.kgimg.com，python/curl
        // 一致 CERTIFICATE_VERIFY_FAILED Hostname mismatch）→ 保持 gateway +
        // x-router（web 签名）。实测 200，与 kapi 逐字段一致（0 差异）。
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
    // 源码（comment_floor.js）：song → /mcomment/v1/hot_replylist（gateway 根路径，
    // 无独立 baseURL）；playlist/album → gateway 路由前缀 m.comment.service/。
    // 实测 song 分支必须带 childrenid（=special_child_id，Repository 传的
    // special_id 即它；只传 mixsongid 报 err_code=10002『歌曲不存在』）。
    // 带 childrenid 后与 kapi（/comment/floor?special_id=&tid=）逐字段一致（0 差异）。
    return kg.request(
        isPlaylistOrAlbum
            ? '/m.comment.service/v1/hot_replylist'
            : '/mcomment/v1/hot_replylist',
        method: 'POST',
        params: {
          // childrenid：song 分支取 special_id（special_child_id），
          // playlist/album 分支源码同样传 special_id
          'childrenid': q['special_id'],
          'need_show_image': 1,
          'p': q['page'] ?? 1,
          'pagesize': q['pagesize'] ?? 30,
          'show_classify': q['show_classify'] ?? 1,
          'show_hotword_list': q['show_hotword_list'] ?? 1,
          'code': switch (resourceType) {
            // 歌单评论 code（实测：配 /m.comment.service 端点才返回 err_code=0）
            'playlist' => 'ca53b96fe5a1d9c22d71c8f522ef7c4f',
            // 专辑评论 code
            'album' => '94f1792ced1df89aa68a7939eaf2efca',
            // 歌曲评论 code
            _ => 'fc4be23b4e972707f36b8a828a93ba8a',
          },
          'tid': q['tid'],
          if (q['mixsongid'] != null) 'mixsongid': q['mixsongid'],
        });
  }

  // ---------------- 首页 ----------------

  Future<KgResponse> _yueku() {
    // 实测 service.mobile.kugou.com 证书为网宿 CDN 证书（CN=default.chinanetcenter.com，
    // SAN 不含该三标签域名），Dart/Dio 会 TLS 拒绝 → 保持 gateway + x-router。
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

  // ---------- 歌手 / 专辑（原生 openapi.kugou.com，实测字段见 docs/api_samples） ----------

  /// 歌手详情（module/artist_detail.js）
  /// POST /kmr/v3/author + x-router: openapi.kugou.com + kg-tid: 36
  Future<KgResponse> _artistDetail(Map<String, dynamic> q) {
    return kg.request('/kmr/v3/author',
        method: 'POST',
        data: {'author_id': '${q['id'] ?? q['author_id'] ?? ''}'},
        headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '36'});
  }

  /// 歌手单曲（module/artist_audios.js）
  /// POST openapi.kugou.com/kmr/v1/audio_group/author，kg-tid: 220
  ///
  /// ⚠️ 必须用 v1 而非 v2：
  ///   v1（/kmr/v1/audio_group/author）→ `data` 是 **List**、顶层有 `total`，
  ///   字段平铺在顶层（hash / timelength / audio_name），与本仓库解析口径一致；
  ///   v2（/kmr/v2/audio_group/author）→ `data` 是 **Map**（data.songs / data.total），
  ///   且 hash/timelength 藏在 `audio_info` 内 —— 解析会得到空列表且**不会触发回退**
  ///   （响应 status=1 / error_code=0，_wrap 判成功）。
  /// 实测 v1 匿名可返回 30 首，pagesize 上限 100（超过 error_code=20010）。
  Future<KgResponse> _artistAudios(Map<String, dynamic> q) {
    var ps = int.tryParse('${q['pagesize'] ?? 30}') ?? 30;
    if (ps > 100) ps = 100;
    // clienttime 是**秒级**（Node: Math.floor(Date.now()/1000)）
    final clienttime = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    return kg.request('/kmr/v1/audio_group/author',
        method: 'POST',
        // 【实测】签名输入 = **defaultParams + body 全部参数**（query 同样
        // 带上 body 的字段），不是「query 只有 signature」。
        //   ❌ clearDefaultParams: true → ec=20006（签名对不上）
        //   ❌ 默认参数不带 body 字段 → 同样 ec=20006
        // Node artist_audios.js 的 body 显式给 appid/clientver/mid/clienttime/key，
        // 而 util/request.js 会把 defaultParams 与 options.params 合并后参与签名。
        data: {
          'appid': KgConfig.appid,
          'clientver': KgConfig.clientver,
          'mid': kg.device.mid,
          'clienttime': clienttime,
          // signParamsKey(clienttime) = md5(appid + salt + clientver + clienttime)
          'key': KgSignature.paramsKey(clienttime),
          'author_id': '${q['id'] ?? q['author_id'] ?? ''}',
          'area_code': 'all',
          // 1：最热，2：最新
          'sort': q['sort'] == 'hot' ? 1 : 2,
          'page': int.tryParse('${q['page'] ?? 1}') ?? 1,
          'pagesize': ps,
        },
        headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '220'});
  }

  /// 歌手专辑（module/artist_albums.js）Postg /kmr/v1/author/albums，kg-tid: 36
  Future<KgResponse> _artistAlbums(Map<String, dynamic> q) {
    return kg.request('/kmr/v1/author/albums',
        method: 'POST',
        data: {
          'author_id': '${q['id'] ?? q['author_id'] ?? ''}',
          'pagesize': int.tryParse('${q['pagesize'] ?? 30}') ?? 30,
          'page': int.tryParse('${q['page'] ?? 1}') ?? 1,
          // 3：最热，1：最新
          'sort': q['sort'] == 'hot' ? 3 : 1,
          'category': 1,
          'area_code': 'all',
        },
        headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '36'});
  }

  /// 专辑详情（module/album_detail.js）kg-tid: 255
  Future<KgResponse> _albumDetail(Map<String, dynamic> q) {
    return kg.request('/kmr/v2/albums',
        method: 'POST',
        data: {
          'data': [
            {'album_id': '${q['id'] ?? q['album_id'] ?? ''}'}
          ],
          'is_buy': q['is_buy'] ?? 0,
          'fields': 'album_id,album_name,publish_date,sizable_cover,intro,'
              'language,is_publish,heat,type,quality,authors,exclusive,'
              'author_name,trans_param',
        },
        headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '255'});
  }

  /// 专辑歌曲（module/album_songs.js）kg-tid: 255
  Future<KgResponse> _albumSongs(Map<String, dynamic> q) {
    return kg.request('/v1/album_audio/lite',
        method: 'POST',
        data: {
          'album_id': '${q['id'] ?? q['album_id'] ?? ''}',
          'is_buy': q['is_buy'] ?? '',
          'page': int.tryParse('${q['page'] ?? 1}') ?? 1,
          'pagesize': int.tryParse('${q['pagesize'] ?? 30}') ?? 30,
        },
        headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '255'});
  }

  /// 榜单歌曲列表（module/rank_audio.js）
  /// POST gateway /openapi/kmr/v2/rank/audio，kg-tid: 369
  ///
  /// 【实测】data 是 Map：`{total, songlist[]}`。songlist 项字段：
  /// songname / author_name / authors[].author_name / audio_id /
  /// album_audio_id / album_info{sizable_cover,album_name} /
  /// audio_info{hash_128,hash_320,hash_flac,duration_128,...} /
  /// trans_param{union_cover} / video_info{video_hash}
  ///
  /// ⚠️ 签名用 **defaultParams + body**（dfid/mid/uuid/appid/clientver/
  /// clienttime 参与签名且同时进 query）——与 artist_audios 那种
  /// clearDefaultParams 模式相反，勿混用。
  Future<KgResponse> _rankAudio(Map<String, dynamic> q) {
    return kg.request('/openapi/kmr/v2/rank/audio',
        method: 'POST',
        headers: {'kg-tid': '369'},
        data: {
          'show_portrait_mv': 1,
          'show_type_total': 1,
          'filter_original_remarks': 1,
          'area_code': 1,
          'pagesize': int.tryParse('${q['pagesize'] ?? 30}') ?? 30,
          'rank_cid': 0,
          'type': 1,
          'page': int.tryParse('${q['page'] ?? 1}') ?? 1,
          'rank_id': int.tryParse('${q['rankid'] ?? q['rank_id'] ?? 0}') ?? 0,
        });
  }

  Future<KgResponse> _rankList(Map<String, dynamic> q) {
    // 原生域名 ocean.kugou.com：gateway 的路由前缀 ocean/ 需去掉（带前缀 404）。
    return kg.request('/v6/rank/list',
        method: 'GET',
        baseUrl: 'https://ocean.kugou.com',
        params: {
          'plat': 2,
          'withsong': q['withsong'] ?? 1,
          'parentid': 0,
        });
  }

  /// 新歌速递（module/top_song.js）。
  /// 原生域名 musicadservice.kugou.com（去掉 gateway 路由前缀 musicadservice/）。
  /// 实测：POST body {rank_id,userid,page,pagesize,tags:[]}，data 为数组，
  /// 与 kapi /top/song 结构逐字段一致（0 差异）。
  Future<KgResponse> _topSong(Map<String, dynamic> q) {
    return kg.request('/container/v1/newsong_publish',
        method: 'POST',
        baseUrl: 'https://musicadservice.kugou.com',
        data: {
          'rank_id': q['type'] ?? q['rank_id'] ?? 21608,
          'userid': q['userid'] ?? kg.userid,
          'page': q['page'] ?? 1,
          'pagesize': q['pagesize'] ?? 30,
          'tags': const <String>[],
        });
  }

  Future<KgResponse> _everydayRecommend(Map<String, dynamic> q) {
    // 实测 everydayrec.service.kugou.com 为三标签域名，*.kugou.com 通配符证书
    // 不覆盖 → Dart/Dio TLS 拒绝，保持 gateway + x-router。
    //
    // 【实测】`platform` 必须是 **query 参数**（放 body 里无效，上游不认），
    // 默认 'ios'。
    return kg.request('/everyday_song_recommend',
        method: 'POST',
        headers: {'x-router': 'everydayrec.service.kugou.com'},
        params: {'platform': '${q['platform'] ?? 'ios'}'});
  }

  Future<KgResponse> _topPlaylist(Map<String, dynamic> q) {
    // Node top_playlist.js: `const dateTime = (Date.now()/1000).toFixed(0)` —— **秒级**。
    // （此前误用 YYYYMMDDHH，导致 signParamsKey 的输入与 Node 不一致 → ec=200101）
    final dateTime = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    return kg.request('/v2/special_recommend',
        method: 'POST',
        // 【实测】special_recommend 直连恒 ec=200101（匿名/VIP、多组参数均
        // 复现，Node 上游同样如此），该端点疑似上游已收紧 → 保留 kapi 回退。
        // 实测 specialrec.service.kugou.com 为三标签域名，*.kugou.com 证书不覆盖
        // （SAN 仅 *.kugou.com），Dart/Dio TLS 拒绝 → 保持 gateway + x-router。
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

  /// 热搜（search_hot.js）。
  /// 原生域名 msearch.kugou.com（两标签，*.kugou.com 通配证书覆盖，实测 TLS OK），
  /// gateway 路由前缀 msearch/ 需去掉。实测 200 status=1，data.list[] 每项
  /// 含 name + keywords[]，与 kapi /search/hot 结构一致。
  Future<KgResponse> _searchHot(Map<String, dynamic> q) {
    return kg.request('/api/v3/search/hot_tab',
        method: 'GET',
        baseUrl: 'https://msearch.kugou.com',
        params: {
          'navid': q['navid'] ?? 1,
          'plat': q['plat'] ?? 2,
        });
  }

  /// 乐库 banner（yueku_banner.js）。
  /// 源码无 x-router/baseURL → gateway 的 /ads.gateway/v3/listen_banner。
  /// 【实测】匿名态恒返回 error_code=31136（无数据）——Node 版同样如此
  /// （依赖登录态/风控态），属上游行为非实现差异；失败由 _wrap 抛出 →
  /// _directOrFallback 回退 kapi（同样 31136）→ fetchBanners 容错置空。
  Future<KgResponse> _yuekuBanner(Map<String, dynamic> q) {
    return kg.request('/ads.gateway/v3/listen_banner',
        method: 'POST',
        data: {
          'plat': 0,
          'channel': 201,
          'operator': 7,
          'networktype': 2,
          'userid': q['userid'] ?? kg.userid,
          'vip_type': 0,
          'm_type': 0,
          'tags': const <String>[],
          'apiver': 5,
          'ability': 2,
          'mode': 'normal',
        });
  }

  /// 视频详情（video_detail.js）。
  /// 原生域名 kmr.service.kugou.com 为三标签域名，*.kugou.com 单层通配证书
  /// 不覆盖（docs/api_report_player.md：TLS 硬失败）→ 保持 gateway + x-router。
  /// 实测 200 status=1，data 数组首项含 hd/sd/qhd/ld_hash、timelength 等，
  /// 与 kapi /video/detail 结构一致（既往验证 + 本轮复核）。
  Future<KgResponse> _videoDetail(Map<String, dynamic> q) {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final dfid = kg.device.dfid.isEmpty ? '-' : kg.device.dfid;
    return kg.request('/v1/video',
        method: 'POST',
        clearDefaultParams: true,
        headers: {'x-router': 'kmr.service.kugou.com'},
        data: {
          'appid': kg.lite ? KgConfig.liteAppid : KgConfig.appid,
          'clientver': kg.lite ? KgConfig.liteClientver : KgConfig.clientver,
          'clienttime': clienttime,
          'mid': kg.device.mid,
          'uuid': KgCrypto.md5('$dfid${kg.device.mid}'),
          'dfid': dfid,
          'token': kg.token,
          'key': KgSignature.paramsKey('$clienttime', lite: kg.lite),
          'show_resolution': 1,
          'data': [
            for (final id in '${q['id'] ?? q['ids'] ?? ''}'.split(','))
              if (id.trim().isNotEmpty) {'video_id': id.trim()},
          ],
        });
  }

  // ---------------- 歌单 ----------------  /// 歌单详情。
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
        baseUrl: 'https://pubsongs.kugou.com',
        data: {
          // data 必须 1..10 项，每项用 global_collection_id 定位
          'data': [
            for (final id in ids.take(10)) {'global_collection_id': id},
          ],
        });
  }

  Future<KgResponse> _playlistTrackAll(Map<String, dynamic> q) {
    final pagesize = int.tryParse('${q['pagesize'] ?? 30}') ?? 30;
    final page = int.tryParse('${q['page'] ?? 1}') ?? 1;
    final rawId = '${q['id'] ?? q['global_collection_id'] ?? ''}'.trim();

    // 【实测】`global_collection_id` 只接受 `collection_...` 形式；
    // 传纯数字（specialid）时上游返回空 → 改用 `specialid` 参数键。
    final isCollection = rawId.startsWith('collection_');
    final params = <String, dynamic>{
      'area_code': 1,
      'begin_idx': (page - 1) * pagesize,
      'plat': 1,
      'type': 1,
      'mode': 1,
      'personal_switch': 1,
      'extend_fields': 'abtags,hot_cmt,popularization',
      'pagesize': pagesize,
      if (isCollection)
        'global_collection_id': rawId
      else
        'specialid': rawId,
    };

    return kg.request('/v2/get_other_list_file_nofilt',
        method: 'GET',
        // 原生域名 pubsongs.kugou.com：gateway 路由前缀 pubsongs/ 需去掉（带前缀 404）。
        baseUrl: 'https://pubsongs.kugou.com',
        params: params);
  }

  // ---------------- MV ----------------

  Future<KgResponse> _kmrAudioMv(Map<String, dynamic> q) {
    // 【实测】body 必须是 `{'data':[{'album_audio_id':X}],'fields':...}`，
    // **不是** `mixsongid`（传 mixsongid 上游返回 [{}] 空对象）。
    final ids = '${q['album_audio_id'] ?? q['mixsongid'] ?? ''}'
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != 'null')
        .toList();
    return kg.request('/kmr/v1/audio/mv',
        method: 'POST',
        // 原生域名 openapi.kugou.com（两标签，*.kugou.com 证书覆盖，实测 TLS ok）：
        // 去掉 x-router，匿名/VIP 实测 200 status=1，与 kapi 逐字段一致（0 差异）。
        baseUrl: 'https://openapi.kugou.com',
        headers: {'KG-TID': '38'},
        data: {
          'data': ids.map((s) => {'album_audio_id': s}).toList(),
          'fields': q['fields'] ?? '',
        });
  }

  Future<KgResponse> _videoUrl(Map<String, dynamic> q) async {
    final hash = '${q['hash'] ?? ''}';
    final r = await kg.request('/v2/interface/index',
        method: 'GET',
        // 原生域名 trackermv.kugou.com（两标签，*.kugou.com 证书覆盖）：
        // 匿名/VIP 实测 200 status=1，data[hash].downurl/backupdownurl 与 kapi
        // 逐字段一致（0 差异）。downurl 为 http://，代理转换在 Repository 层
        // AppConfig.proxyMvUrl 完成，URL 直连层只负责原样返回（不丢代理转换）。
        baseUrl: 'https://trackermv.kugou.com',
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
    // 参数构造与 KgPlayApi.songUrl **共用** KgSharedParams（别写两份）。
    //
    // 【实测】key 用**小写 hash** + `userid` 字符串（匿名 '0'），
    // signature 必填（由 kg.request 用 android 签名自动补）。
    final params = KgSharedParams.songUrl(
      client: kg,
      hash: '${q['hash'] ?? ''}',
      albumId: int.tryParse('${q['album_id'] ?? 0}') ?? 0,
      albumAudioId: int.tryParse('${q['album_audio_id'] ?? 0}') ?? 0,
      quality: '${q['quality'] ?? '128'}',
      freePart: '${q['free_part']}' == '1' || '${q['free_part']}' == 'true',
    );
    return kg.request('/v5/url',
        method: 'GET',
        // 原生域名 trackercdn.kugou.com（两标签，*.kugou.com 证书覆盖，实测 TLS ok）：
        // 匿名/VIP 实测 200 status=1，返回真实 url/backupUrl（数组）。
        // 直连仍可能遇 20028（与 IP/风控相关），_directOrFallback 已兜底回退 kapi。
        baseUrl: 'https://trackercdn.kugou.com',
        params: params);
  }

  Future<KgResponse> _privilege(Map<String, dynamic> q) {
    // 参数构造与 KgPlayApi.privilege **共用** KgSharedParams（别写两份）。
    //
    // 【实测】resource 过滤空 hash（避免把字符串 "null" 传上去）、
    // page_id 必须是 0、qualities 必须是数组（逗号串要拆）。
    final hashes = '${q['hash'] ?? ''}'.split(',');
    final albums = '${q['album_id'] ?? ''}'.split(',');
    final body = KgSharedParams.privilege(
      client: kg,
      hashes: hashes,
      albumIds: albums,
      qualities: KgSharedParams.parseQualities(q['qualities']),
    );
    return kg.request('/v2/get_res_privilege/lite',
        method: 'POST',
        // 实测 media.store.kugou.com 为三标签域名，*.kugou.com 单层通配证书
        // 不覆盖（openssl: subject CN=*.kugou.com, SAN 仅 *.kugou.com/*.kgimg.com/
        // kugou.com/kgimg.com；python/curl 一致报 CERTIFICATE_VERIFY_FAILED
        // Hostname mismatch）→ 保持 gateway + x-router（实测 200 status=1，
        // 与 kapi 逐字段一致 0 差异）。
        headers: {'x-router': 'media.store.kugou.com', 'Content-Type': 'application/json'},
        data: body);
  }

  // ---------------- 账号 / 登录 / 验证 ----------------
  //
  // 全部按 KuGouMusicApi/module 下同名 js 逐行移植：
  // 请求的 url/baseURL/method/params/data/encryptType/headers 保持一致。
  // 登录成功（status==1 且含 secu_params）时解密并回写 kg.token / kg.userid。

  /// 二维码 appid/srcappid 常量（config.json）
  static const int _qrSrcappid = 2919;

  /// 掩码手机号（形如 13*****0），酷狗登录接口要求传掩码值
  String _maskMobile(String mobile) {
    if (mobile.length < 11) return mobile;
    return '${mobile.substring(0, 2)}*****${mobile.substring(10, 11)}';
  }

  /// 酷狗设备注册（对应 module/register_dev.js，复用 kg.registerDevice）
  Future<KgResponse> _registerDev() async {
    final ok = await kg.registerDevice();
    if (ok && kg.device.dfid.isNotEmpty) {
      return KgResponse(
        status: 200,
        body: <String, dynamic>{
          'status': 1,
          'data': <String, dynamic>{'dfid': kg.device.dfid},
        },
      );
    }
    return KgResponse(
      status: 200,
      body: <String, dynamic>{'status': 0, 'error': '设备注册失败'},
    );
  }

  /// 发送短信验证码（对应 module/captcha_sent.js）
  Future<KgResponse> _captchaSent(Map<String, dynamic> q) {
    return kg.request('/v7/send_mobile_code',
        baseUrl: 'http://login.user.kugou.com',
        method: 'POST',
        encryptType: 'android',
        data: {
          'businessid': 5,
          'mobile': '${q['mobile'] ?? ''}',
          'plat': 3,
        });
  }

  /// 手机验证码登录（对应 module/login_cellphone.js）
  Future<KgResponse> _loginCellphone(Map<String, dynamic> q) async {
    final dateTime = DateTime.now().millisecondsSinceEpoch;
    final encrypt = KgCrypto.aesEncryptCbcAuto(jsonEncode({
      'mobile': '${q['mobile'] ?? ''}',
      'code': '${q['code'] ?? ''}',
    }));
    final mobile = _maskMobile('${q['mobile'] ?? ''}');
    final dfid = kg.device.dfid.isNotEmpty
        ? kg.device.dfid
        : KgCrypto.randomString(24);
    final lite = kg.lite;
    final t2 = KgCrypto.aesEncryptCbcHex(
      '${kg.device.guid}|0f607264fc6318a92b9e13c65db7cd3c|${kg.device.mac}|${kg.device.dev}|$dateTime',
      key: 'fd14b35e3f81af3817a20ae7adae7020',
      iv: '17a20ae7adae7020',
    );
    final t1 = KgCrypto.aesEncryptCbcHex('|$dateTime',
        key: '5e4ef500e9597fe004bd09a46d8add98', iv: '04bd09a46d8add98');

    final dataMap = <String, dynamic>{
      'plat': 1,
      'support_multi': 1,
      't1': lite ? t1 : 0,
      't2': lite ? t2 : 0,
      'clienttime_ms': dateTime,
      'mobile': mobile,
      'key': KgSignature.paramsKey(dateTime, lite: lite),
      'pk': KgCrypto.rsaEncryptRawHex(
        jsonEncode({'clienttime_ms': dateTime, 'key': encrypt.key}),
        lite: lite,
      ).toUpperCase(),
      'params': encrypt.str,
    };
    final uid = '${q['userid'] ?? ''}';
    if (uid.isNotEmpty) dataMap['userid'] = uid;
    if (lite) {
      dataMap['dfid'] = dfid;
      dataMap['dev'] = kg.device.dev;
      dataMap['gitversion'] = '5f0b7c4';
    } else {
      dataMap['t3'] = 'MCwwLDAsMCwwLDAsMCwwLDA=';
    }

    final r = await kg.request('/v7/login_by_verifycode',
        baseUrl: 'https://loginserviceretry.kugou.com',
        method: 'POST',
        data: dataMap,
        encryptType: 'android',
        headers: {
          'support-calm': '1',
          'User-Agent': 'Android16-1070-11440-130-0-LOGIN-wifi',
        });
    _afterLogin(r, encrypt.key);
    return r;
  }

  /// 用户名密码登录（对应 module/login.js）
  Future<KgResponse> _login(
      Map<String, dynamic> q, Map<String, dynamic> d) async {
    final dateNow = DateTime.now().millisecondsSinceEpoch;
    final encrypt = KgCrypto.aesEncryptCbcAuto(jsonEncode({
      'pwd': '${d['password'] ?? ''}',
      'code': '${d['code'] ?? q['code'] ?? ''}',
      'clienttime_ms': dateNow,
    }));
    final dataMap = <String, dynamic>{
      'plat': 1,
      'support_multi': 1,
      'clienttime_ms': dateNow,
      // t1/t2 为酷狗固定常量（与 Node 版一致）
      't1':
          '562a6f12a6e803453647d16a08f5f0c2ff7eee692cba2ab74cc4c8ab47fc467561a7c6b586ce7dc46a63613b246737c03a1dc8f8d162d8ce1d2c71893d19f1d4b797685a4c6d3d81341cbde65e488c4829a9b4d42ef2df470eb102979fa5adcdd9b4eecfea8b909ff7599abeb49867640f10c3c70fc444effca9d15db44a9a6c907731e2bb0f22cd9b3536380169995693e5f0e2424e3378097d3813186e3fe96bbe7023808a0981b4e2b6135a76faac',
      't2':
          '31c4daf4cf480169ccea1cb7d4a209295865a9d2b788510301694db229b87807469ea0d41b4d4b9173c2151da7294aeebfc9738df154bbdf11a4e117bb5dff6a3af8ce5ce333e681c1f29a44038f27567d58992eb81283e080778ac77db1400fdf49b7cf7e26be2e5af4da7830cc3be4',
      't3': 'MCwwLDAsMCwwLDAsMCwwLDA=',
      'dev': kg.device.dev,
      'username': '${d['username'] ?? q['username'] ?? ''}',
      'params': encrypt.str,
      'pk': KgCrypto.rsaEncryptRawHex(
        jsonEncode({'clienttime_ms': dateNow, 'key': encrypt.key}),
        lite: kg.lite,
      ).toUpperCase(),
    };

    final r = await kg.request('/v9/login_by_pwd',
        method: 'POST',
        data: dataMap,
        encryptType: 'android',
        headers: {'x-router': 'login.user.kugou.com'});
    _afterLogin(r, encrypt.key);
    return r;
  }

  /// 刷新登录态（对应 module/login_token.js）
  Future<KgResponse> _loginToken(Map<String, dynamic> q) async {
    final dateNow = DateTime.now().millisecondsSinceEpoch;
    final token = '${q['token'] ?? (kg.token.isNotEmpty ? kg.token : '')}';
    final userid = '${q['userid'] ?? (kg.userid.isNotEmpty ? kg.userid : '0')}';
    final lite = kg.lite;
    const key = '90b8382a1bb4ccdcf063102053fd75b8';
    const iv = 'f063102053fd75b8';
    const liteKey = 'c24f74ca2820225badc01946dba4fdf7';
    const liteIv = 'adc01946dba4fdf7';

    final encrypt = KgCrypto.aesEncryptCbcHex(
      jsonEncode({'clienttime': dateNow ~/ 1000, 'token': token}),
      key: lite ? liteKey : key,
      iv: lite ? liteIv : iv,
    );
    final encryptParams = KgCrypto.aesEncryptCbcAuto('{}');
    final pk = KgCrypto.rsaEncryptRawHex(
      jsonEncode({'clienttime_ms': dateNow, 'key': encryptParams.key}),
      lite: lite,
    );
    final t2 = KgCrypto.aesEncryptCbcHex(
      '${kg.device.guid}|0f607264fc6318a92b9e13c65db7cd3c|${kg.device.mac}|${kg.device.dev}|$dateNow',
      key: 'fd14b35e3f81af3817a20ae7adae7020',
      iv: '17a20ae7adae7020',
    );
    // 上游逻辑：cookie.t1 存在时为「t1|dateNow」，否则「|dateNow」
    final t1Plain = kg.t1.isNotEmpty ? '${kg.t1}|$dateNow' : '|$dateNow';
    final t1 = KgCrypto.aesEncryptCbcHex(t1Plain,
        key: '5e4ef500e9597fe004bd09a46d8add98', iv: '04bd09a46d8add98');

    final dataMap = <String, dynamic>{
      'dfid': kg.device.dfid.isNotEmpty ? kg.device.dfid : '-',
      'p3': encrypt,
      'plat': 1,
      't1': lite ? t1 : 0,
      't2': lite ? t2 : 0,
      't3': 'MCwwLDAsMCwwLDAsMCwwLDA=',
      'pk': pk,
      'params': encryptParams.str,
      'userid': userid,
      'clienttime_ms': dateNow,
    };
    if (lite) dataMap['dev'] = kg.device.dev;

    final r = await kg.request('/v5/login_by_token',
        baseUrl: 'http://login.user.kugou.com',
        method: 'POST',
        data: dataMap,
        encryptType: 'android');
    _afterLogin(r, encryptParams.key);
    return r;
  }

  /// 二维码 key 生成（对应 module/login_qr_key.js）
  Future<KgResponse> _loginQrKey(Map<String, dynamic> q) {
    final type = '${q['type'] ?? ''}';
    return kg.request('/v2/qrcode',
        baseUrl: 'https://login-user.kugou.com',
        method: 'GET',
        encryptType: 'web',
        params: {
          'appid': type == 'web' ? 1014 : 1001,
          'type': 1,
          'plat': 4,
          'qrcode_txt':
              'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=${KgConfig.appid}&',
          'srcappid': _qrSrcappid,
        });
  }

  /// 二维码图片生成（对应 module/login_qr_create.js，本地生成 PNG base64）
  Future<KgResponse> _loginQrCreate(Map<String, dynamic> q) async {
    final key = '${q['key'] ?? ''}';
    final url =
        'https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=$key';
    final wantImg = '${q['qrimg'] ?? ''}' == '1' || q['qrimg'] == 1;
    final b64 = wantImg ? await _qrPngBase64(url) : '';
    return KgResponse(
      status: 200,
      body: <String, dynamic>{
        'code': 200,
        'status': 200,
        'data': <String, dynamic>{'url': url, 'base64': b64, 'key': key},
      },
    );
  }

  /// 用 qr_flutter 把二维码 URL 渲染为 PNG base64
  Future<String> _qrPngBase64(String data) async {
    try {
      final painter = QrPainter(
        data: data,
        version: QrVersions.auto,
        gapless: true,
      );
      final bytes = await painter.toImageData(480);
      if (bytes == null) return '';
      return base64.encode(bytes.buffer.asUint8List());
    } catch (e) {
      _logError('二维码生成', e);
      return '';
    }
  }

  /// 二维码状态检测（对应 module/login_qr_check.js）
  Future<KgResponse> _loginQrCheck(Map<String, dynamic> q) async {
    // 直连不像 kapi 会自动加时间戳，这里自行加入以绕过缓存
    final timestamp =
        q['timestamp'] ?? DateTime.now().millisecondsSinceEpoch.toString();
    final r = await kg.request('/v2/get_userinfo_qrcode',
        baseUrl: 'https://login-user.kugou.com',
        method: 'GET',
        encryptType: 'web',
        params: {
          'plat': 4,
          'appid': KgConfig.appid,
          'srcappid': _qrSrcappid,
          'qrcode': q['key'],
          'dev': kg.device.dev,
          'timestamp': timestamp,
          '_t': timestamp,
        });
    final data = r.body['data'];
    if (data is Map && '${data['status']}' == '4') {
      final token = '${data['token'] ?? ''}';
      final userid = '${data['userid'] ?? ''}';
      if (token.isNotEmpty) kg.token = token;
      if (userid.isNotEmpty && userid != '0') kg.userid = userid;
    }
    return r;
  }

  /// 用户信息（对应 module/user_detail.js）
  Future<KgResponse> _userDetail(Map<String, dynamic> q) async {
    final token = '${q['token'] ?? (kg.token.isNotEmpty ? kg.token : '')}';
    final userid = int.tryParse(
            '${q['userid'] ?? (kg.userid.isNotEmpty ? kg.userid : '0')}') ??
        0;
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final pk = KgCrypto.rsaEncryptRawHex(
      jsonEncode({'token': token, 'clienttime': clienttime}),
      lite: kg.lite,
    ).toUpperCase();
    final resp = await kg.request('/v3/get_my_info',
        method: 'POST',
        params: {'plat': 1},
        data: {
          'visit_time': clienttime,
          'usertype': 1,
          'p': pk,
          'userid': userid,
        },
        encryptType: 'android',
        headers: {'x-router': 'usercenter.kugou.com'});
    // 实测响应无 userid 字段，而上层 AuthRepository 读 data.userid → 回填
    final d = resp.body;
    final inner = d['data'];
    if (inner is Map<String, dynamic>) {
      inner['userid'] = userid.toString();
    }
    return resp;
  }

  /// 获取人机验证信息（对应 module/get_verify_info.js）
  Future<KgResponse> _getVerifyInfo(Map<String, dynamic> q) {
    final userid = int.tryParse(
            '${q['userid'] ?? (kg.userid.isNotEmpty ? kg.userid : '0')}') ??
        0;
    return kg.request('/verifyservice/v3/get_verify_info',
        method: 'POST',
        encryptType: 'android',
        data: {
          'eventid': q['eventid'],
          'userid': userid,
          'platid': q['platid'] ?? 2,
          'rtype': 1,
          'wasm': 1,
          'i': '',
          'sid': '',
          'edt': '',
        });
  }

  /// 提交人机验证结果（对应 module/verify_user_info.js）
  Future<KgResponse> _verifyUserInfo(Map<String, dynamic> d) {
    final vType = int.tryParse('${d['v_type'] ?? 23}') ?? 23;
    final userid = int.tryParse(
            '${d['userid'] ?? (kg.userid.isNotEmpty ? kg.userid : '0')}') ??
        0;
    final sid = Uri.decodeComponent('${d['sid'] ?? ''}');
    final edt = Uri.decodeComponent('${d['edt'] ?? ''}');
    var dataMap = <String, dynamic>{
      'eventid': d['eventid'],
      'userid': userid,
      'platid': d['platid'] ?? 2,
      'v_type': vType,
      'wasm': 1,
      'i': '',
      'sid': sid,
      'edt': edt,
    };
    if (vType == 23) {
      final encrypt = KgCrypto.aesEncryptCbcAuto('{}');
      dataMap = {
        ...dataMap,
        'verifycode': Uri.decodeComponent('${d['verifycode'] ?? ''}'),
        'pk': KgCrypto.rsaEncryptRawHex(jsonEncode({'key': encrypt.key}),
            lite: kg.lite),
        'params': encrypt.str,
      };
    } else if (vType == 32) {
      final encrypt = KgCrypto.aesEncryptCbcAuto(
          jsonEncode({'code': '${d['verifycode'] ?? ''}'}));
      dataMap = {
        ...dataMap,
        'code': Uri.decodeComponent('${d['verifycode'] ?? ''}'),
        'pk': KgCrypto.rsaEncryptRawHex(jsonEncode({'key': encrypt.key}),
            lite: kg.lite),
        'params': encrypt.str,
      };
    }
    return kg.request('/v4/verify_user_info',
        baseUrl: 'https://verifyservice.kugou.com',
        method: 'POST',
        params: {'clientver': 11510},
        data: dataMap,
        encryptType: 'android');
  }

  /// 登录成功后：解密 secu_params 合并进 data，并回写 kg.token / kg.userid
  void _afterLogin(KgResponse r, String tempKey) {
    final body = r.body;
    if (body['status'] != 1) return;
    final data = body['data'];
    if (data is! Map) return;
    final sp = data['secu_params'];
    if (sp is String && sp.isNotEmpty) {
      try {
        final dec = KgCrypto.aesDecryptCbcHex(sp, tempKey);
        if (dec is Map) {
          dec.forEach((k, v) => data['$k'] = v);
        } else if (dec is String && dec.isNotEmpty) {
          data['token'] = dec;
        }
      } catch (e) {
        _logError('secu_params 解密', e);
      }
    }
    final token = '${data['token'] ?? ''}';
    final userid = '${data['userid'] ?? ''}';
    if (token.isNotEmpty) kg.token = token;
    if (userid.isNotEmpty && userid != '0') kg.userid = userid;
    final t1 = data['t1']?.toString();
    if (t1 != null && t1.isNotEmpty) kg.t1 = t1;
  }
}
