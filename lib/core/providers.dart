import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/lyric/data/lyric_repository.dart';
import 'api/kugou_api_client.dart';
import 'api/translate_api.dart';
import 'direct/kg_direct_api_client.dart';
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

/// 全局 ProviderScope 容器（在非 Widget 环境读取 provider 时使用）
final globalContainer = ProviderContainer();

/// 便捷访问全局 API 客户端
KugouApiClient get kugouApi => globalContainer.read(kugouApiClientProvider);
