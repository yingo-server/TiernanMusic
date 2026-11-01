import '../../core/api/kugou_api_client.dart';

/// 统一把异常转为用户可读的中文文案（W2）。
///
/// `ApiException.toString()` 形如 `ApiException(20028): xxx`，
/// StateError 也是英文原始文本 —— UI 层不得直接 `'$e'` 上屏。
String friendlyError(Object e) {
  if (e is ApiException) {
    if (e.needsVerification) return '需要完成人机验证后重试';
    return switch (e.errorCode) {
      1011 || 20010 || 30791 || 401 => '登录已过期，请重新登录',
      _ => e.message,
    };
  }
  if (e is StateError) return e.message;
  return '操作失败，请稍后重试';
}
