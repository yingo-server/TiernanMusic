import 'package:dio/dio.dart';
import '../foundation/errors.dart' show ApiException;


/// 从直连层包装的 DioException 中解出内层 ApiException（A2-07）。
///
/// 直连层统一把 ApiException 包成 DioException(error: e) 抛出，
/// UI 层的 `on ApiException` 永远不命中（登录页/评论页/播放监听）。
/// 此 helper 是表现层解包的**唯一入口**。
ApiException? unwrapApi(Object e) {
  if (e is ApiException) return e;
  if (e is DioException && e.error is ApiException) {
    return e.error as ApiException;
  }
  return null;
}

/// 统一把异常转为用户可读的中文文案（W2）。
///
/// `ApiException.toString()` 形如 `ApiException(20028): xxx`，
/// StateError 也是英文原始文本 —— UI 层不得直接 `'$e'` 上屏。
String friendlyError(Object e) {
  final api = unwrapApi(e);
  if (api != null) {
    if (api.needsVerification) return '需要完成人机验证后重试';
    return switch (api.errorCode) {
      1011 || 30791 || 401 => '登录已过期，请重新登录',
      _ => api.message,
    };
  }
  if (e is StateError) return e.message;
  return '操作失败，请稍后重试';
}
