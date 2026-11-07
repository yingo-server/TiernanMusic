import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'download_task.dart';
import 'storage_permission_service.dart';

/// 公共媒体库封装（MediaStore）。
///
/// Android 10+：插入 pending 条目 → 写流 → 置 pending=0；
/// Android 9 及以下：退化为直接写公共目录文件。
class PublicMediaStore {
  PublicMediaStore._();
  static final instance = PublicMediaStore._();

  static const MethodChannel _channel =
      MethodChannel('com.tiernan.music/storage');

  /// App 名（公共目录下的子目录名）
  static const String folderName = 'Tiernan Music';

  /// 各类型对应的公共目录与 MIME
  static String relativePathOf(DownloadTaskType type) => switch (type) {
        DownloadTaskType.audio => 'Music/$folderName',
        DownloadTaskType.cover => 'Pictures/$folderName',
        DownloadTaskType.lyric => 'Documents/$folderName/Lyrics',
        DownloadTaskType.mv => 'Movies/$folderName',
      };

  static String collectionOf(DownloadTaskType type) => switch (type) {
        DownloadTaskType.audio => 'audio',
        DownloadTaskType.cover => 'images',
        // MediaStore.Files：支持 Documents/ 下任意 RELATIVE_PATH。
        // Downloads collection 要求 RELATIVE_PATH 位于 Download/ 之下，
        // 用它插 Documents/ 路径在 Android 10+ 上 insert 必抛 IllegalArgumentException。
        DownloadTaskType.lyric => 'files',
        DownloadTaskType.mv => 'video',
      };

  static String mimeOf(DownloadTaskType type, {String? realTempPath}) {
    // V35-B3（第 B 批，P1）：audio 真实扩展名（.flac/.m4a）对应正确
    // MIME——此前恒 audio/mpeg，车机/第三方播放器按 MIME 选解码器
    // 直接报「格式不支持」（第 15 条单位/形态显式）。
    if (type == DownloadTaskType.audio &&
        realTempPath != null &&
        realTempPath.isNotEmpty) {
      final ext = realTempPath.substring(realTempPath.lastIndexOf('.'));
      if (ext == '.flac') return 'audio/flac';
      if (ext == '.m4a') return 'audio/mp4';
      if (ext == '.ogg') return 'audio/ogg';
      if (ext == '.wav') return 'audio/wav';
      if (ext == '.ape') return 'audio/x-ape';
    }
    return switch (type) {
      DownloadTaskType.audio => 'audio/mpeg',
      DownloadTaskType.cover => 'image/jpeg',
      DownloadTaskType.lyric => 'text/plain',
      DownloadTaskType.mv => 'video/mp4',
    };
  }

  /// 公共目录名（Android 9 及以下直接写路径时使用）
  static String publicDirNameOf(DownloadTaskType type) => switch (type) {
        DownloadTaskType.audio => 'music',
        DownloadTaskType.cover => 'pictures',
        DownloadTaskType.lyric => 'documents',
        DownloadTaskType.mv => 'movies',
      };


  /// 下载用临时目录（App 私有，发布完成后再写入公共目录）。
  static Future<Directory> tempDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/downloads_tmp');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 降级目录：App 外部私有目录（Android/data/...），多数文件管理器可见。
  static Future<String> fallbackDir(DownloadTaskType type) async {
    final base = await getExternalStorageDirectory();
    final root = base?.path ?? (await getApplicationDocumentsDirectory()).path;
    final dir = Directory('$root/${relativePathOf(type)}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// 把临时文件发布到公共目录，返回可访问位置。
  Future<PublishedFile> publish({
    required DownloadTaskType type,
    required String tempFilePath,
    required String displayName,
    required StorageStrategy strategy,
  }) async {
    if (strategy == StorageStrategy.mediaStore) {
      final uri = await _channel.invokeMethod<String>('insert', {
        'collection': collectionOf(type),
        'displayName': displayName,
        'relativePath': relativePathOf(type),
        'mimeType': mimeOf(type, realTempPath: tempFilePath),
      });
      if (uri == null || uri.isEmpty) {
        // MediaStore 插入失败 → 退回直接路径
        return _publishDirect(type, tempFilePath, displayName);
      }
      try {
        final ok = await _channel
            .invokeMethod<bool>('write', {'uri': uri, 'srcPath': tempFilePath});
        if (ok != true) {
          await _channel.invokeMethod<bool>('delete', {'uri': uri});
          return await _publishDirect(type, tempFilePath, displayName);
        }
        // V35-B3（第 B 批，P1）：finalize 返回值必须校验——Kotlin 层
        // 现在真实返回 update 行数判定；false = 条目消失（被系统清理/
        // Uri 无效），此时不能当发布成功，降级直写。
        final finalized = await _channel.invokeMethod<bool>('finalize', {'uri': uri});
        if (finalized != true) {
          try {
            await _channel.invokeMethod<bool>('delete', {'uri': uri});
          } catch (_) {}
          return await _publishDirect(type, tempFilePath, displayName);
        }
        return PublishedFile(
          uri: uri,
          displayPath: '/sdcard/${relativePathOf(type)}',
        );
      } catch (_) {
        // 写流/finalize 抛异常时也要清掉 IS_PENDING=1 的孤儿条目，
        // 否则残留约 7 天（MediaStore 对 pending 条目的清理周期）。
        try {
          await _channel.invokeMethod<bool>('delete', {'uri': uri});
        } catch (_) {}
        return _publishDirect(type, tempFilePath, displayName);
      }
    }
    return _publishDirect(type, tempFilePath, displayName);
  }

  /// 直接写公共目录（Android 9 及以下）或降级目录。
  Future<PublishedFile> _publishDirect(
    DownloadTaskType type,
    String tempFilePath,
    String displayName,
  ) async {
    final service = StoragePermissionService.instance;
    final publicBase = await service.publicDir(publicDirNameOf(type));
    String dirPath;
    String display;
    if (publicBase == null || publicBase.isEmpty) {
      dirPath = await fallbackDir(type);
      display = dirPath;
    } else {
      var base = publicBase;
      // 歌词目录：Documents 不可用时退到 Download
      if (type == DownloadTaskType.lyric) {
        final target = Directory('$base/$folderName/Lyrics');
        if (!await target.exists()) {
          final downloadBase = await service.publicDir('downloads');
          if (downloadBase != null && downloadBase.isNotEmpty) {
            base = downloadBase;
          }
        }
      }
      final dir = Directory('$base/$folderName${_subSuffix(type)}');
      if (!await dir.exists()) await dir.create(recursive: true);
      dirPath = dir.path;
      display = '/sdcard/${relativePathOf(type)}';
    }

    final target = File('$dirPath/$displayName');
    // V37-04（B3 P1-6，第 20/21 条）：**发布前清扫同前缀 .part 残留**——
    // 此前写入中途失败时 catch 里虽会清 .part，但若进程被杀（断电/
    // 强杀），.part 会永久残留占空间。每次发布同名文件前先删残留。
    try {
      final stalePart = File('${target.path}.part');
      if (await stalePart.exists()) await stalePart.delete();
    } catch (_) {
      // 清扫失败不阻断发布（.part 残留会由下一次发布再次尝试清理）
    }
    final partFile = File('${target.path}.part');
    // D-02（第6批③，P1）：**先写临时文件，成功后再原子替换**（第 21 条）。
    final inRaf = File(tempFilePath).openRead();
    final outRaf = partFile.openWrite(mode: FileMode.write);
    try {
      await for (final chunk in inRaf) {
        outRaf.add(chunk);
      }
    try {
      await for (final chunk in inRaf) {
        outRaf.add(chunk);
      }
      await outRaf.flush();
      await outRaf.close();
      // 写完后才替换旧文件；此后任何异常都不会破坏旧副本。
      // V37-04（B3 P1-2）：rename 覆盖改法——已存在旧文件时**先删旧
      // 文件再 rename** 之间存在「既无旧文件也无新文件」的窗口；
      // Android/Linux 的 rename 在目标存在时**原子覆盖**，因此只需
      // 直接 rename，无需预先 delete（避免删除-改名之间的非原子窗口）。
      await partFile.rename(target.path);
    } catch (e) {
      // 失败时清理 .part，旧文件原封不动
      try {
        if (await partFile.exists()) await partFile.delete();
      } catch (_) {}
      rethrow;
    }
    return PublishedFile(path: target.path, displayPath: display);
  }

  static String _subSuffix(DownloadTaskType type) =>
      type == DownloadTaskType.lyric ? '/Lyrics' : '';

  /// 查询已存在的同名文件（用于「已下载」判定）。
  Future<PublishedFile?> queryExisting({
    required DownloadTaskType type,
    required String displayName,
  }) async {
    final service = StoragePermissionService.instance;
    final level = await service.apiLevel();
    if (level >= 29) {
      try {
        final uri = await _channel.invokeMethod<String>('query', {
          'collection': collectionOf(type),
          'displayName': displayName,
          'relativePath': relativePathOf(type),
        });
        if (uri != null && uri.isNotEmpty) {
          return PublishedFile(
            uri: uri,
            displayPath: '/sdcard/${relativePathOf(type)}',
          );
        }
      } catch (_) {}
      return null;
    }
    final base = await service.publicDir(publicDirNameOf(type));
    if (base == null || base.isEmpty) return null;
    final dir = Directory('$base/$folderName${_subSuffix(type)}');
    final file = File('${dir.path}/$displayName');
    if (await file.exists()) {
      return PublishedFile(
        path: file.path,
        displayPath: '/sdcard/${relativePathOf(type)}',
      );
    }
    return null;
  }

  /// 删除已发布文件。
  Future<bool> delete(PublishedFile file) async {
    try {
      if (file.uri != null && file.uri!.isNotEmpty) {
        final ok = await _channel
            .invokeMethod<bool>('delete', {'uri': file.uri});
        return ok == true;
      }
      if (file.path != null && file.path!.isNotEmpty) {
        final f = File(file.path!);
        if (await f.exists()) {
          await f.delete();
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// 用其它应用打开文件。
  Future<bool> open(PublishedFile file) async {
    try {
      final ok = await _channel.invokeMethod<bool>('openFile', {
        'uri': file.uri,
        'path': file.path,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// 在系统文件管理器中打开所在目录。
  ///
  /// V37-05（B3 P2-14，第 3 条契约先行）：MediaStore 发布的文件只有
  /// content:// uri（path 为空）→ 恒失败。改为：调用前判定，无绝对
  /// 路径时直接返回 false（不发起注定失败的 invokeMethod），
  /// 调用方据此给出降级反馈（复制路径 Toast）。
  Future<bool> viewFolder(PublishedFile file) async {
    final path = file.path;
    if (path == null || path.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('viewFolder', {'path': path});
      return ok == true;
    } catch (_) {
      return false;
    }
  }
}

/// 已发布文件的位置信息。
class PublishedFile {
  const PublishedFile({
    this.uri,
    this.path,
    this.displayPath = '',
  });

  /// MediaStore Uri（Android 10+）
  final String? uri;

  /// 绝对路径（Android 9 及以下 / 降级目录）
  final String? path;

  /// 展示给用户的目录位置
  final String displayPath;

  bool get isValid => (uri != null && uri!.isNotEmpty) ||
      (path != null && path!.isNotEmpty);
}
