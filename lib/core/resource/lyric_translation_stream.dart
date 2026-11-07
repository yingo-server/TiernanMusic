import 'dart:async';

/// 翻译增量补丁（v4.0 冻结契约）。
class LyricTranslationPatch {
  const LyricTranslationPatch(this.lyricId, this.startIndex, this.values);
  final String lyricId;
  final int startIndex;
  final List<String> values;
}

/// 翻译增量广播（v4.0-B，V400-B-03）。
///
/// 每批译文完成即 [emit]，UI 订阅 [patches] 实时插行，不等整批翻译完
///（TASK_v400_b.md B3）。broadcast 流：无监听时 emit 不丢错、不阻塞；
/// 缓存命中时也 emit 一次（UI 秒显），遵循「单一事实源+事件通知」分层。
class LyricTranslationStream {
  LyricTranslationStream._();
  static final instance = LyricTranslationStream._();

  final _controller =
      StreamController<LyricTranslationPatch>.broadcast();

  /// 增量补丁流（broadcast，多页订阅互不影响）。
  Stream<LyricTranslationPatch> get patches => _controller.stream;

  /// 广播一批译文：[startIndex] 起，逐行对应 [values]。
  /// broadcast 流在无监听时静默丢弃——UI 尚未订阅（切歌瞬间）时
  /// 丢一批可接受，持久缓存兜底下次秒显，故无需缓冲区（第 25 条上限）。
  void emit(LyricTranslationPatch p) {
    if (_controller.isClosed) return;
    _controller.add(p);
  }

  /// 对称释放（第 20 条）。当前为进程级单例，仅测试/热重载场景调用。
  Future<void> dispose() => _controller.close();
}
