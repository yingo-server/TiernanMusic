import 'dart:convert';

import 'kg_client.dart';
import 'kg_crypto.dart';

import 'kg_direct_api_client.dart';

/// 评论端点（列表/计数/发送/回复/删除/楼中楼）
///
/// 【实测结论见各方法注释与 docs/api_verified.md】
/// 从 kg_direct_api_client.dart 拆出（R1 重构）；由主类组合调用，
/// 行为与拆分前完全一致。
///
/// 方法签名与主类拆分前一致；由 KgDirectApiClient 组合委托。
class KgEndpointComment {
  KgEndpointComment(this.kg);
  final KgClient kg;



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

  /// 发评论（module/_comment.js buildCommentSendConfig，需登录）
  ///
  /// POST /index.php?r=commentsv3/add
  /// - clearDefaultParams + notSignature（自带 key，不走通用签名）
  /// - key = signParamsKey(clienttime + mid + data)
  /// - x-router m.comment.service.kugou.com
  Future<KgResponse> _commentSend(Map<String, dynamic> q) {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final contentData = <String, dynamic>{
      'content': '${q['content'] ?? ''}',
      if (q['mixsongid'] != null) 'album_audio_id': '${q['mixsongid']}',
      if (q['title'] != null) 'title': '${q['title']}',
      'images': const <String>[],
    };
    final data = jsonEncode({'data': contentData});
    return kg.request('/index.php',
        method: 'POST',
        clearDefaultParams: true,
        notSignature: true,
        headers: {
          'x-router': 'm.comment.service.kugou.com',
          'Content-Type': 'application/json; charset=UTF-8',
        },
        params: {
          'r': 'commentsv3/add',
          'code': _commentCodeOf('${q['resource_type'] ?? 'song'}'),
          'childrenid': '${q['special_id'] ?? q['childrenid'] ?? q['id'] ?? ''}',
          if (q['name'] != null) 'childrenname': '${q['name']}',
          'kugouid': kg.userid,
          'ver': 6,
          'clienttoken': kg.token,
          'appid': KgConfig.appid,
          'clientver': KgConfig.clientver,
          'mid': kg.device.mid,
          'clienttime': '$clienttime',
          // key = md5(appid + salt + clientver + clienttime + mid + data)
          'key': KgSignature.paramsKey('$clienttime${kg.device.mid}$data'),
          'uuid': '-',
          'dfid': kg.device.dfid.isEmpty ? '-' : kg.device.dfid,
        },
        data: data);
  }

  /// 楼中楼回复（module/_comment.js buildCommentReplyConfig，需登录）
  /// POST /index.php?r=commentsv2/reply
  /// key = signParamsKey(clienttime + mid)（**不含 data**）
  Future<KgResponse> _commentFloorSend(Map<String, dynamic> q) {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final content = '${q['content'] ?? ''}';
    return kg.request('/index.php',
        method: 'POST',
        clearDefaultParams: true,
        notSignature: true,
        headers: {'x-router': 'm.comment.service.kugou.com'},
        params: {
          'r': 'commentsv2/reply',
          'code': _commentCodeOf('${q['resource_type'] ?? 'song'}'),
          'childrenid': '${q['special_id'] ?? q['childrenid'] ?? q['id'] ?? ''}',
          if (q['name'] != null) 'childrenname': '${q['name']}',
          'kugouid': kg.userid,
          'ver': 6,
          'clienttoken': kg.token,
          'appid': KgConfig.appid,
          'clientver': KgConfig.clientver,
          'mid': kg.device.mid,
          'clienttime': '$clienttime',
          'key': KgSignature.paramsKey('$clienttime${kg.device.mid}'),
          'uuid': '-',
          'dfid': kg.device.dfid.isEmpty ? '-' : kg.device.dfid,
          'content': content,
          'tid': '${q['tid'] ?? ''}',
          if (q['pid'] != null) 'pid': '${q['pid']}',
        });
  }

  /// 删除评论（module/_comment.js buildCommentDelConfig，需登录）
  /// POST /index.php?r=commentsv2/delcomment
  Future<KgResponse> _commentDel(Map<String, dynamic> q) {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return kg.request('/index.php',
        method: 'POST',
        clearDefaultParams: true,
        notSignature: true,
        headers: {'x-router': 'm.comment.service.kugou.com'},
        params: {
          'r': 'commentsv2/delcomment',
          'code': _commentCodeOf('${q['resource_type'] ?? 'song'}'),
          'childrenid': '${q['special_id'] ?? q['childrenid'] ?? q['id'] ?? ''}',
          'cid': '${q['cid'] ?? ''}',
          if (q['tid'] != null) 'tid': '${q['tid']}',
          'kugouid': kg.userid,
          'ver': 6,
          'clienttoken': kg.token,
          'appid': KgConfig.appid,
          'clientver': KgConfig.clientver,
          'mid': kg.device.mid,
          'clienttime': '$clienttime',
          'key': KgSignature.paramsKey('$clienttime${kg.device.mid}'),
          'uuid': '-',
          'dfid': kg.device.dfid.isEmpty ? '-' : kg.device.dfid,
        });
  }

  /// 评论资源类型 → code
  static String _commentCodeOf(String resourceType) => switch (resourceType) {
        'playlist' => 'ca53b96fe5a1d9c22d71c8f522ef7c4f',
        'album' => '94f1792ced1df89aa68a7939eaf2efca',
        _ => 'fc4be23b4e972707f36b8a828a93ba8a',
      };

  /// 删除/取消收藏歌单（module/playlist_del.js，需登录）
  ///
  /// 协议：body = playlistAesEncrypt({listid, total_ver:0, type:1}) 的 Base64，
  /// query `p` = RSA({aes:seed, uid, token}) 大写 hex，响应是 AES 加密二进制。

  Future<KgResponse> _commentPlaylist(Map<String, dynamic> q) {
    return kg.request('/m.comment.service/v1/cmtlist',
        method: 'POST',
        params: {
          'childrenid': '${q['id'] ?? q['childrenid'] ?? ''}',
          'need_show_image': 1,
          'p': q['page'] ?? 1,
          'pagesize': q['pagesize'] ?? 30,
          'show_classify': q['show_classify'] ?? 1,
          'show_hotword_list': q['show_hotword_list'] ?? 1,
          'code': 'ca53b96fe5a1d9c22d71c8f522ef7c4f',
          'content_type': 0,
          'tag': 5,
        });
  }

  /// 专辑评论（module/comment_album.js）
  /// POST /m.comment.service/v1/cmtlist，childrenid = album_id，code = 专辑码
  Future<KgResponse> _commentAlbum(Map<String, dynamic> q) {
    return kg.request('/m.comment.service/v1/cmtlist',
        method: 'POST',
        params: {
          'childrenid': '${q['id'] ?? q['childrenid'] ?? ''}',
          'need_show_image': 1,
          'p': q['page'] ?? 1,
          'pagesize': q['pagesize'] ?? 30,
          'show_classify': q['show_classify'] ?? 1,
          'show_hotword_list': q['show_hotword_list'] ?? 1,
          'code': '94f1792ced1df89aa68a7939eaf2efca',
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
}
