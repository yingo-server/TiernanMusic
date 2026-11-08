
import 'package:dio/dio.dart';
import '../foundation/errors.dart';
import '../domain/response_policy.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';



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
        // v5.1 B1 三视角共识：成功/失败/风控判定**唯一**走 evaluateResponse。
        // 旧拦截器曾完整复制一套 _wrap，与 ResponsePolicy 可得出相反结论。
        final data = response.data;
        if (data is Map<String, dynamic>) {
          final ssaHeader = response.headers.value('ssa-code') ??
              response.headers.value('ssa_code');
          final outcome = evaluateResponse(data, ssaCode: ssaHeader);
          if (!outcome.isOk) {
            handler.reject(DioException(
              requestOptions: response.requestOptions,
              response: response,
              error: outcome.failure,
            ));
            return;
          }
        } else if (data == null) {
          // 空响应体不得静默转 {} 当成功（第 14/16 条）
          handler.reject(DioException(
            requestOptions: response.requestOptions,
            response: response,
            error: ApiException(-1, '空响应体', body: const {}),
          ));
          return;
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
      } catch (e) {
        // 目录异常时退化为内存，不能让登录因存储问题而失败
        // B-07（第6批①，P1）：静默降级必须留痕（第 9 条）
        debugPrint('[cookie] PersistCookieJar creation failed (path=$path): $e'
            ' — falling back to in-memory jar');
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
  ///
  /// B-07（第6批①，P1）：持久化与否取决于「谁先构造客户端」的时序——
  /// main() 在 runApp 前设置 [cookieStoragePath]，但若任何 Provider 在
  /// 该设置之前构造了客户端（冷启动/低端机），整个进程会静默使用内存
  /// jar → 用户下次冷启动被登出。两道防线：
  /// 1. 路径未设置时**不缓存** jar（每次重查，路径就绪后自然切到持久化）；
  /// 2. 降级到内存 jar 时必须留日志（第 9 条），否则线上无线索。
  static CookieJar get sharedCookieJar {
    if (_sharedJar != null) return _sharedJar!;
    final path = cookieStoragePath;
    if (path == null || path.isEmpty) {
      // 路径未就绪：返回内存 jar 但不缓存，等路径就绪后重建
      debugPrint('[cookie] storage path not ready, using in-memory jar '
          '(will switch to persistent once path is set)');
      return CookieJar();
    }
    final jar = _createCookieJar(path);
    if (jar is! PersistCookieJar) {
      // v5.1 B1 三视角共识：降级到内存 jar **绝不缓存**——
      // 否则持久化目录后续恢复可用时整个进程仍停留在内存 jar，
      // 冷启动登录态永久丢失（第 5/11 条：降级必须有恢复条件）。
      debugPrint('[cookie] WARNING: falling back to in-memory jar '
          '(path=$path) — will retry persistent jar on next client');
      return CookieJar();
    }
    return _sharedJar = jar;
  }

  /// 全局 cookie 存储路径（main() 启动时用 getApplicationDocumentsDirectory 设置一次）
  static String? cookieStoragePath;

  static bool _needsTimestamp(String path) {
    // C-07（审查②）：kapi 对全部 200 响应按 URL 做 2 分钟全局缓存。
    // 登录/设备/验证类接口若命中缓存：二维码串号、dfid 复用、短信不下发。
    const list = [
      '/login/', '/register/dev', '/get/verify/info', '/verify/user/info',
      '/sidedt', '/captcha/sent',
      '/playlist/add', '/playlist/del',
      '/playlist/tracks/add', '/playlist/tracks/del',
      '/comment/', '/import/',
    ];
    return list.any(path.startsWith);
  }

  Dio get dio => _dio;
  CookieJar get cookieJar => _cookieJar;

  /// 登录用户 id（直连签名/权益查询用；匿名为 '0'）
  String userid = '';
  String dfid = '';
  String webglHash = '11664606328242161144';

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
      // C-03（审查②）：null 时显式写空 cookie 清除旧值（切号防串号）
      Cookie('t1', t1 ?? ''),
      Cookie('auth', auth ?? ''),
      Cookie('dfid', dfid ?? ''),
    ];
    await _cookieJar.saveFromResponse(uri, cookies);
    this.userid = userid;
    if (dfid != null) this.dfid = dfid;
  }

  Future<void> clearCredentials() async {
    // 用实例自己的 jar：若调用方传了 cookieStoragePath，清 sharedCookieJar 会清错
    await _cookieJar.deleteAll();
    userid = '';
    dfid = '';
  }
}
