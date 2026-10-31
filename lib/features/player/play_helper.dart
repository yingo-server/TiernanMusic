import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/data/models.dart';
import '../playlist/data/playlist_repository.dart';
import 'data/models.dart';
import 'player_provider.dart';

/// 统一把各模块数据转换为 Song 并调用播放。
class PlayHelper {
  PlayHelper(this._ref);
  final Ref _ref;

  PlayerController get _controller => _ref.read(playerControllerProvider);

  /// 首页单曲
  Future<void> playHomeSong(HomeSong s) => _controller.playSong(Song(
        hash: s.hash ?? s.id,
        albumId: s.albumId ?? '',
        name: s.name,
        artist: s.singer,
        cover: s.cover,
        duration: Duration(seconds: s.duration),
      ));

  /// 首页列表（队列播放）
  Future<void> playHomeQueue(List<HomeSong> list, int index) =>
      _controller.playQueue(
        list
            .map((s) => Song(
                  hash: s.hash ?? s.id,
                  albumId: s.albumId ?? '',
                  name: s.name,
                  artist: s.singer,
                  cover: s.cover,
                  duration: Duration(seconds: s.duration),
                ))
            .toList(),
        index,
      );

  /// 歌单单曲
  Future<void> playPlaylistSong(PlaylistSong s, {String cover = ''}) =>
      _controller.playSong(Song(
        hash: s.hash,
        albumId: s.albumId,
        albumAudioId: s.albumAudioId,
        name: s.name,
        artist: s.artist,
        cover: cover,
        duration: Duration(seconds: s.duration),
      ));

  /// 歌单队列
  Future<void> playPlaylistQueue(List<PlaylistSong> list, int index,
          {String cover = ''}) =>
      _controller.playQueue(
        list
            .map((s) => Song(
                  hash: s.hash,
                  albumId: s.albumId,
                  albumAudioId: s.albumAudioId,
                  name: s.name,
                  artist: s.artist,
                  cover: cover,
                  duration: Duration(seconds: s.duration),
                ))
            .toList(),
        index,
      );

  /// 直接播放 Song
  Future<void> playSong(Song song) => _controller.playSong(song);
}

final playHelperProvider = Provider<PlayHelper>(PlayHelper.new);
