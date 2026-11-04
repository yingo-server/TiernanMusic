import 'dart:convert';

import 'kg_client.dart';
import 'kg_crypto.dart';

import 'kg_direct_api_client.dart';

/// 歌手与专辑端点
///
/// 【实测结论见各方法注释与 docs/api_verified.md】
/// 从 kg_direct_api_client.dart 拆出（R1 重构）；由主类组合调用，
/// 行为与拆分前完全一致。
///
/// 方法签名与主类拆分前一致；由 KgDirectApiClient 组合委托。
class KgEndpointArtistAlbum {
  KgEndpointArtistAlbum(this.kg);
  final KgClient kg;



  /// 歌手详情（module/artist_detail.js）
  /// POST /kmr/v3/author + x-router: openapi.kugou.com + kg-tid: 36
  Future<KgResponse> artistDetail(Map<String, dynamic> q) {
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
  Future<KgResponse> artistAudios(Map<String, dynamic> q) {
    var ps = int.tryParse('${q['pagesize'] ?? 30}') ?? 30;
    if (ps > 100) ps = 100;
    // clienttime 是**秒级**（Node: Math.floor(Date.now()/1000)）
    final clienttime = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    return kg.request('/kmr/v1/audio_group/author',
        method: 'POST',
        // 【实测】该端点的 key 由**服务端从 body 读**，签名只校验 defaultParams。
        // 三种形态实测结果：
        //   A) query=defaultParams+signature，body 另带 appid/key/... → ✅ st=1
        //   B) query=defaultParams+body字段+signature → ✅ st=1
        //   C) clearDefaultParams（query 只有 body 字段）→ ❌ ec=20006
        // 故保持 A（默认参数进 query + body 独立），不要开 clearDefaultParams。
        // 注意 body 里的 clienttime 必须是**秒级**，key=signParamsKey(clienttime)。
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
  Future<KgResponse> artistAlbums(Map<String, dynamic> q) {
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
  Future<KgResponse> albumDetail(Map<String, dynamic> q) {
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
  Future<KgResponse> albumSongs(Map<String, dynamic> q) {
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
  Future<KgResponse> rankAudio(Map<String, dynamic> q) {
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
}
