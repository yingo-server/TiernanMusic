/// 内容接口直连适配器
///
/// 继承 [KugouApiClient]，覆写 get/post，把已移植的接口直接打到酷狗网关，
/// 未移植的路径回退到父类（kapi 中转）。这样所有既有 Repository 无需改动。
library;

import 'dart:convert';
import '../foundation/errors.dart' show ApiException;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'kg_client.dart';
import '../domain/response_policy.dart';
import 'kg_crypto.dart';
import 'kg_endpoints_search.dart';
import 'kg_endpoints_comment.dart';
import 'kg_endpoints_playlist.dart';
import 'kg_endpoints_media.dart';
import 'kg_endpoints_artist_album.dart';
import 'kg_endpoints_home.dart';
import 'kg_endpoints_auth.dart';
import 'kg_play_api.dart';
import '../api/kugou_api_client.dart';

class KgDirectApiClient extends KugouApiClient {
  KgDirectApiClient(this.kg, {super.baseUrl});

  final KgClient kg;

  /// P0-3（审查①）：同步登录态到 KgClient。
  /// setCredentials 只更新父类字段与 CookieJar，直连层的签名取 kg.token/kg.userid，
  /// 不同步则冷启动 login/token 首次请求缺登录态（与 Node cookie 注入行为不一致）。
  @override
  Future<void> setCredentials({
    required String token,
    required String userid,
    String? t1,
    String? auth,
    String? dfid,
  }) async {
    kg.token = token;
    kg.userid = userid;
    if (t1 != null) kg.t1 = t1;
    if (dfid != null && dfid.isNotEmpty) {
      // V3-09（第5批复核①，P1）：登录下发的 dfid 必须同时落到 device.dfid
      //（第 5 条：状态单一来源）。全类签名/头构造都取 device.dfid，
      // 只写 kg.dfid 会让同步变成空操作，签名/风控维度与账号不匹配。
      kg.dfid = dfid;
      kg.device.dfid = dfid;
    }
    await super.setCredentials(
        token: token, userid: userid, t1: t1, auth: auth, dfid: dfid);
  }

  @override
  Future<void> clearCredentials() async {
    kg.token = '';
    kg.userid = '0';
    kg.t1 = '';
    await super.clearCredentials();
  }

  // ---- 端点组（R1 拆分：实现移至 kg_endpoints_*.dart，本类只做委托）----
  late final _epSearch = KgEndpointSearch(kg);
  late final _epComment = KgEndpointComment(kg);
  late final _epPlaylist = KgEndpointPlaylist(kg);
  late final _epMedia = KgEndpointMedia(kg);
  late final _epArtistAlbum = KgEndpointArtistAlbum(kg);
  late final _epHome = KgEndpointHome(kg);
  late final _epAuth = KgEndpointAuth(kg);

  /// 依据响应构造与 kapi 一致的 Map（业务失败抛 ApiException）
  ///
  /// 成功判定看 **`status == 1`**。
  /// `errcode`/`error_code` 为 151/152 等**警告码**时，只要响应里**有数据**
  /// （data 非空）就不算失败 —— 实测这两个码常与有效数据同时出现，
  /// 按「errcode != 0 即失败」判定会误杀正常响应。
  /// v5.0 M4：成功/异常判定已上移 [evaluateResponse]（Bridge-N 单点）。
  /// 本层只保留「KgResponse → body/ssaCode」适配，禁止在此重写业务语义。
  Map<String, dynamic> _wrap(KgResponse r) {
    final outcome = evaluateResponse(r.body, ssaCode: r.ssaCode);
    if (!outcome.isOk) throw outcome.failure!;
    return outcome.body;
  }


  /// 是否允许回退 kapi 中转。
  ///
  /// PLY-13（2026-11-06 用户口径，QUALITY_STANDARD 第 27 条）：**kapi 仅作为原生
  /// 接口的参考，不得实际调用**。因此该开关永久为 false；kapi 只保留在
  /// 文档与 Node 参考源码里用于对照，运行期绝不发起请求。
  static const bool fallbackToKapi = false;

  /// 记录最近一次错误（供"网络诊断"页展示）
  static final List<String> lastErrors = <String>[];

  void _logError(String where, Object e) {
    final msg = '[${DateTime.now().toIso8601String()}] $where: $e';
    lastErrors.insert(0, msg);
    if (lastErrors.length > 20) lastErrors.removeLast();
    debugPrint(msg);
  }

  /// 先直连，失败则回退 kapi
  ///
  /// PLY-08（审查①-A，P0）：写操作（发评论/收藏/加歌/删歌…）**禁止**回退——
  /// 直连请求可能已被服务端执行，只是响应超时或解析失败；再打一次 kapi
  /// 会重复提交（重复评论、歌单里两条同名、同批歌加两遍）。
  Future<Map<String, dynamic>> _directOrFallback(
    Future<KgResponse> Function() direct,
    Future<Map<String, dynamic>> Function() kapi,
    String label, {
    bool write = false,
  }) async {
    try {
      return _wrap(await direct());
    } on ApiException catch (e) {
      _logError(label, e);
      // P0-1（审查①）：保持与 kapi 拦截器一致的异常契约——
      // 上层（AuthRepository/verification_guard）只捕获 DioException 并从
      // .error 取 ApiException。直连若裸抛会被上层泛 catch 吞掉，
      // 导致 20028 验证、20034 多账号、token 失效清理全部失效。
      if (write ||
          !fallbackToKapi ||
          e.needsVerification ||
          e.errorCode == 20034) {
        throw _asDioException(label, e);
      }
      try {
        return await kapi();
      } catch (e2) {
        // PLY-09（审查①-A，P1）：回退路径异常统一包装为 DioException，
        // 否则上层 on DioException 捕不到，验证/多账号/token 清理失效。
        _logError('$label (kapi 回退)', e2);
        throw _asDioException(label, e2);
      }
    } catch (e) {
      _logError(label, e);
      // 编程错误（TypeError/NoSuchMethodError）不回退、不吞，直接暴露
      if (e is TypeError || e is NoSuchMethodError) rethrow;
      if (write || !fallbackToKapi) {
        throw _asDioException(label, e);
      }
      try {
        return await kapi();
      } catch (e2) {
        _logError('$label (kapi 回退)', e2);
        throw _asDioException(label, e2);
      }
    }
  }

  /// 统一异常形态：无论底层抛什么，上层拿到的都是 DioException + error=ApiException
  static DioException _asDioException(String label, Object e) {
    if (e is DioException) return e;
    return DioException(
      requestOptions: RequestOptions(path: label),
      error: e is ApiException ? e : ApiException(-1, '$e'),
    );
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
      case 'comment/floor/send':
        return _directOrFallback(
            () => _commentFloorSend(q), kapi, '/comment/floor/send', write: true);
      case 'comment/music/del':
        return _directOrFallback(
            () => _commentDel(q), kapi, '/comment/music/del', write: true);
      case 'comment/music/send':
      case 'comment/playlist/send':
      case 'comment/album/send':
        return _directOrFallback(
            () => _commentSend(q), kapi, '/comment/${n}/send', write: true);
      case 'playlist/del':
        return _directOrFallback(() => _epPlaylist.playlistDel(q), kapi, '/playlist/del',
            write: true);
      case 'playlist/add':
        return _directOrFallback(() => _playlistAdd(q), kapi, '/playlist/add', write: true);
      case 'playlist/tracks/add':
        return _directOrFallback(
            () => _playlistTracksAdd(q), kapi, '/playlist/tracks/add', write: true);
      case 'playlist/tracks/del':
        return _directOrFallback(
            () => _playlistTracksDel(q), kapi, '/playlist/tracks/del', write: true);
      case 'user/playlist':
        return _directOrFallback(() => _userPlaylist(q), kapi, '/user/playlist');
      case 'playlist/track/all/new':
        return _directOrFallback(
            () => _userPlaylistTracks(q), kapi, '/playlist/track/all/new');
      case 'comment/playlist':
        return _directOrFallback(
            () => _commentPlaylist(q), kapi, '/comment/playlist');
      case 'comment/album':
        return _directOrFallback(
            () => _commentAlbum(q), kapi, '/comment/album');
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
    // PLY-14（QUALITY_STANDARD 第 27 条）：未移植路径**不得**回退 kapi 中转。
    // 明确报错，让缺失的功能暴露出来，而不是悄悄依赖第三方网关。
    // V3-08（第5批复核①，P1）：异常契约必须单一（第 8 条）——上层只捕获
    // DioException 并从 .error 取 ApiException，裸抛会被泛 catch 吞掉。
    throw _asDioException(
      '/$n',
      ApiException(
        -404,
        '接口 /$n 尚未移植到原生网关（kapi 仅作参考，运行期不调用）',
      ),
    );
  }

  @override
  Future<Map<String, dynamic>> post(String path, dynamic data,
      {Map<String, dynamic>? query}) async {
    final q = query ?? const <String, dynamic>{};
    final d = data is Map<String, dynamic> ? data : const <String, dynamic>{};
    final n = _norm(path);
    final kapi = () => super.post(path, data, query: query);
    switch (n) {
      // D-P0-1（第5批①，P0）：评论写三件套此前只在 get 分派表里，
      // 而 CommentRepository 走 post → 恒抛 -404「未移植」，发评论/
      // 回复/删评论 100% 失效。补齐 post 分派（write: true 禁回退）。
      case 'comment/music/send':
      case 'comment/playlist/send':
      case 'comment/album/send':
        return _directOrFallback(() => _commentSend(q), kapi, '/comment/$n/send',
            write: true);
      case 'comment/floor/send':
        return _directOrFallback(() => _commentFloorSend(q), kapi,
            '/comment/floor/send', write: true);
      case 'comment/music/del':
        return _directOrFallback(
            () => _commentDel(q), kapi, '/comment/music/del', write: true);
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
    // PLY-14（QUALITY_STANDARD 第 27 条）：同上，未移植路径不回退 kapi。
    // V3-08（第5批复核①，P1）：同上，异常统一包装为 DioException（第 8 条）。
    throw _asDioException(
      '/$n',
      ApiException(
        -404,
        '接口 /$n 尚未移植到原生网关（kapi 仅作参考，运行期不调用）',
      ),
    );
  }

  static String _norm(String p) =>
      p.startsWith('/') ? p.substring(1) : p;

  // ---------------- 搜索 ----------------

  Future<KgResponse> _search(Map<String, dynamic> q) async  => _epSearch.search(q);

  /// 歌词搜索。
  ///
  /// 实测：lyrics.kugou.com 上 `/v1/search` 恒返回**空响应体 + HTTP 200**，
  /// 响应头 `x-kg-errcode: 20010`（10 种参数/UA/Referer/签名组合全部一样空），
  /// 加 `x-router` 头也一样空。真正存在的路径是 `/search`（无版本前缀），
  /// 返回 `x-kg-errcode: 200` 与 candidates 数组。
  /// 该接口不校验 signature，保持 clearDefaultParams + notSignature。
  /// duration 传毫秒：搜索结果 Duration 是秒，服务端候选 duration=269792。
  Future<KgResponse> _searchLyric(Map<String, dynamic> q)  => _epSearch.searchLyric(q);

  Future<KgResponse> _lyric(Map<String, dynamic> q) async  => _epSearch.lyric(q);

  // ---------------- 评论 ----------------

  Future<KgResponse> _commentMusic(Map<String, dynamic> q)  => _epComment.commentMusic(q);

  Future<KgResponse> _commentCount(Map<String, dynamic> q)  => _epComment.commentCount(q);

  /// 发评论（module/_comment.js buildCommentSendConfig，需登录）
  ///
  /// POST /index.php?r=commentsv3/add
  /// - clearDefaultParams + notSignature（自带 key，不走通用签名）
  /// - key = signParamsKey(clienttime + mid + data)
  /// - x-router m.comment.service.kugou.com
  Future<KgResponse> _commentSend(Map<String, dynamic> q)  => _epComment.commentSend(q);

  /// 楼中楼回复（module/_comment.js buildCommentReplyConfig，需登录）
  /// POST /index.php?r=commentsv2/reply
  /// key = signParamsKey(clienttime + mid)（**不含 data**）
  Future<KgResponse> _commentFloorSend(Map<String, dynamic> q)  => _epComment.commentFloorSend(q);

  /// 删除评论（module/_comment.js buildCommentDelConfig，需登录）
  /// POST /index.php?r=commentsv2/delcomment
  Future<KgResponse> _commentDel(Map<String, dynamic> q)  => _epComment.commentDel(q);

  /// 评论资源类型 → code
  static String _commentCodeOf(String resourceType) => switch (resourceType) {
        'playlist' => 'ca53b96fe5a1d9c22d71c8f522ef7c4f',
        'album' => '94f1792ced1df89aa68a7939eaf2efca',
        _ => 'fc4be23b4e972707f36b8a828a93ba8a',
      };

  /// 删除/取消收藏歌单（module/playlist_del.js，需登录）
  ///
  /// 协议：body = playlistAesEncrypt({listid, total_ver:0, type:1}) 的 Base64，
  /// query `p` = RSA 加密串，响应为 AES 二进制。实现见
  /// `kg_endpoints_playlist.dart:playlistDel`。

  /// 收藏/新建歌单（module/playlist_add.js，需登录）
  /// POST /cloudlist.service/v5/add_list
  /// type=1 收藏公共歌单（需 list_create_userid/list_create_listid/gid）
  /// type=0 新建歌单
  Future<KgResponse> _playlistAdd(Map<String, dynamic> q)  => _epPlaylist.playlistAdd(q);

  /// 歌单加歌（module/playlist_tracks_add.js，需登录）
  /// POST /cloudlist.service/v6/add_song
  /// data 为 `名称|hash|album_id|album_audio_id` 逗号分隔（空字段要占位，不能跳）
  Future<KgResponse> _playlistTracksAdd(Map<String, dynamic> q)  => _epPlaylist.playlistTracksAdd(q);

  /// 歌单删歌（module/playlist_tracks_del.js，需登录）
  /// POST /cloudlist.service/v4/delete_songs，x-router cloudlist.service.kugou.com
  Future<KgResponse> _playlistTracksDel(Map<String, dynamic> q)  => _epPlaylist.playlistTracksDel(q);

  /// 我的歌单（module/user_playlist.js，需登录）
  /// POST gateway /v7/get_all_list，x-router cloudlist.service.kugou.com
  /// 参数：query 带 plat/userid/token，body 带 total_ver/type/page/pagesize
  Future<KgResponse> _userPlaylist(Map<String, dynamic> q)  => _epPlaylist.userPlaylist(q);

  /// 用户歌单歌曲（module/playlist_track_all_new.js，需登录）
  /// POST gateway /v4/get_list_all_file_v3，x-router cloudlist.service.kugou.com
  Future<KgResponse> _userPlaylistTracks(Map<String, dynamic> q)  => _epPlaylist.userPlaylistTracks(q);

  /// 歌单评论（module/comment_playlist.js）
  /// POST /m.comment.service/v1/cmtlist，参数走 **query**
  /// childrenid = global_collection_id，code = 歌单码，content_type=0，tag=5
  Future<KgResponse> _commentPlaylist(Map<String, dynamic> q)  => _epComment.commentPlaylist(q);

  /// 专辑评论（module/comment_album.js）
  /// POST /m.comment.service/v1/cmtlist，childrenid = album_id，code = 专辑码
  Future<KgResponse> _commentAlbum(Map<String, dynamic> q)  => _epComment.commentAlbum(q);

  Future<KgResponse> _commentFloor(Map<String, dynamic> q)  => _epComment.commentFloor(q);

  // ---------------- 首页 ----------------

  Future<KgResponse> _yueku()  => _epHome.yueku();

  // ---------- 歌手 / 专辑（原生 openapi.kugou.com，实测字段见 docs/api_samples） ----------

  /// 歌手详情（module/artist_detail.js）
  /// POST /kmr/v3/author + x-router: openapi.kugou.com + kg-tid: 36
  Future<KgResponse> _artistDetail(Map<String, dynamic> q)  => _epArtistAlbum.artistDetail(q);

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
  Future<KgResponse> _artistAudios(Map<String, dynamic> q)  => _epArtistAlbum.artistAudios(q);

  /// 歌手专辑（module/artist_albums.js）Postg /kmr/v1/author/albums，kg-tid: 36
  Future<KgResponse> _artistAlbums(Map<String, dynamic> q)  => _epArtistAlbum.artistAlbums(q);

  /// 专辑详情（module/album_detail.js）kg-tid: 255
  Future<KgResponse> _albumDetail(Map<String, dynamic> q)  => _epArtistAlbum.albumDetail(q);

  /// 专辑歌曲（module/album_songs.js）kg-tid: 255
  Future<KgResponse> _albumSongs(Map<String, dynamic> q)  => _epArtistAlbum.albumSongs(q);

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
  Future<KgResponse> _rankAudio(Map<String, dynamic> q)  => _epArtistAlbum.rankAudio(q);

  Future<KgResponse> _rankList(Map<String, dynamic> q)  => _epHome.rankList(q);

  /// 新歌速递（module/top_song.js）。
  /// 原生域名 musicadservice.kugou.com（去掉 gateway 路由前缀 musicadservice/）。
  /// 实测：POST body {rank_id,userid,page,pagesize,tags:[]}，data 为数组，
  /// 与 kapi /top/song 结构逐字段一致（0 差异）。
  Future<KgResponse> _topSong(Map<String, dynamic> q)  => _epHome.topSong(q);

  Future<KgResponse> _everydayRecommend(Map<String, dynamic> q)  => _epHome.everydayRecommend(q);

  Future<KgResponse> _topPlaylist(Map<String, dynamic> q)  => _epHome.topPlaylist(q);

  /// 热搜（search_hot.js）。
  /// 原生域名 msearch.kugou.com（两标签，*.kugou.com 通配证书覆盖，实测 TLS OK），
  /// gateway 路由前缀 msearch/ 需去掉。实测 200 status=1，data.list[] 每项
  /// 含 name + keywords[]，与 kapi /search/hot 结构一致。
  Future<KgResponse> _searchHot(Map<String, dynamic> q)  => _epHome.searchHot(q);

  /// 乐库 banner（yueku_banner.js）。
  /// 源码无 x-router/baseURL → gateway 的 /ads.gateway/v3/listen_banner。
  /// 【实测】匿名态恒返回 error_code=31136（无数据）——Node 版同样如此
  /// （依赖登录态/风控态），属上游行为非实现差异；失败由 _wrap 抛出 →
  /// _directOrFallback 回退 kapi（同样 31136）→ fetchBanners 容错置空。
  Future<KgResponse> _yuekuBanner(Map<String, dynamic> q)  => _epHome.yuekuBanner(q);

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
  Future<KgResponse> _playlistDetail(Map<String, dynamic> q)  => _epPlaylist.playlistDetail(q);

  Future<KgResponse> _playlistTrackAll(Map<String, dynamic> q)  => _epPlaylist.playlistTrackAll(q);

  // ---------------- MV ----------------

  Future<KgResponse> _kmrAudioMv(Map<String, dynamic> q)  => _epMedia.kmrAudioMv(q);

  Future<KgResponse> _videoUrl(Map<String, dynamic> q) async  => _epMedia.videoUrl(q);

  // ---------------- 播放/权益（供 kapi 回退路径复用） ----------------

  Future<KgResponse> _songUrl(Map<String, dynamic> q)  => _epMedia.songUrl(q);

  Future<KgResponse> _privilege(Map<String, dynamic> q)  => _epMedia.privilege(q);

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
  Future<KgResponse> _registerDev() async  => _epAuth.registerDev();

  /// 发送短信验证码（对应 module/captcha_sent.js）
  Future<KgResponse> _captchaSent(Map<String, dynamic> q)  => _epAuth.captchaSent(q);

  /// 手机验证码登录（对应 module/login_cellphone.js）
  Future<KgResponse> _loginCellphone(Map<String, dynamic> q) async  => _epAuth.loginCellphone(q);

  /// 用户名密码登录（对应 module/login.js）
  Future<KgResponse> _login(
      Map<String, dynamic> q, Map<String, dynamic> d) async  => _epAuth.login(q, d);

  /// 刷新登录态（对应 module/login_token.js）
  Future<KgResponse> _loginToken(Map<String, dynamic> q) async  => _epAuth.loginToken(q);

  /// 二维码 key 生成（对应 module/login_qr_key.js）
  Future<KgResponse> _loginQrKey(Map<String, dynamic> q)  => _epAuth.loginQrKey(q);

  /// 二维码图片生成（对应 module/login_qr_create.js，本地生成 PNG base64）
  Future<KgResponse> _loginQrCreate(Map<String, dynamic> q) async  => _epAuth.loginQrCreate(q);

  Future<String> _qrPngBase64(String data) => _epAuth.qrPngBase64(data);

  /// 二维码状态检测（对应 module/login_qr_check.js）
  Future<KgResponse> _loginQrCheck(Map<String, dynamic> q) async  => _epAuth.loginQrCheck(q);

  /// 用户信息（对应 module/user_detail.js）
  Future<KgResponse> _userDetail(Map<String, dynamic> q) async  => _epAuth.userDetail(q);

  /// 获取人机验证信息（对应 module/get_verify_info.js）
  Future<KgResponse> _getVerifyInfo(Map<String, dynamic> q)  => _epAuth.getVerifyInfo(q);

  /// 提交人机验证结果（对应 module/verify_user_info.js）
  Future<KgResponse> _verifyUserInfo(Map<String, dynamic> d)  => _epAuth.verifyUserInfo(d);

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
