import 'dart:convert';

import 'kg_client.dart';
import 'kg_crypto.dart';

import 'kg_direct_api_client.dart';
import '../foundation/errors.dart' show ApiException;

/// 搜索端点（song/album/author/mv/special/lyric）
///
/// 【实测结论见各方法注释与 docs/api_verified.md】
/// 从 kg_direct_api_client.dart 拆出（R1 重构）；由主类组合调用，
/// 行为与拆分前完全一致。
///
/// 方法签名与主类拆分前一致；由 KgDirectApiClient 组合委托。
class KgEndpointSearch {
  KgEndpointSearch(this.kg);
  final KgClient kg;



  Future<KgResponse> search(Map<String, dynamic> q) async {
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
    // PLY-02（审查①-B，P1）：补齐 Node search.js else 分支必带的
    // albumhide / nocollect / iscorrection 三字段，pagesize 默认 30（Node 口径）。
    return kg.request('/v1/search/$type',
        method: 'GET',
        baseUrl: 'https://complexsearch.kugou.com',
        params: {
          'albumhide': 0,
          'iscorrection': 1,
          'keyword': keyword,
          'nocollect': 0,
          'page': q['page'] ?? 1,
          'pagesize': q['pagesize'] ?? 30,
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
  Future<KgResponse> searchLyric(Map<String, dynamic> q) {
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

  Future<KgResponse> lyric(Map<String, dynamic> q) async {
    final fmt = '${q['fmt'] ?? 'krc'}';
    // PLY-03（审查①-B，P2）：id/accesskey 为空直接拒绝，避免发出 id=null 的无效请求
    final id = '${q['id'] ?? ''}';
    final accesskey = '${q['accesskey'] ?? ''}';
    if (id.isEmpty || id == 'null' || accesskey.isEmpty || accesskey == 'null') {
      throw ApiException(-1, '歌词下载参数缺失（id/accesskey）');
    }
    final r = await kg.request('/download',
        baseUrl: 'https://lyrics.kugou.com',
        method: 'GET',
        params: {
          'ver': 1,
          'client': q['client'] ?? 'android',
          'id': id,
          'accesskey': accesskey,
          'fmt': fmt,
          'charset': 'utf8',
        });
    // decode=true 时在客户端解密（KRC）或 Base64 解码（LRC）
    if ('${q['decode']}' == 'true') {
      final body = r.body;
      final content = body['content'];
      if (content is String && content.isNotEmpty) {
        final contenttype = body['contenttype'];
        // PLY-04（审查①-B，P2）：contenttype 可能是字符串 "0"，统一按字符串比较
        final ct = '${contenttype ?? ''}';
        if (fmt == 'lrc' || (ct.isNotEmpty && ct != '0')) {
          try {
            body['decodeContent'] =
                utf8.decode(base64.decode(content), allowMalformed: true);
          } catch (_) {}
        }
      }
    }
    return r;
  }
}
