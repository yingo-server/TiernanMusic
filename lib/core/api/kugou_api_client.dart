
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';

import '../config/app_config.dart';

class ApiException implements Exception {
  ApiException(
    this.errorCode,
    this.message, {
    this.ssaCode,
    this.verifyUrl,
    this.body,
  });

  final int errorCode;
  final String message;

  /// 20028 时携带的验证事件 id（body.ssaCode 或响应头 ssa-code）
  final String? ssaCode;

  /// /get/verify/info 返回的 url，前缀决定验证码类型（KGCodeTX| / KGCodeGT| …）
  final String? verifyUrl;

  /// 原始错误响应体，便于上层判断 fail_process 等
  final Map<String, dynamic>? body;

  bool get needsVerification => errorCode == 20028;

  @override
  String toString() => 'ApiException($errorCode): $message';
}

class KugouApiClient {
  KugouApiClient({String? baseUrl})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl ?? AppConfig.kugouApiBase,
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'User-Agent': 'TiernanMusic/0.1.0 Android'},
        )) {
    _dio.interceptors.add(CookieManager(_cookieJar));
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        // 写操作和轮询接口附加时间戳防缓存
        if (_needsTimestamp(options.path)) {
          options.queryParameters['timestamp'] =
              DateTime.now().millisecondsSinceEpoch.toString();
        }
        handler.next(options);
      },
      onResponse: (response, handler) {
        final data = response.data;
        if (data is Map<String, dynamic>) {
          final status = int.tryParse('${data['status'] ?? 1}') ?? 1;
          final rawCode = data['error_code'] ?? data['errcode'] ?? 0;
          final errorCode = rawCode is int
              ? rawCode
              : int.tryParse('$rawCode') ?? -1;
          final hasErrorCode = data.containsKey('error_code') ||
              data.containsKey('errcode');
          // 部分接口使用 status=2，另有失败响应只给非零 errcode。
          // 无论哪种形式都必须向上抛错，不能被仓库当成空列表。
          if (status == 0 || status == 2 || (hasErrorCode && errorCode != 0)) {
            final defaultMessage = errorCode == 20028
                ? '需要完成人机验证'
                : status == 0 && errorCode == 0
                    ? '请求失败'
                    : '未知错误';
            // ssaCode 优先取 body，其次取响应头 ssa-code（酷狗两种都可能给）
            final ssaCode = (data['ssaCode'] ?? data['ssa_code'])
                    ?.toString()
                    .trim() ??
                response.headers.value('ssa-code') ??
                response.headers.value('ssa_code');
            handler.reject(DioException(
              requestOptions: response.requestOptions,
              response: response,
              error: ApiException(
                errorCode,
                '${data['error_msg'] ?? data['errmsg'] ?? data['error'] ?? data['info'] ?? defaultMessage}',
                ssaCode: (ssaCode != null && ssaCode.isNotEmpty) ? ssaCode : null,
                body: data,
              ),
            ));
            return;
          }
        }
        handler.next(response);
      },
    ));
  }

  final Dio _dio;
  final PersistCookieJar _cookieJar = PersistCookieJar();

  static bool _needsTimestamp(String path) {
    const list = [
      '/login/qr/check', '/login/wx/check', '/login/qq/qr/check',
      '/login/token', '/playlist/add', '/playlist/del',
      '/playlist/tracks/add', '/playlist/tracks/del',
      '/comment/', '/import/',
    ];
    return list.any(path.startsWith);
  }

  Dio get dio => _dio;
  PersistCookieJar get cookieJar => _cookieJar;

  /// 设备 mid（登录/注册后由服务端 cookie 注入，用于行为指纹）
  String mid = '';
  String userid = '';
  String dfid = '';
  String webglHash = '11664606328242161144';

  /// 从 cookie 中刷新 mid / userid，供 sid/edt 生成使用
  Future<void> refreshDeviceContext() async {
    try {
      final uri = Uri.parse(AppConfig.kugouApiBase);
      final cookies = await _cookieJar.loadForRequest(uri);
      for (final c in cookies) {
        switch (c.name) {
          case 'KUGOU_API_MID':
            if (c.value.isNotEmpty) mid = c.value;
            break;
          case 'userid':
            if (c.value.isNotEmpty) userid = c.value;
            break;
        }
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>> get(String path,
      {Map<String, dynamic>? query}) async {
    final res = await _dio.get<Map<String, dynamic>>(path,
        queryParameters: query);
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> post(String path, dynamic data,
      {Map<String, dynamic>? query}) async {
    final res = await _dio.post<Map<String, dynamic>>(path,
        data: data, queryParameters: query);
    return res.data ?? {};
  }

  /// 设置登录凭证 cookie
  Future<void> setCredentials({
    required String token,
    required String userid,
    String? t1,
    String? auth,
    String? dfid,
  }) async {
    final uri = Uri.parse(AppConfig.kugouApiBase);
    final cookies = [
      Cookie('token', token),
      Cookie('userid', userid),
      if (t1 != null) Cookie('t1', t1),
      if (auth != null) Cookie('auth', auth),
      if (dfid != null) Cookie('dfid', dfid),
    ];
    await _cookieJar.saveFromResponse(uri, cookies);
    this.userid = userid;
    if (dfid != null) this.dfid = dfid;
  }

  Future<void> clearCredentials() async {
    await _cookieJar.deleteAll();
  }
}
