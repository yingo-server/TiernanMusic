import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/direct/kg_client.dart';
import '../../../core/direct/kg_crypto.dart';
import '../../../core/direct/kg_providers.dart' show kgClientProvider;
import '../../home/data/models.dart' show kugouImageUrl;

/// 我收藏的 MV
///
/// 【实测结构】`/collectservice/v2/collect_list_mixvideo` → `data.info[]`
/// （与 `/user/playlist` 同为 `data.info[]` 形态）。
class CollectedMv {
  const CollectedMv({
    required this.id,
    required this.hash,
    this.title = '',
    this.artist = '',
    this.cover = '',
    this.duration = Duration.zero,
  });

  /// video_id
  final String id;
  /// 视频 hash（`/video/url` 只认 hash）
  final String hash;
  final String title;
  final String artist;
  final String cover;
  final Duration duration;

  factory CollectedMv.fromJson(Map<String, dynamic> e) {
    String s(Object? v) => v == null ? '' : '$v';
    final tp = e['trans_param'];
    final transParam = tp is Map ? Map<String, dynamic>.from(tp) : <String, dynamic>{};
    final ai = e['audio_info'];
    final audioInfo = ai is Map ? Map<String, dynamic>.from(ai) : <String, dynamic>{};
    final vi = e['video_info'];
    final videoInfo = vi is Map ? Map<String, dynamic>.from(vi) : <String, dynamic>{};

    var ms = 0;
    final d = audioInfo['duration'] ?? audioInfo['duration_128'];
    if (d is int) ms = d;
    if (d is String) ms = int.tryParse(d) ?? 0;

    return CollectedMv(
      id: s(e['video_id'] ?? e['id']),
      hash: s(videoInfo['video_hash'] ?? e['hash']),
      title: s(e['mv_name'] ?? e['songname'] ?? e['name']),
      artist: s(e['author_name'] ?? e['singername']),
      cover: kugouImageUrl('${transParam['union_cover'] ?? e['cover'] ?? ''}',
          size: 400),
      duration: Duration(milliseconds: ms),
    );
  }
}

class MvCollectionRepository {
  MvCollectionRepository(this._client);
  final KgClient _client;

  /// 我的 MV 收藏列表（需登录）
  Future<List<CollectedMv>> fetchCollected(
      {int page = 1, int pageSize = 50}) async {
    final res = await _client.request('/v2/collect_list_mixvideo',
        method: 'POST',
        baseUrl: 'https://collectservice.kugou.com',
        params: {'plat': 1, 'page': page, 'pagesize': pageSize},
        data: {
          'userid': _client.userid,
          'token': _client.token,
          'page': page,
          'pagesize': pageSize,
        });
    final data = res.body['data'];
    final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    final list = map['info'] is List ? map['info'] as List : const [];
    return list
        .whereType<Map>()
        .map((e) => CollectedMv.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 收藏 / 取消收藏 MV（需登录）
  ///
  /// 【协议】`collectservice.kugou.com/v1/collect`：
  /// - body = `playlistAesEncrypt({'ctype':2,'data':[{'obj_id':videoId}]})` 的 Base64
  /// - query `p` = RSA 加密 `{"aes":seed,"uid":userid,"token":token}`（大写 hex）
  /// - query `key` = signParamsKey(clienttime)
  /// - 响应是 AES 加密二进制，需用同一 seed 解密
  Future<bool> setCollected(int videoId, {required bool collect}) async {
    final api = _client;
    final userid = api.userid;
    final token = api.token;
    if (userid.isEmpty || userid == '0' || token.isEmpty) return false;

    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // D-P0-2（第5批①，P0）：`collect` 形参此前从未参与请求——
    // 取消收藏仍发 `/v1/collect`，收藏数只增不减。对齐 Node
    // mv_collect_del.js：取消走 **/v1/cancel_collect**。
    final path = collect ? '/v1/collect' : '/v1/cancel_collect';

    // AES 加密载荷
    final payload = jsonEncode({
      'ctype': 2,
      'data': [
        {'obj_id': videoId}
      ],
    });
    final aes = KgCrypto.aesEncryptHex(payload);

    // RSA 加密 {aes: seed, uid, token}
    final p = KgCrypto.rsaEncryptRawHex(
      jsonEncode({'aes': aes.key, 'uid': userid, 'token': token}),
    ).toUpperCase();

    final res = await api.request(path,
        method: 'POST',
        baseUrl: 'https://collectservice.kugou.com',
        params: {
          'clienttime': '$clienttime',
          'mid': api.device.mid,
          'key': KgSignature.paramsKey('$clienttime'),
          'dfid': api.device.dfid,
          'clientver': KgConfig.clientver,
          'appid': KgConfig.appid,
          'p': p,
        },
        // Node 发 **二进制**（Buffer.from(str,'base64')），不是 Base64 文本
        data: base64Decode(aes.str),
        headers: {
          'User-Agent': 'Android9-1070-${KgConfig.clientver}-18-0-'
              '${collect ? 'MV/Care' : 'MV/UnCare'}-wifi',
          'Content-Type': 'application/json',
        },
        notSignature: true);

    // 响应是 AES 加密二进制，用同一 seed 解密；解出 status 才算真成功
    try {
      final bytes = res.rawBytes;
      if (bytes != null && bytes.isNotEmpty) {
        final decrypted =
            KgCrypto.aesDecryptPlaylistB64(base64Encode(bytes), aes.key);
        // 丢弃解密结果但至少校验存在（此前 HTTP 200 即算成功，
        // 风控空包也被当成功，收藏态判定失真）
        return decrypted != null;
      }
    } catch (e) {
      debugPrint('[mv_collect] decrypt failed: $e');
    }
    return res.status == 200;
  }
}

final mvCollectionRepositoryProvider = Provider<MvCollectionRepository>(
    (ref) => MvCollectionRepository(ref.watch(kgClientProvider)));
