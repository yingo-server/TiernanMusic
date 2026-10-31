import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/data/models.dart';
import '../library/data/recent_play_store.dart';
import '../playlist/data/playlist_repository.dart';
import 'data/models.dart';
import 'player_provider.dart';

/// 统一把各模块数据转换为 Song 并调用播放。
class PlayHelper {
  PlayHelper(this._ref);
  final Ref _ref;

  PlayerController get _controller => _ref.read(playerControllerProvider);

  /// 播放成功后写入最近播放（去重置顶，最多 50 条）。
  Future<void> _record(Song song) async {
    if (song.hash.isEmpty) return;
    await RecentPlayStore.add(RecentPlay(
      hash: song.hash,
      name: song.name,
      artist: song.artist,
      cover: song.cover,
      ts: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// 首页单曲
  Future<void> playHomeSong(HomeSong s) async {
    final song = Song(
      hash: s.hash ?? s.id,
      albumId: s.albumId ?? '',
      name: s.name,
      artist: s.singer,
      cover: s.cover,
      duration: Duration(seconds: s.duration),
    );
    await _controller.playSong(song);
    await _record(song);
  }

  /// 首页列表（队列播放）
  Future<void> playHomeQueue(List<HomeSong> list, int index) async {
    final songs = list
        .map((s) => Song(
              hash: s.hash ?? s.id,
              albumId: s.albumId ?? '',
              name: s.name,
              artist: s.singer,
              cover: s.cover,
              duration: Duration(seconds: s.duration),
            ))
        .toList();
    await _controller.playQueue(songs, index);
    if (index >= 0 && index < songs.length) await _record(songs[index]);
  }

  /// 歌单单曲
  Future<void> playPlaylistSong(PlaylistSong s, {String cover = ''}) async {
    final song = Song(
      hash: s.hash,
      albumId: s.albumId,
      albumAudioId: s.albumAudioId,
      name: s.name,
      artist: s.artist,
      cover: cover,
      duration: Duration(seconds: s.duration),
    );
    await _controller.playSong(song);
    await _record(song);
  }

  /// 歌单队列
  Future<void> playPlaylistQueue(List<PlaylistSong> list, int index,
      {String cover = ''}) async {
    final songs = list
        .map((s) => Song(
              hash: s.hash,
              albumId: s.albumId,
              albumAudioId: s.albumAudioId,
              name: s.name,
              artist: s.artist,
              cover: cover,
              duration: Duration(seconds: s.duration),
            ))
        .toList();
    await _controller.playQueue(songs, index);
    if (index >= 0 && index < songs.length) await _record(songs[index]);
  }

  /// 直接播放 Song
  Future<void> playSong(Song song) async {
    await _controller.playSong(song);
    await _record(song);
  }
}

final playHelperProvider = Provider<PlayHelper>(PlayHelper.new);
