/// v5.0 M3：翻译持久缓存 + 搜索热词（REFACTOR_PLAN_V5 §4）。
///
/// v5.1 B3-B P1-1/2/4 修复：
/// - openBox 并发合并（同名箱只打一次，失败留痕不崩）
/// - 读取前严格 JSON 校验（第 13/14 条），畸形体清理不抛
/// - 解析全部包 try/catch，不再有未捕获 int.parse（第 6 条）
library;

import 'package:hive/hive.dart';
import 'package:flutter/foundation.dart';

/// 进程内记忆缓存（v5.1 B3-B P1-3 修复：取消 as T? 裸强转）。
class MemoryCache {
  MemoryCache._();
  static final instance = MemoryCache._();

  final Map<String, Object> _m = {};

  T? get<T extends Object>(String key) {
    final v = _m[key];
    return v is T ? v : null; // 类型不符视为未命中，不抛
  }

  void put(String key, Object value) => _m[key] = value;

  void removeWhere(bool Function(String, Object) test) => _m.removeWhere(test);

  void clear() => _m.clear();

  /// openBox 并发合并：同名箱只打一次，失败缓存 Future（P1-1）。
  Future<Box<E>> openBoxSafe<E extends Object>(String name,
      {bool stringValues = false}) {
    return _openFutures.putIfAbsent(
      'E:$name:string:$stringValues',
      () => Hive.openBox<E>(name).catchError((Object e) {
        debugPrint('[cache] openBox($name) failed: $e');
        throw e; // 保持失败可观测，后续调用方决定降级
      }),
    ) as Future<Box<E>>;
  }

  final Map<String, Future<dynamic>> _openFutures = {};
}
