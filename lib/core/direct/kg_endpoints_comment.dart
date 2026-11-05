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



  Future<KgResponse> commentMusic(Map<String, dynamic> q) {
    // 【实测 2026-11-06】三种形态 curl 对比（mixsongid=32100650）：
    //   A  gateway + /mcomment/v1/cmtlist（无 x-router）      → 200 status=1
    //   B  gateway + /v1/cmtlist + x-router m.comment.service → 200 status=1（同数据）
    //   C  gateway + /mcomment/v1/cmtlist + x-router          → "Access Deny !!!"
    //   D  https://m.comment.service.kugou.com/v1/cmtlist     → TLS 证书不匹配（三标签域）
    // F4-04（审查①-B，P1）：改走 B —— 裸路径 + x-router，符合口径「评论走
    // x-router: m.comment.service.kugou.com」，且不会与服务前缀叠加（C 会 403）。
    return kg.request('/v1/cmtlist',
        method: 'POST',
        headers: {'x-router': 'm.comment.service.kugou.com'},
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

  Future<KgResponse> commentCount(Map<String, dynamic> q) {
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
          // F4-16（审查①-B，P2）：Node 用**真值**判定（`if (params.hash) …
          // else if (params.special_id)`）。此前只判 != null，传 hash='' 时
          // 会既发空 hash 又不发 childrenid，评论数恒 0。
          if (_nonEmpty(q['hash']))
            'hash': q['hash']
          else if (_nonEmpty(q['special_id']))
            'childrenid': q['special_id'],
        });
  }

  /// 发评论（module/_comment.js buildCommentSendConfig，需登录）
  ///
  /// POST /index.php?r=commentsv3/add
  /// - clearDefaultParams + notSignature（自带 key，不走通用签名）
  /// - key = signParamsKey(clienttime + mid + data)
  /// - x-router m.comment.service.kugou.com
  Future<KgResponse> commentSend(Map<String, dynamic> q) {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final images = q['images'];
    final contentData = <String, dynamic>{
      'content': '${q['content'] ?? ''}',
      if (q['mixsongid'] != null)
        'album_audio_id': '${q['mixsongid']}'
      else if (_nonEmpty(q['album_audio_id']))
        'album_audio_id': '${q['album_audio_id']}',
      if (q['title'] != null) 'title': '${q['title']}',
      // F4-17（审查①-B，P2）：Node compact({..., extdata: params.content_extdata,
      // images})；缺 extdata 时上游可能判为不完整请求（带歌词/来源上下文的
      // 评论会丢字段）。
      if (_nonEmpty(q['content_extdata'])) 'extdata': '${q['content_extdata']}',
      'images': images is List ? images : const <String>[],
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
          // F4-17（审查①-B，P2）：Node 的 childrenname 兼容
          // name/song_name/album_name/playlist_name 四个别名。
          if (_childName(q) != null) 'childrenname': _childName(q),
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
          // F4-17（审查①-B，P2）：Node 透传 source（来源标识），此前被丢弃。
          if (_nonEmpty(q['source'])) 'source': q['source'],
        },
        data: data);
  }

  /// 楼中楼回复（module/_comment.js buildCommentReplyConfig，需登录）
  /// POST /index.php?r=commentsv2/reply
  /// key = signParamsKey(clienttime + mid)（**不含 data**）
  Future<KgResponse> commentFloorSend(Map<String, dynamic> q) {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // F4-05（审查①-B，P1）：对齐 Node：
    //   pid = firstValue(params.pid, 0)
    //   is_t = firstValue(params.is_t, params.isT, pid == '0' ? 1 : 0)
    // 缺 is_t 时服务端分不清「主楼回复」与「楼中楼回复」，回复会挂错层级/被丢弃。
    final pid = _nonEmpty(q['pid']) ? '${q['pid']}' : '0';
    final isTopLevel = q['is_t'] ?? q['isT'] ?? (pid == '0' ? 1 : 0);
    final replyUserName = q['reply_user_name'] ?? q['puser'];
    final replyContent = q['reply_content'] ?? q['pcontent'];
    var content = '${q['content'] ?? ''}';
    // F4-05：Node 仅在「有被回复人 + 有被回复内容 + 正文尚未含 //@」时拼接
    // `content//@user:原评论`；不拼则对方收不到回复提醒。
    if (_nonEmpty(replyUserName) &&
        _nonEmpty(replyContent) &&
        !content.contains('//@')) {
      content = '$content//@$replyUserName:$replyContent';
    }
    return kg.request('/index.php',
        method: 'POST',
        clearDefaultParams: true,
        notSignature: true,
        headers: {'x-router': 'm.comment.service.kugou.com'},
        params: {
          'r': 'commentsv2/reply',
          'code': _commentCodeOf('${q['resource_type'] ?? 'song'}'),
          'childrenid': '${q['special_id'] ?? q['childrenid'] ?? q['id'] ?? ''}',
          if (_childName(q) != null) 'childrenname': _childName(q),
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
          // F4-05：extdata（Node 透传 params.extdata）+ is_t + pid 默认 0。
          if (_nonEmpty(q['extdata'])) 'extdata': '${q['extdata']}',
          'content': content,
          'tid': '${q['tid'] ?? ''}',
          'is_t': isTopLevel,
          'pid': pid,
          if (_nonEmpty(q['source'])) 'source': q['source'],
        });
  }

  /// 删除评论（module/_comment.js buildCommentDelConfig，需登录）
  /// GET /index.php?r=commentsv2/delcomment（Node 未传 method → 默认 GET、无 body）
  Future<KgResponse> commentDel(Map<String, dynamic> q) {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // F4-06（审查①-B，P1）：method 由 POST 改 **GET**（Node commentRequestConfig
    // 默认 method='GET'，buildCommentDelConfig 未覆写；注释亦写明「GET 无 body」）。
    // 另外 F4-18（P2）：cid 兼容 comment_id 别名，空值不下发（Node 走 compact()）。
    final cid = q['cid'] ?? q['comment_id'];
    return kg.request('/index.php',
        method: 'GET',
        clearDefaultParams: true,
        notSignature: true,
        headers: {'x-router': 'm.comment.service.kugou.com'},
        params: {
          'r': 'commentsv2/delcomment',
          'code': _commentCodeOf('${q['resource_type'] ?? 'song'}'),
          'childrenid': '${q['special_id'] ?? q['childrenid'] ?? q['id'] ?? ''}',
          if (_nonEmpty(cid)) 'cid': '$cid',
          if (_nonEmpty(q['tid'])) 'tid': '${q['tid']}',
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

  /// 与 Node `_comment.js` 的 `firstValue` 同语义：null/undefined/空串都算缺失。
  static bool _nonEmpty(Object? v) {
    if (v == null) return false;
    final s = '$v'.trim();
    return s.isNotEmpty && s != 'null' && s != 'undefined';
  }

  /// childrenname 的别名收敛（Node firstValue(name, song_name, album_name,
  /// playlist_name, childrenname)）——调用方只传 song_name 时也能下发。
  static String? _childName(Map<String, dynamic> q) {
    for (final key in const [
      'name',
      'song_name',
      'album_name',
      'playlist_name',
      'childrenname',
    ]) {
      if (_nonEmpty(q[key])) return '${q[key]}';
    }
    return null;
  }

  Future<KgResponse> commentPlaylist(Map<String, dynamic> q) {
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
  Future<KgResponse> commentAlbum(Map<String, dynamic> q) {
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

  Future<KgResponse> commentFloor(Map<String, dynamic> q) {
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
