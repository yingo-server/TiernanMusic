import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/data/models.dart';
import '../playlist/data/playlist_repository.dart';
import '../../core/domain/song.dart';
import 'player_provider.dart';

/// 统一把各模块数据转换为 Song 并调用播放。
///
/// 最近播放记录已由 [recentPlayRecorderProvider] 监听
/// audioHandler.onSongStarted 统一写入（F2：播放真正出声后才记录，
/// 自动切歌 / 上下一首同样覆盖），此处不再单独写。
class PlayHelper {
  PlayHelper(this._ref);
  final Ref _ref;

  PlayerController get _controller => _ref.read(playerControllerProvider);

  /// V39-AUX-02：HomeSong → Song 的唯一转换点（原 playHomeSong /
  /// playHomeQueue 各复制一份，第 1/5 条）。
  ///
  /// V39-AUX-01（P1）：hash 缺失不得用 id 冒充。`HomeSong.id` 在 hash
  /// 缺失时是 mixsongid/audio_id（home/data/models.dart:183），而
  /// Song.hash 是唯一可播放标识：`Song.==` 只比 hash（data/models.dart:218）、
  /// `/privilege/lite` 详情与 `/v5/url` 解析都按 hash 查询、MediaItem.id
  /// 与最近播放记录（recentPlayRecorderProvider 的 `hash.isEmpty` 守卫）
  /// 均以 hash 为准。混入 mixsongid 会污染相等语义并发出注定失败的
  /// 详情请求。缺失就传空串，让失败走正常的可观测错误链路（第 14 条）。
  Song _songFromHome(HomeSong s) => Song(
        hash: s.hash ?? '',
        albumId: s.albumId ?? '',
        albumAudioId: s.albumAudioId ?? '',
        name: s.name,
        artist: s.singer,
        cover: s.cover,
        // HomeSong.duration 契约为秒（home/data/models.dart `// 秒`，
        // fromJson 已按字段区分秒/毫秒字段），显式以秒构造（第 15 条）。
        duration: Duration(seconds: s.duration),
      );

  /// V39-AUX-02：PlaylistSong → Song 的唯一转换点。cover 参数仅当
  /// 歌单项无 cover 时兜底。
  Song _songFromPlaylist(PlaylistSong s, {String cover = ''}) => Song(
        hash: s.hash,
        albumId: s.albumId,
        albumAudioId: s.albumAudioId,
        name: s.name,
        artist: s.artist,
        cover: s.cover.isNotEmpty ? s.cover : cover,
        // PlaylistSong.duration 契约为秒（timelen 毫秒已在 fromJson ~/1000）。
        duration: Duration(seconds: s.duration),
      );

  /// 首页单曲
  Future<void> playHomeSong(HomeSong s) async {
    await _controller.playSong(_songFromHome(s));
  }

  /// 首页列表（队列播放）
  Future<void> playHomeQueue(List<HomeSong> list, int index) async {
    await _controller.playQueue(
        [for (final s in list) _songFromHome(s)], index);
  }

  /// 歌单单曲。[cover] 仅当歌单项无 cover 时兜底。
  Future<void> playPlaylistSong(PlaylistSong s, {String cover = ''}) async {
    await _controller.playSong(_songFromPlaylist(s, cover: cover));
  }

  /// 歌单队列。[cover] 仅当歌单项无 cover 时兜底。
  Future<void> playPlaylistQueue(List<PlaylistSong> list, int index,
      {String cover = ''}) async {
    await _controller.playQueue(
        [for (final s in list) _songFromPlaylist(s, cover: cover)], index);
  }

  /// 直接播放 Song
  Future<void> playSong(Song song) async {
    await _controller.playSong(song);
  }

  /// 通用队列播放（歌手页 / 专辑页等直接构造 Song 的场景）。
  Future<void> playQueue(List<Song> songs, int index) async {
    if (songs.isEmpty) return;
    await _controller.playQueue(songs, index);
  }
}

final playHelperProvider = Provider<PlayHelper>(PlayHelper.new);
