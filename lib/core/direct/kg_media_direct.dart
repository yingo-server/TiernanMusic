import 'dart:convert';

import 'kg_client.dart';
import 'kg_crypto.dart';

/// 图片与视频详情直连（images / images_audio / video/detail）
extension KgMediaDirect on KgClient {
  /// 歌曲封面（hash+album_id+album_audio_id 组合）
  ///
  /// 返回 {data: [{hash, filename, imgsize, cover: 'http://...'}]}
  Future<KgResponse> images({
    required String hash,
    String albumId = '',
    String albumAudioId = '',
    int count = 5,
  }) {
    final data = <Map<String, dynamic>>[];
    final hashes = hash.split(',').where((s) => s.isNotEmpty).toList();
    final albums = albumId.split(',');
    final aas = albumAudioId.split(',');
    for (var i = 0; i < hashes.length; i++) {
      data.add({
        'hash': hashes[i],
        'album_id': i < albums.length ? albums[i] : '0',
        'album_audio_id': i < aas.length ? aas[i] : '0',
      });
    }
    final params = <String, dynamic>{
      'appid': lite ? KgConfig.liteAppid : KgConfig.appid,
      'clientver': lite ? KgConfig.liteClientver : KgConfig.clientver,
      'count': count,
      'data': data,
      'isCdn': 1,
      'publish_time': 1,
      'show_authors': 1,
    };
    // 该接口签名拼在 query 末尾，参数不做默认注入
    final signature = KgSignature.android(params, lite: lite);
    final q = <String, String>{
      for (final e in params.entries)
        e.key: e.value is Map || e.value is List
            ? jsonEncode(e.value)
            : '${e.value}',
      'signature': signature,
    };
    return request(
      '/v2/author_image/audio?${Uri(queryParameters: q).query}',
      baseUrl: 'https://expendablekmr.kugou.com',
      method: 'GET',
      clearDefaultParams: true,
      notSignature: true,
    );
  }

  /// 视频详情（POST /v1/video，kmr.service.kugou.com）
  ///
  /// 返回更高清 hash 与 resolution 列表
  Future<KgResponse> videoDetail({
    required String videoId,
  }) {
    final dfid = device.dfid.isEmpty ? '-' : device.dfid;
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final uuid = KgCrypto.md5('$dfid${device.mid}');
    final key = KgSignature.paramsKey('$clienttime', lite: lite);
    return request('/v1/video',
        method: 'POST',
        clearDefaultParams: true,
        // 实测 kmr.service.kugou.com 为三标签域名，*.kugou.com 单层通配证书不覆盖
        // （openssl: subject CN=*.kugou.com, SAN 仅 *.kugou.com/*.kgimg.com/kugou.com/
        // kgimg.com；python urllib 报 CERTIFICATE_VERIFY_FAILED Hostname mismatch，
        // 证书 not valid for 'kmr.service.kugou.com'）→ 保持 gateway + x-router
        // （实测 200 status=1，data 数组与 kapi /video/detail 一致）。
        headers: {'x-router': 'kmr.service.kugou.com'},
        data: {
          'appid': lite ? KgConfig.liteAppid : KgConfig.appid,
          'clientver': lite ? KgConfig.liteClientver : KgConfig.clientver,
          'clienttime': clienttime,
          'mid': device.mid,
          'uuid': uuid,
          'dfid': dfid,
          'token': token,
          'key': key,
          'show_resolution': 1,
          'data': [
            {'video_id': videoId}
          ],
        });
  }
}
