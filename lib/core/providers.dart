import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/lyric/data/lyric_repository.dart';
import 'api/kugou_api_client.dart';
import 'api/translate_api.dart';
import 'direct/kg_providers.dart';

/// 全局 API 客户端：默认直连酷狗网关，未移植路径自动回退 kapi。
final kugouApiClientProvider = Provider<KugouApiClient>((ref) {
  return ref.watch(kgDirectApiProvider);
});

/// 翻译 API 单例
final translateApiProvider = Provider<TranslateApi>((ref) => TranslateApi());

/// 歌词仓库
final lyricRepositoryProvider = Provider<LyricRepository>((ref) =>
    LyricRepository(
        ref.watch(kugouApiClientProvider), ref.watch(translateApiProvider)));

// 注意：不要在这里创建第二个顶层 ProviderContainer（旧的 globalContainer）。
// 它没有 ProviderScope 的 override（尤其 kgDeviceProvider），一旦被读取会抛
// UnimplementedError。需要访问客户端时一律通过 Provider 的 ref 获取，
// 例如 ref.watch(kugouApiClientProvider)。
