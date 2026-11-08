import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/lyric/data/lyric_repository.dart';
import '../core/api/translate_api.dart';
import '../core/direct/kg_providers.dart';
import '../core/net/music_api.dart';
import '../core/cache/resource_gateway.dart';
import '../core/domain/quality.dart' show QualityDiagnostics;

/// 全局 API 客户端：默认直连酷狗网关，未移植路径自动回退 kapi。
final kugouApiClientProvider = Provider<KugouApiClient>((ref) {
  return ref.watch(kgDirectApiProvider);
});

/// 翻译 API 单例
final translateApiProvider = Provider<TranslateApi>((ref) => TranslateApi());

/// 歌词仓库（v5.3 B-15：读路径统一走 MusicApi.transport，与 M5 一致）
final lyricRepositoryProvider = Provider<LyricRepository>((ref) =>
    LyricRepository(
        ref.watch(musicApiProvider), ref.watch(translateApiProvider)));

// 注意：不要在这里创建第二个顶层 ProviderContainer（旧的 globalContainer）。
// 它没有 ProviderScope 的 override（尤其 kgDeviceProvider），一旦被读取会抛
// UnimplementedError。需要访问客户端时一律通过 Provider 的 ref 获取，
// 例如 ref.watch(kugouApiClientProvider)。


/// v5.0 M4：Bridge-N 门面（惰性创建；注册缓存失效器，避免 core/net 反向依赖）。
final musicApiProvider = Provider<MusicApi>((ref) {
  final api = MusicApi.of(ref.watch(kugouApiClientProvider));
  MusicApi.attachInvalidator(ResourceGateway.instance.invalidateNs);
  QualityDiagnostics.onUnknownValue ??= (raw) {
    // 第 9 条：降级必须可观测；不引 Flutter，由 app 层注入 debugPrint。
    // ignore: avoid_print
    print('[quality] unknown value fallback to q128: $raw');
  };
  return api;
});
