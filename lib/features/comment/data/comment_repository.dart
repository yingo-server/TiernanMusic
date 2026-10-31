import '../../../core/api/kugou_api_client.dart';

enum CommentResourceType { song, playlist, album }

class CommentRepository {
  CommentRepository(this._api);
  final KugouApiClient _api;

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
    return CommentPage.fromJson(data);
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
    String? mixsongid,
    int page = 1,
  }) async {
    final data = await _api.get('/comment/floor', query: {
      'special_id': specialId,
      'tid': tid,
      if (mixsongid != null) 'mixsongid': mixsongid,
      'page': page,
    });
    return CommentPage.fromJson(data);
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
          'mixsongid': id, 'content': content, if (name != null) 'name': name,
        },
      _ => {'id': id, 'content': content, if (name != null) 'name': name},
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
  }) async {
    await _api.post('/comment/music/del', {}, query: {
      'cid': cid,
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

  factory CommentPage.fromJson(Map<String, dynamic> json) {
    // 实测：顶层就有 `list`（无 data 层）；楼中楼总数是 `comments_num`。
    final data = json['data'] is Map
        ? Map<String, dynamic>.from(json['data'] as Map)
        : json;
    final raw = data['list'];
    final list = raw is List ? raw : const [];
    final comments = list
        .whereType<Map>()
        .map((e) => Comment.fromJson(Map<String, dynamic>.from(e)))
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

  factory Comment.fromJson(Map<String, dynamic> json) {
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
