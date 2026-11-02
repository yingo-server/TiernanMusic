
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
  /// [cookieStoragePath] 必须是**可写**的 App 私有目录（如 documents/cookies）。
  /// 不传时使用全局静态 [cookieStoragePath]；两者都没有则退化为内存 CookieJar
  /// —— cookie 不持久化，但绝不会写只读路径（登录曾因此报
  /// 「Read-only file system」）。
  KugouApiClient({String? baseUrl, String? cookieStoragePath})
      : _cookieJar = cookieStoragePath == null
            ? sharedCookieJar
            : _createCookieJar(cookieStoragePath),
        _dio = Dio(BaseOptions(
          baseUrl: baseUrl ?? AppConfig.kugouApiBase,
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'User-Agent': 'TiernanMusic/1.0.0 Android'},
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

          // 酷狗各接口的成功语义不统一，实测口径：
          //   /search、/comment 等：status=1
          //   /search/lyric：status=200 + errcode=200（**成功**，不是错误）
          //   /comment/music 等：status=1 + errcode=151/152（**警告但有数据**）
          // 若把 1xx/2xx 一律当失败，歌词接口会永远抛 ApiException(200)，
          // 表现为播放页无歌词并刷屏报错。
          final okStatus = status == 1 || status == 200;
          final failedStatus = status == 0 || status == 2;
          // 警告码：0 表示无错；151/152/200/201 是上游"有结果但需提示"的码
          const warningCodes = {0, 151, 152, 200, 201};
          final isWarning = warningCodes.contains(errorCode) ||
              (errorCode > 0 && errorCode < 300);

          if (failedStatus ||
              (hasErrorCode && errorCode != 0 && !(okStatus && isWarning))) {
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

  /// cookie 存储：
  /// - 有可写路径 → PersistCookieJar + FileStorage（应用私有目录，三层存储规范第 2 层）
  /// - 无路径 → 内存 CookieJar（不持久化，但绝不写只读路径）
  final CookieJar _cookieJar;

  static CookieJar _createCookieJar(String? explicitPath) {
    final path = explicitPath ?? KugouApiClient.cookieStoragePath;
    if (path != null && path.isNotEmpty) {
      try {
        return PersistCookieJar(storage: FileStorage(path));
      } catch (_) {
        // 目录异常时退化为内存，不能让登录因存储问题而失败
      }
    }
    return CookieJar();
  }

  /// 进程级共享的 CookieJar。
  ///
  /// 登录态必须在**所有** KugouApiClient 实例之间共享：
  /// 各实例各建一个 PersistCookieJar 时，内存里的 hostCookies 互不可见，
  /// 而 FileStorage 又指向同一目录互相覆盖 —— 结果就是「登录写入的 token，
  /// 播放器/评论等其它 client 完全读不到」。
  static CookieJar? _sharedJar;

  /// 共享 cookie 存储（首次调用时按全局路径创建）。
  static CookieJar get sharedCookieJar => _sharedJar ??= _createCookieJar(null);

  /// 全局 cookie 存储路径（main() 启动时用 getApplicationDocumentsDirectory 设置一次）
  static String? cookieStoragePath;

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
  CookieJar get cookieJar => _cookieJar;

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
    // 用实例自己的 jar：若调用方传了 cookieStoragePath，清 sharedCookieJar 会清错
    await _cookieJar.deleteAll();
    mid = '';
    userid = '';
    dfid = '';
  }
}
