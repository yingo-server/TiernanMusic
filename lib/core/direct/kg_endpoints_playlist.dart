import 'dart:convert';

import 'kg_client.dart';
import 'kg_crypto.dart';

import 'kg_direct_api_client.dart';
import '../api/kugou_api_client.dart' show ApiException;

/// 歌单端点（详情/歌曲/收藏/增删/用户歌单）
///
/// 【实测结论见各方法注释与 docs/api_verified.md】
/// 从 kg_direct_api_client.dart 拆出（R1 重构）；由主类组合调用，
/// 行为与拆分前完全一致。
///
/// 方法签名与主类拆分前一致；由 KgDirectApiClient 组合委托。
class KgEndpointPlaylist {
  KgEndpointPlaylist(this.kg);
  final KgClient kg;

  Future<KgResponse> playlistDel(Map<String, dynamic> q) async {
    final userid = kg.userid.isEmpty ? '0' : kg.userid;
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final aes = KgCrypto.aesEncryptHex(jsonEncode({
      'listid': int.tryParse('${q['listid'] ?? 0}') ?? 0,
      'total_ver': 0,
      'type': 1,
    }));
    // P0-4（审查①）：Node rsaEncrypt2 = RSAES-PKCS1-V1_5 填充（crypto.js:264-270），
    // 此前误用无填充裸 RSA，服务端无法解出 {aes,uid,token}。
    final p = KgCrypto.rsaEncryptPkcs1(
      jsonEncode({'aes': aes.key, 'uid': userid, 'token': kg.token}),
    ).toUpperCase();

    final res = await kg.request('/v2/delete_list',
        method: 'POST',
        headers: {'x-router': 'cloudlist.service.kugou.com'},
        params: {
          'clienttime': '$clienttime',
          'key': KgSignature.paramsKey('$clienttime'),
          'last_area': 'gztx',
          'clientver': KgConfig.clientver,
          'appid': KgConfig.appid,
          'last_time': '$clienttime',
          'p': p,
        },
        data: aes.str);

    // 响应是 AES 加密二进制，用同一 seed 解密
    try {
      final bytes = res.rawBytes;
      if (bytes != null && bytes.isNotEmpty) {
        final decoded = KgCrypto.aesDecryptPlaylistB64(base64Encode(bytes), aes.key);
        if (decoded.containsKey('status')) {
          return KgResponse(
            status: res.status,
            body: decoded,
            headers: res.headers,
          );
        }
      }
    } catch (_) {
      // 解密失败不影响判定
    }
    return res;
  }

  /// 收藏/新建歌单（module/playlist_add.js，需登录）
  /// POST /cloudlist.service/v5/add_list
  /// type=1 收藏公共歌单（需 list_create_userid/list_create_listid/gid）
  /// type=0 新建歌单
  Future<KgResponse> playlistAdd(Map<String, dynamic> q) {
    final userid = kg.userid.isEmpty ? '0' : kg.userid;
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final type = int.tryParse('${q['type'] ?? 0}') ?? 0;
    return kg.request('/cloudlist.service/v5/add_list',
        method: 'POST',
        params: type == 0
            ? {
                'last_time': '$clienttime',
                'last_area': 'gztx',
                'userid': userid,
                'token': kg.token,
              }
            : const <String, dynamic>{},
        data: {
          'userid': userid,
          'token': kg.token,
          'total_ver': 0,
          'name': '${q['name'] ?? ''}',
          'type': type,
          'source': 1,
          'is_pri': 0,
          if (q['list_create_userid'] != null)
            'list_create_userid': '${q['list_create_userid']}',
          if (q['list_create_listid'] != null)
            'list_create_listid': '${q['list_create_listid']}',
          'list_create_gid': '${q['list_create_gid'] ?? ''}',
          'from_shupinmv': 0,
        });
  }

  /// 歌单加歌（module/playlist_tracks_add.js，需登录）
  /// POST /cloudlist.service/v6/add_song
  /// data 为 `名称|hash|album_id|album_audio_id` 逗号分隔（空字段要占位，不能跳）
  Future<KgResponse> playlistTracksAdd(Map<String, dynamic> q) {
    final userid = kg.userid.isEmpty ? '0' : kg.userid;
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // P0-5（审查①）：Node 把 `名称|hash|album_id|album_audio_id` 逗号串解析成
    // 对象数组再发送（playlist_tracks_add.js:8-21）；字符串形态会导致参数错误。
    final resource = _parseTracksResource('${q['data'] ?? q['songs'] ?? ''}');
    return kg.request('/cloudlist.service/v6/add_song',
        method: 'POST',
        params: {
          'last_time': '$clienttime',
          'last_area': 'gztx',
          'userid': userid,
          'token': kg.token,
        },
        data: {
          'userid': userid,
          'token': kg.token,
          'listid': '${q['listid'] ?? ''}',
          'list_ver': 0,
          'type': 0,
          'slow_upload': 1,
          'scene': 'false;null',
          'data': resource,
        });
  }

  /// 歌单删歌（module/playlist_tracks_del.js，需登录）
  /// POST /v4/delete_songs，x-router cloudlist.service.kugou.com
  Future<KgResponse> playlistTracksDel(Map<String, dynamic> q) {
    final userid = kg.userid.isEmpty ? '0' : kg.userid;
    // PLY-06（审查①-B，P1）：路径去掉 cloudlist.service/ 前缀（与 x-router 叠加会 404），
    // body 只保留 Node dataMap 的 6 个键，去掉自加的 area_code/allplatform。
    return kg.request('/v4/delete_songs',
        method: 'POST',
        headers: {'x-router': 'cloudlist.service.kugou.com'},
        data: {
          'listid': '${q['listid'] ?? ''}',
          'userid': userid,
          'data': '${q['fileids'] ?? q['data'] ?? ''}'
              .split(',')
              .where((e) => e.trim().isNotEmpty)
              .map((e) => {'fileid': int.tryParse(e.trim()) ?? 0})
              .toList(),
          'type': 0,
          'token': kg.token,
          'list_ver': 0,
        });
  }

  /// 我的歌单（module/user_playlist.js，需登录）
  /// POST gateway /v7/get_all_list，x-router cloudlist.service.kugou.com
  /// 参数：query 带 plat/userid/token，body 带 total_ver/type/page/pagesize
  Future<KgResponse> userPlaylist(Map<String, dynamic> q) {
    final userid = kg.userid.isEmpty ? '0' : kg.userid;
    return kg.request('/v7/get_all_list',
        method: 'POST',
        headers: {'x-router': 'cloudlist.service.kugou.com'},
        params: {'plat': 1, 'userid': userid, 'token': kg.token},
        data: {
          'userid': userid,
          'token': kg.token,
          'total_ver': 979,
          'type': 2,
          'page': q['page'] ?? 1,
          'pagesize': q['pagesize'] ?? 30,
        });
  }

  /// 用户歌单歌曲（module/playlist_track_all_new.js，需登录）
  /// POST gateway /v4/get_list_all_file_v3，x-router cloudlist.service.kugou.com
  Future<KgResponse> userPlaylistTracks(Map<String, dynamic> q) {
    final userid = kg.userid.isEmpty ? '0' : kg.userid;
    return kg.request('/v4/get_list_all_file_v3',
        method: 'POST',
        headers: {'x-router': 'cloudlist.service.kugou.com'},
        data: {
          'listid': '${q['listid'] ?? q['id'] ?? ''}',
          'userid': userid,
          'type': int.tryParse('${q['type'] ?? 0}') ?? 0,
          'page': int.tryParse('${q['page'] ?? 1}') ?? 1,
          'pagesize': int.tryParse('${q['pagesize'] ?? 300}') ?? 300,
          'area_code': 1,
          'allplatform': 1,
          'show_cover': 1,
          'token': kg.token,
        });
  }

  /// 歌单评论（module/comment_playlist.js）
  /// POST /m.comment.service/v1/cmtlist，参数走 **query**
  /// childrenid = global_collection_id，code = 歌单码，content_type=0，tag=5

  /// 歌单详情。
  ///
  /// 实测：载荷必须是 `{"data": [{"global_collection_id": "<gid>"}]}`。
  /// 旧写法 `{"listid": [...]}` 不管传 gid 还是数字 specialid、不管 v1/v2/v3
  /// 都返回 `status=0 error_code=20010`（v2 附带 errmsg `data len need in [1, 10]`）。
  /// 数字 listid（用户歌单）不被接受，只认 `collection_x_uid_xx` 形式的 gid。
  Future<KgResponse> playlistDetail(Map<String, dynamic> q) {
    final ids = '${q['ids'] ?? q['global_collection_id'] ?? ''}'
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    // PLY-07（审查①-B，P1）：Node playlist_detail.js 必带 userid/token；
    // 超过 10 个 gid 时上游只接受 1..10，显式拒绝而非静默截断。
    if (ids.isEmpty) {
      throw ApiException(-2, '歌单详情缺少 global_collection_id');
    }
    if (ids.length > 10) {
      throw ApiException(-2, '歌单详情一次最多 10 个 gid（收到 ${ids.length}）');
    }
    final userid = kg.userid.isEmpty ? '0' : kg.userid;
    return kg.request('/v3/get_list_info',
        method: 'POST',
        baseUrl: 'https://pubsongs.kugou.com',
        data: {
          // data 必须 1..10 项，每项用 global_collection_id 定位
          'data': [
            for (final id in ids) {'global_collection_id': id},
          ],
          'userid': userid,
          'token': kg.token,
        });
  }

  Future<KgResponse> playlistTrackAll(Map<String, dynamic> q) {
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
}

/// `名称|hash|album_id|album_audio_id` 逗号分隔串 → Node 形态的对象数组
/// （对应 Node playlist_tracks_add.js:8-21 的 split(',').map(...)）
List<Map<String, dynamic>> _parseTracksResource(String raw) {
  if (raw.trim().isEmpty) return const [];
  return raw
      .split(',')
      .where((e) => e.trim().isNotEmpty)
      .map((e) {
        final f = e.split('|');
        String f0(int i) => i < f.length ? f[i].trim() : '';
        return {
          // PLY-05（审查①-B，P1）：补齐 Node playlist_tracks_add.js 必带的
          // number/size/sort/timelen/bitrate 五字段，缺字段会导致加歌失败。
          'number': 1,
          'name': f0(0),
          'hash': f0(1),
          'size': 0,
          'sort': 0,
          'timelen': 0,
          'bitrate': 0,
          'album_id': int.tryParse(f0(2)) ?? 0,
          'mixsongid': int.tryParse(f0(3)) ?? 0,
        };
      })
      .toList();
}
