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
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final list = data['list'] as List? ?? data['info'] as List? ?? [];
    final comments = list
        .map((e) => Comment.fromJson(e as Map<String, dynamic>))
        .toList();
    final total = _asInt(data['count'] ?? data['total'] ?? data['comments_num'],
        fallback: comments.length);

    List<CommentClassify>? classifies;
    if (data['classify'] is List) {
      classifies = (data['classify'] as List)
          .map((e) => CommentClassify.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    List<String>? hotWords;
    if (data['hotword_list'] is List) {
      hotWords = (data['hotword_list'] as List)
          .map((e) => '${e is Map ? e['hot_word'] ?? e : e}')
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
    final like = json['like'];
    return Comment(
      id: '${json['id'] ?? json['cid'] ?? ''}',
      userName: '${json['user_name'] ?? json['nickname'] ?? ''}',
      avatar: avatar,
      content: '${json['content'] ?? ''}',
      likeCount: _asInt(like is Map
          ? like['count'] ?? like['likenum']
          : like ?? json['likecount']),
      createTime: '${json['addtime'] ?? json['create_time'] ?? ''}',
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

  factory CommentClassify.fromJson(Map<String, dynamic> json) => CommentClassify(
        id: '${json['type_id'] ?? json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        count: (json['count'] ?? 0) is int
            ? (json['count'] ?? 0)
            : int.tryParse('${json['count']}') ?? 0,
      );
}
