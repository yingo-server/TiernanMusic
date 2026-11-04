import 'dart:convert';

import 'kg_client.dart';
import 'kg_crypto.dart';

import 'kg_direct_api_client.dart';

/// 媒体端点（MV/视频/播放地址/权益）
///
/// 【实测结论见各方法注释与 docs/api_verified.md】
/// 从 kg_direct_api_client.dart 拆出（R1 重构）；由主类组合调用，
/// 行为与拆分前完全一致。
///
/// 方法签名与主类拆分前一致；由 KgDirectApiClient 组合委托。
class KgEndpointMedia {
  KgEndpointMedia(this.kg);
  final KgClient kg;



  Future<KgResponse> kmrAudioMv(Map<String, dynamic> q) {
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

  Future<KgResponse> videoUrl(Map<String, dynamic> q) async {
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



  Future<KgResponse> songUrl(Map<String, dynamic> q) {
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

  Future<KgResponse> privilege(Map<String, dynamic> q) {
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
}
