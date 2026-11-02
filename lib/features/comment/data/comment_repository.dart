import '../../../core/api/kugou_api_client.dart';

enum CommentResourceType { song, playlist, album }

class CommentRepository {
  CommentRepository(this._api);
  final KugouApiClient _api;

  /// 当前登录用户 userid（来自 API 客户端 cookie 上下文），用于 isMine 判定
  String get _currentUserId => _api.userid;

  /// 评论列表
  Future<CommentPage> fetchComments({
    required CommentResourceType type,
    required String id, // mixsongid / global_collection_id / album_id
    int page = 1,
    int pageSize = 30,
  }) async {
    final path = switch (type) {
      CommentResourceType.song => '/comment/music',
      CommentResourceType.playlist => '/comment/playlist',
      CommentResourceType.album => '/comment/album',
    };
    final query = switch (type) {
      CommentResourceType.song => {
          'mixsongid': id, 'page': page, 'pagesize': pageSize,
          'show_classify': 1, 'show_hotword_list': 1,
        },
      _ => {'id': id, 'page': page, 'pagesize': pageSize},
    };
    final data = await _api.get(path, query: query);
    return CommentPage.fromJson(data, currentUserId: _currentUserId);
  }

  /// 按歌曲 hash 查询评论数。
  Future<int> fetchCount(String hash) async {
    final data = await _api.get('/comment/count', query: {'hash': hash});
    final value = data[hash] ?? data[hash.toUpperCase()] ?? data[hash.toLowerCase()];
    return value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  }

  /// 楼中楼
  Future<CommentPage> fetchFloor({
    required String specialId, // special_child_id
    required String tid, // 顶层评论 id
    CommentResourceType type = CommentResourceType.song,
    String? mixsongid,
    int page = 1,
  }) async {
    final data = await _api.get('/comment/floor', query: {
      'special_id': specialId,
      'tid': tid,
      // ⚠️ 必须传 resource_type：直连层据此选择「端点 + comment code」，
      // 缺失时歌单/专辑会走歌曲分支 → err_code=60102 → 恒空且不回退。
      'resource_type': type.name,
      if (mixsongid != null) 'mixsongid': mixsongid,
      'page': page,
    });
    return CommentPage.fromJson(data, currentUserId: _currentUserId);
  }

  /// 发评论
  Future<void> sendComment({
    required CommentResourceType type,
    required String id,
    required String content,
    String? name,
  }) async {
    final path = switch (type) {
      CommentResourceType.song => '/comment/music/send',
      CommentResourceType.playlist => '/comment/playlist/send',
      CommentResourceType.album => '/comment/album/send',
    };
    final query = switch (type) {
      CommentResourceType.song => {
          'mixsongid': id,
          'content': content,
          'resource_type': 'song',
          if (name != null) 'name': name,
        },
      _ => {
          'id': id,
          'content': content,
          // 直连层按 resource_type 选 code（歌曲/歌单/专辑各不相同）
          'resource_type': type.name,
          if (name != null) 'name': name,
        },
    };
    await _api.post(path, {}, query: query);
  }

  /// 回复（楼中楼）
  Future<void> sendFloorReply({
    required String specialId,
    required String tid,
    required String content,
    String? pid,
    CommentResourceType resourceType = CommentResourceType.song,
    String? name,
  }) async {
    await _api.post('/comment/floor/send', {}, query: {
      'special_id': specialId,
      'tid': tid,
      'content': content,
      if (pid != null) 'pid': pid,
      'resource_type': resourceType.name,
      if (name != null) 'name': name,
    });
  }

  /// 删除评论
  Future<void> deleteComment({
    required String cid,
    String? mixsongid,
    String? specialId,
    String? tid,
    CommentResourceType resourceType = CommentResourceType.song,
  }) async {
    await _api.post('/comment/music/del', {}, query: {
      'cid': cid,
      // 直连层按 resource_type 选评论 code（歌曲/歌单/专辑各不相同）
      'resource_type': resourceType.name,
      if (mixsongid != null) 'mixsongid': mixsongid,
      if (specialId != null) 'special_id': specialId,
      if (tid != null) 'tid': tid,
    });
  }
}

class CommentPage {
  CommentPage({required this.comments, required this.total, this.classifies, this.hotWords});
  final List<Comment> comments;
  final int total;
  final List<CommentClassify>? classifies;
  final List<String>? hotWords;

  factory CommentPage.fromJson(Map<String, dynamic> json,
      {String? currentUserId}) {
    // 实测：顶层就有 `list`（无 data 层）；楼中楼总数是 `comments_num`。
    final data = json['data'] is Map
        ? Map<String, dynamic>.from(json['data'] as Map)
        : json;
    final raw = data['list'];
    final list = raw is List ? raw : const [];
    final comments = list
        .whereType<Map>()
        .map((e) => Comment.fromJson(Map<String, dynamic>.from(e),
            currentUserId: currentUserId))
        .toList();
    final total = _asInt(data['count'] ??
        data['total'] ??
        data['comments_num'] ??
        data['str_count'],
        fallback: comments.length);

    // 实测分类标签字段名是 `classify_list`，项为 {id, label, icon, cnt}。
    List<CommentClassify>? classifies;
    final classifyRaw = data['classify_list'] ?? data['classify'];
    if (classifyRaw is List) {
      classifies = classifyRaw
          .whereType<Map>()
          .map((e) => CommentClassify.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    // 实测热词项为 {content, count}（不是 hot_word）。
    List<String>? hotWords;
    final hotRaw = data['hot_word_list'] ?? data['hotword_list'];
    if (hotRaw is List) {
      hotWords = hotRaw
          .map((e) => e is Map
              ? '${e['content'] ?? e['hot_word'] ?? e['word'] ?? ''}'
              : '$e')
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return CommentPage(
        comments: comments, total: total, classifies: classifies, hotWords: hotWords);
  }
}

int _asInt(dynamic value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? fallback;
}

class Comment {
  Comment({
    required this.id,
    required this.userName,
    required this.avatar,
    required this.content,
    required this.likeCount,
    required this.createTime,
    required this.replyCount,
    this.specialChildId,
    this.isMine = false,
  });
  final String id;
  final String userName;
  final String avatar;
  final String content;
  final int likeCount;
  final String createTime;
  final int replyCount;
  final String? specialChildId;
  final bool isMine;

  factory Comment.fromJson(Map<String, dynamic> json, {String? currentUserId}) {
    var avatar = '${json['user_pic'] ?? json['avatar'] ?? json['pic'] ?? ''}';
    avatar = avatar.replaceAll('{size}', '120');
    // 实测 `like` 是**对象** {count, likenum, haslike, opposenum}；
    // 旧实现当数字解析，导致点赞恒为 0。
    final like = json['like'];
    return Comment(
      id: '${json['id'] ?? json['cid'] ?? ''}',
      userName: '${json['user_name'] ?? json['nickname'] ?? ''}',
      avatar: avatar,
      content: '${json['content'] ?? ''}',
      likeCount: _asInt(like is Map
          ? (like['count'] ?? like['likenum'])
          : (like ?? json['likecount'])),
      createTime: '${json['addtime'] ?? json['create_time'] ?? ''}',
      // 实测顶层评论回复数是 `reply_num`；楼中楼项没有该字段。
      replyCount: _asInt(json['reply_num'] ?? json['replycount']),
      specialChildId: json['special_child_id'] != null
          ? '${json['special_child_id']}'
          : null,
      // 是否本人评论：userid 与当前登录用户一致
      // （优先用调用方传入的 currentUserId，缺省用 API 客户端的 cookie userid）
      isMine: (currentUserId ?? '').isNotEmpty &&
          '${json['userid'] ?? json['user_id'] ?? ''}' == (currentUserId ?? ''),
    );
  }
}

class CommentClassify {
  CommentClassify({required this.id, required this.name, required this.count});
  final String id;
  final String name;
  final int count;

  /// 实测分类项为 `{id, label, icon, cnt}`（标签名是 `label`，数量是 `cnt`）。
  factory CommentClassify.fromJson(Map<String, dynamic> json) => CommentClassify(
        id: '${json['id'] ?? json['type_id'] ?? ''}',
        name: '${json['label'] ?? json['name'] ?? ''}',
        count: _asInt(json['cnt'] ?? json['count']),
      );
}
