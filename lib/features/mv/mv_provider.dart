import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'data/mv_repository.dart';

/// MV 仓库（全局共享，播放页与全屏播放器共用）。
final mvRepoProvider =
    Provider<MvRepository>((ref) => MvRepository(ref.watch(kugouApiClientProvider)));

/// 当前歌曲是否有 MV（按 album_audio_id 查询）。
final mvExistsProvider = FutureProvider.family.autoDispose<bool, String>(
    (ref, albumAudioId) async {
  if (albumAudioId.isEmpty) return false;
  final list = await ref.watch(mvRepoProvider).findBySong(albumAudioId);
  return list.isNotEmpty;
});

/// 当前歌曲关联的 MV 信息（取第一个，供全屏播放器跳转）。
final songMvProvider =
    FutureProvider.family.autoDispose<MvInfo?, String>((ref, albumAudioId) async {
  if (albumAudioId.isEmpty) return null;
  final list = await ref.watch(mvRepoProvider).findBySong(albumAudioId);
  return list.isEmpty ? null : list.first;
});

/// MV 视频详情（清晰度列表），失败返回 null（隐藏清晰度按钮）。
final mvDetailProvider =
    FutureProvider.family.autoDispose<MvDetail?, String>((ref, hash) async {
  try {
    return await ref.watch(mvRepoProvider).fetchDetail(hash);
  } catch (_) {
    return null;
  }
});
