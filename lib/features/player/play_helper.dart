import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/data/models.dart';
import '../playlist/data/playlist_repository.dart';
import 'data/models.dart';
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

  /// 首页单曲
  Future<void> playHomeSong(HomeSong s) async {
    final song = Song(
      hash: s.hash ?? s.id,
      albumId: s.albumId ?? '',
      albumAudioId: s.albumAudioId ?? '',
      name: s.name,
      artist: s.singer,
      cover: s.cover,
      duration: Duration(seconds: s.duration),
    );
    await _controller.playSong(song);
  }

  /// 首页列表（队列播放）
  Future<void> playHomeQueue(List<HomeSong> list, int index) async {
    final songs = list
        .map((s) => Song(
              hash: s.hash ?? s.id,
              albumId: s.albumId ?? '',
              albumAudioId: s.albumAudioId ?? '',
              name: s.name,
              artist: s.singer,
              cover: s.cover,
              duration: Duration(seconds: s.duration),
            ))
        .toList();
    await _controller.playQueue(songs, index);
  }

  /// 歌单单曲。[cover] 仅当歌单项无 cover 时兜底。
  Future<void> playPlaylistSong(PlaylistSong s, {String cover = ''}) async {
    final song = Song(
      hash: s.hash,
      albumId: s.albumId,
      albumAudioId: s.albumAudioId,
      name: s.name,
      artist: s.artist,
      cover: s.cover.isNotEmpty ? s.cover : cover,
      duration: Duration(seconds: s.duration),
    );
    await _controller.playSong(song);
  }

  /// 歌单队列。[cover] 仅当歌单项无 cover 时兜底。
  Future<void> playPlaylistQueue(List<PlaylistSong> list, int index,
      {String cover = ''}) async {
    final songs = list
        .map((s) => Song(
              hash: s.hash,
              albumId: s.albumId,
              albumAudioId: s.albumAudioId,
              name: s.name,
              artist: s.artist,
              cover: s.cover.isNotEmpty ? s.cover : cover,
              duration: Duration(seconds: s.duration),
            ))
        .toList();
    await _controller.playQueue(songs, index);
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
