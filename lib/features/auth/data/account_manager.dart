import 'package:hive_flutter/hive_flutter.dart';

/// 账号记录（存 Hive box 'accounts'）
class AccountRecord {
  AccountRecord({
    required this.userid,
    required this.token,
    this.nickname = '',
    this.avatar = '',
    this.t1,
  });

  final String userid;
  final String token;
  String nickname;
  String avatar;
  String? t1;

  Map<String, dynamic> toJson() => {
        'userid': userid,
        'token': token,
        'nickname': nickname,
        'avatar': avatar,
        't1': t1,
      };

  factory AccountRecord.fromJson(Map<dynamic, dynamic> json) => AccountRecord(
        userid: '${json['userid'] ?? ''}',
        token: '${json['token'] ?? ''}',
        nickname: '${json['nickname'] ?? ''}',
        avatar: '${json['avatar'] ?? ''}',
        t1: json['t1'] as String?,
      );
}

/// 多账号管理器
class AccountManager {
  AccountManager._();
  static final AccountManager instance = AccountManager._();

  static const _boxName = 'accounts';
  static const _kList = 'list';
  static const _kCurrent = 'current';

  Box<dynamic>? _box;

  Future<void> init() async {
    if (!Hive.isBoxOpen(_boxName)) {
      _box = await Hive.openBox(_boxName);
    } else {
      _box = Hive.box(_boxName);
    }
  }

  Box<dynamic> get _b {
    final b = _box;
    if (b == null || !b.isOpen) {
      throw StateError('AccountManager 未初始化，请先调用 init()');
    }
    return b;
  }

  /// 全部账号
  List<AccountRecord> get accounts {
    final raw = _b.get(_kList, defaultValue: <dynamic>[]) as List<dynamic>;
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(AccountRecord.fromJson)
        .toList();
  }

  /// 当前账号 userid
  String? get currentUserid => _b.get(_kCurrent) as String?;

  AccountRecord? get currentAccount {
    final id = currentUserid;
    if (id == null) return null;
    for (final a in accounts) {
      if (a.userid == id) return a;
    }
    return null;
  }

  Future<void> _saveList(List<AccountRecord> list) =>
      _b.put(_kList, list.map((e) => e.toJson()).toList());

  /// 新增或更新账号，并设为当前账号
  Future<void> upsert(AccountRecord record) async {
    final list = accounts;
    final idx = list.indexWhere((e) => e.userid == record.userid);
    if (idx >= 0) {
      list[idx] = record;
    } else {
      list.add(record);
    }
    await _saveList(list);
    await _b.put(_kCurrent, record.userid);
  }

  /// 切换当前账号（返回账号记录，不存在返回 null）
  Future<AccountRecord?> switchTo(String userid) async {
    for (final a in accounts) {
      if (a.userid == userid) {
        await _b.put(_kCurrent, userid);
        return a;
      }
    }
    return null;
  }

  /// 移除账号；若移除的是当前账号，自动切到剩余的第一个
  Future<AccountRecord?> remove(String userid) async {
    final list = accounts..removeWhere((e) => e.userid == userid);
    await _saveList(list);
    if (currentUserid == userid) {
      if (list.isNotEmpty) {
        await _b.put(_kCurrent, list.first.userid);
        return list.first;
      } else {
        await _b.delete(_kCurrent);
        return null;
      }
    }
    return currentAccount;
  }

  Future<void> clear() async {
    await _b.delete(_kList);
    await _b.delete(_kCurrent);
  }
}
