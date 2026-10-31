import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';

import '../config/app_config.dart';

class ApiException implements Exception {
  ApiException(this.errorCode, this.message);
  final int errorCode;
  final String message;
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
          final status = data['status'];
          final errorCode = data['error_code'] ?? data['errcode'] ?? 0;
          if (status == 0 && errorCode != 0) {
            handler.reject(DioException(
              requestOptions: response.requestOptions,
              error: ApiException(
                errorCode is int ? errorCode : int.tryParse('$errorCode') ?? -1,
                '${data['error_msg'] ?? data['errmsg'] ?? data['info'] ?? '未知错误'}',
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
  }

  Future<void> clearCredentials() async {
    await _cookieJar.deleteAll();
  }
}
