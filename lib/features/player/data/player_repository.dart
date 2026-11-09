import 'dart:async';
import '../../../core/net/music_api.dart';
import '../../../core/net/network_phase.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/kugou_api_client.dart';
import '../../../core/audio/preferred_quality.dart';
import '../../../core/direct/kg_play_api.dart';
import '../../../core/direct/kg_client.dart';
import '../../../core/direct/kg_providers.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/resource/cached_api.dart';
import '../../../core/resource/resource_cache.dart';
import '../../../core/domain/song.dart';
import '../../../core/domain/quality.dart';
import '../../../core/domain/response_policy.dart';
import '../../../core/foundation/errors.dart';

/// 一次成功解析出的播放结果。
class PlayableResult {
  const PlayableResult({
    required this.url,
    required this.quality,
    this.isPreview = false,
    this.expectedBytes = 0,
  });
  final String url;
  final AudioQuality quality;
  final bool isPreview;

  /// V402（用户口径）：播放 JSON 声明的字节数（0=未声明）。
  /// 永久缓存实际文件只允许在 `(url, expectedBytes)` 与请求 JSON
  /// 完全一致时写入/复用；试听片段（isPreview=true）永不入库。
  final int expectedBytes;
}

/// 播放器仓库：直连酷狗网关（不经 Node 中转），避免中转层的 20028 风控。
///
/// 内容接口仍走 kapi；只有受风控影响的播放/权益链路直连。
class PlayerRepository {
  PlayerRepository(this._api, [this._ref])
      : _cached = CachedApiCall(_api, ns: 'player');

  final KugouApiClient _api;
  final CachedApiCall _cached;
  final Ref? _ref;

  /// v5.3 R1 重写恢复：设备注册并发收敛字段（CI 报 undefined——
  /// 状态机重写覆盖本文件时丢失声明）。
  bool _registering = false;
  Future<void>? _registeringFuture;
  int _registerRetries = 0;

  /// 动态获取直连播放接口（异步 provider，可能尚未就绪）
  KgPlayApi? get _directPlay => _ref?.read(kgPlayApiProvider);

  /// v5.3 B-01 重写：等待者**复用首个注册者的最终结果**（成功直取 /
  /// 失败共享失败态），只有首个注册者做重试循环，重试有界（≤3）。
  /// 旧实现等待者各自递归 ensureDfid()，注册接口 hang 后网络恢复瞬间
  /// 并发打注册接口（最多 N+3 次，无界于等待者数），风控概率上升。
  Future<String> ensureDfid() async {
    final cached = await SecureStorage.instance.readDfid();
    if (cached != null && cached.isNotEmpty) return cached;
    final pending = _registeringFuture;
    if (pending != null) {
      // 等待者：挂首个注册者的事务上；成败与它完全一致，不再自旋重试
      //（第 21 条：防重；重试责任收敛在首个注册者）。
      try {
        await pending;
        final dfid = await SecureStorage.instance.readDfid();
        if (dfid != null && dfid.isNotEmpty) return dfid;
      } catch (_) {
        // 首个注册者失败：与它共享同一失败结果，不再各自重试
      }
      throw ApiException(-1, '设备注册未完成，请稍后重试');
    }
    if (_registerRetries >= 3) {
      throw ApiException(-1, '设备注册多次失败，请检查网络后重试');
    }
    _registerRetries++;
    final completer = Completer<void>();
    _registeringFuture = completer.future;
    try {
      // V35-A2-2（第 A 批，P2）：`/register/dev` 走 kapi 中转（第 33 条：
      // kapi 返回不可作判定依据，仅作未移植路径兜底）。原生注册在
      // KgClient.registerDevice（userservice risk/v3/r_register_dev）。
      // 约束：优先用 SecureStorage 已存 dfid（上游镜像），真正缺失时
      // 走 kapi 兜底——兜底结果三写同步（Hive/SecureStorage/内存），
      // 避免此前「只写 SecureStorage 绕过 Hive 单源」的分叉。
      final res = await _api.get('/register/dev');
      final data = res['data'];
      final dfid = data is Map ? '${data['dfid'] ?? ''}' : '';
      if (dfid.isEmpty) {
        throw ApiException(-1, '注册设备失败：未返回 dfid');
      }
      await SecureStorage.instance.saveDfid(dfid);
      // 复核②-2（第3批，P1）：注册结果必须回写直连客户端的设备身份——
      // 否则 /v5/url 的签名/请求头仍用旧（空）dfid，首播直连必失败
      //（这是「全部播放有问题」根因链的最后一环）。kg.device.dfid 是
      // 直连层唯一读点（PLY-12 同源）。
      try {
        // 三写同步（V35-A2-2）：内存 device.dfid（直连层唯一读点）+
        // Hive 单源（KgDeviceStore）+ SecureStorage 镜像（上方已写）。
        _ref?.read(kgClientProvider).device.dfid = dfid;
        KgDeviceStore.saveDfidSync(dfid);
      } catch (_) {
        debugPrint('[player] dfid sync to KgClient/Hive failed');
      }
      _registerRetries = 0;
      return dfid;
    } catch (e) {
      rethrow;
    } finally {
      _registeringFuture = null;
      completer.complete();
    }
  }

  /// 查询歌曲详情（/privilege/lite），返回补全后的 Song。
  /// 失败时返回原 song。
  /// V400-B-04：详情响应接入 ResourceCache（90 秒 + userid 维度键 +
  /// 失效回退 + in-flight 合并）；命中缓存不再重复打权益接口。
  Future<Song> fetchDetail(Song song) async {
    // v5.3 P2：详情补全属于解析阶段，进入即播报（>500ms 必须可见）。
    NetworkPhaseTracker.instance.begin(NetworkPhase.resolving,
        detail: 'detail:${song.hash}');
    try {
      final res = await _cached.get('/privilege/lite', query: {
        'hash': song.hash,
        'album_id': song.albumId,
        'qualities': '128,320,flac,high',
      }, ttl: kListTtl);
      final data = res['data'];
      // 部署版的 data 是各音质权益条目列表，并非单首歌曲对象。
      if (data is List) {
        final entries = data.whereType<Map>();
        if (entries.isEmpty) return song;
        final matching = entries.where((entry) =>
            '${entry['hash']}'.toUpperCase() == song.hash.toUpperCase());
        // V34-01（v3.4 审查①，P1）：hash 未命中 = 详情不可用，不能用
        // entries.first 兜底——那会把别的歌的 name/artist/cover/
        // albumAudioId 合并进来（点 A 歌放 B 歌封面，后续 /v5/url 用错
        // album_audio_id）。缺失就返回原 song（第 14/16 条）。
        if (matching.isEmpty) return song;
        final detail = matching.first;
        final merged = Song.fromJson(Map<String, dynamic>.from(detail));
        return merged.copyWith(
          hash: song.hash,
          albumId: merged.albumId.isNotEmpty ? merged.albumId : song.albumId,
          albumAudioId: merged.albumAudioId.isNotEmpty
              ? merged.albumAudioId
              : song.albumAudioId,
          name: merged.name.isNotEmpty ? merged.name : song.name,
          artist: merged.artist.isNotEmpty ? merged.artist : song.artist,
          cover: merged.cover.isNotEmpty ? merged.cover : song.cover,
          duration:
              merged.duration > Duration.zero ? merged.duration : song.duration,
          quality: song.quality,
          // ⚠️ 必须回填 localPath：否则离线歌曲播过一次后，
          // 队列里的对象被详情覆盖，切回来就退化成在线播放（终审 P1-5）。
          localPath: song.localPath,
        );
      }
      if (data is Map<String, dynamic>) {
        final merged = Song.fromJson(data);
        return merged.copyWith(
          hash: song.hash,
          albumId: merged.albumId.isNotEmpty ? merged.albumId : song.albumId,
          albumAudioId: merged.albumAudioId.isNotEmpty
              ? merged.albumAudioId
              : song.albumAudioId,
          name: merged.name.isNotEmpty ? merged.name : song.name,
          artist: merged.artist.isNotEmpty ? merged.artist : song.artist,
          cover: merged.cover.isNotEmpty ? merged.cover : song.cover,
          duration:
              merged.duration > Duration.zero ? merged.duration : song.duration,
          quality: song.quality,
          // ⚠️ 必须回填 localPath：否则离线歌曲播过一次后，
          // 队列里的对象被详情覆盖，切回来就退化成在线播放（终审 P1-5）。
          localPath: song.localPath,
        );
      }
    } catch (e) {
      // V3-05（第5批复核②，P1）：详情补全失败必须可观测且区分错误类型
      //（第 6/7/9/10 条）。TypeError/FormatException 属上游契约变化，
      // 不得与网络失败同等静默吞掉——否则用户永远拿到「未补全的 song」
      // （无时长/无封面）且线上无日志可查。
      if (e is TypeError || e is NoSuchMethodError || e is FormatException) {
        debugPrint('[player] fetchDetail 解析失败（上游契约变化？）: $e');
      } else {
        debugPrint('[player] fetchDetail 网络失败: $e');
      }
      // 详情查询失败不阻塞播放
    } finally {
      NetworkPhaseTracker.instance.end(NetworkPhase.resolving);
    }
    return song;
  }

  /// 读取用户设置的默认音质（事实源：core/audio/preferred_quality.dart）
  AudioQuality _preferredFromSettings() => preferredQuality();

  /// 获取可播放 URL：直连优先，失败回退 kapi。
  ///
  /// V399-B3：蝰蛇/魔法档是特殊音源——直连失败（含权益不足）**不得**
  /// 落到 kapi 通用路径（那会把特殊音源降级成普通音质），必须直接抛出
  /// 明确报因。
  Future<PlayableResult> resolveUrl(Song song,
      {AudioQuality? preferred}) async {
    preferred ??= _preferredFromSettings();
    // v5.3 P2：URL 解析全链路（直连+kapi）是一个用户可见的解析阶段。
    NetworkPhaseTracker.instance.begin(NetworkPhase.resolving,
        detail: 'resolve:${song.hash}');
    try {
      return await _resolveUrlInner(song, preferred: preferred);
    } finally {
      NetworkPhaseTracker.instance.end(NetworkPhase.resolving);
    }
  }

  Future<PlayableResult> _resolveUrlInner(Song song,
      {AudioQuality? preferred}) async {
    final preferredQuality = preferred ?? song.quality;
    if (_directPlay != null) {
      try {
        final direct =
            await _resolveViaDirect(song, preferred: preferredQuality);
        if (direct != null) return direct;
        // 直连无结果且是特殊档：不回退 kapi，明确报因（第 11 条降级有界）
        if (preferredQuality.isSpecial) {
          throw ApiException(
              -1, '音质 ${preferredQuality.value} 直连未返回播放地址');
        }
      } on ApiException catch (e) {
        // 20028/权益错误直接上抛，不再回退（回退也会被同样拦截）
        if (requiresVerification(e) || preferredQuality.isSpecial) rethrow;
        // 其它错误回退 kapi 再试
      } catch (e) {
        // V34-02（v3.4 审查①，P1）：直连的**网络异常**（DioException/
        // SocketException 等非 ApiException）此前不被捕获，直接冒泡
        // → kapi 回退永不执行 →「有网但播不了」（直连先挂时整首失败）。
        // 回退触发条件应覆盖一切直连失败（第 8/11 条：回退路径异常
        // 形态一致、触发条件完整）。20028 之外的异常都值得一试 kapi。
        debugPrint('[player] direct resolve failed, fallback to kapi: $e');
        // V399-B3：特殊音源档网络异常同样不落 kapi（第 11 条）。
        // v5.3 B-05：保留原始异常形态——非 ApiException 的网络异常包装
        // 时把原文放进 message（上游 KgClient 若带 ssaCode 的包装形态，
        // 由 requiresVerification 判定链处理），不再抹平丢失。
        throw ApiException(-1, '音质 ${preferredQuality.value} 解析失败：$e');
      }
    }
    return _resolveViaKapi(song, preferred: preferredQuality);
  }

  /// 直连解析：按音质降级，命中权益不足才抛错。
  Future<PlayableResult?> _resolveViaDirect(Song song,
      {AudioQuality? preferred}) async {
    final play = _directPlay!;
    // 复核①-16（第3批，P1）：直连前必须 ensureDfid——kapi 路径有这一步
    //（:243），直连路径却依赖 KgPlayApi 内部状态。实测证据：/v5/url
    // 未签名报「err clientver or mid or dfid or clienttime」——dfid
    // 未就绪时首播直连必失败再回退 kapi，这正是「全部播放有问题」的
    // 根因链（用户反馈）。修法：直连前等待 dfid 就绪。
    await ensureDfid();
    final start = preferred ?? song.quality;
    // V399-B3：蝰蛇/魔法档在族内降级，不进通用 fallbackOrder
    //（魔法档匿名可用、蝰蛇档 VIP 态返回；降级不得越过族边界）。
    final List<AudioQuality> order;
    if (start.isMagic) {
      order = AudioQuality.magicOrder;
    } else if (start.isViper) {
      order = AudioQuality.viperOrder;
    } else {
      order = AudioQuality.fallbackOrder;
    }
    var startIndex = order.indexOf(start);
    if (startIndex < 0) startIndex = order.length - 1;

    // v5.4：首播只试「首选档 + 一个兜底档」，且两路并发（缓存命中零网络）。
    // 旧实现串行 5 档 + 每档再发 freePart = 最多 10 次原生请求，是「一首歌
    // 卡两次/首播慢」的剩余来源。上限 2 档来自实测：无权益时低一档即可
    // 拿到可播 URL，再低音质对用户无价值（第 25 条有界）。
    final endIndex = (startIndex + 2 > order.length) ? order.length : startIndex + 2;
    final probes = order.sublist(startIndex, endIndex);
    final results = await Future.wait(
      probes.map((q) async {
        try {
          return MapEntry<AudioQuality, PlayUrlResult?>(
              q,
              await play.songUrl(
                hash: song.hash,
                albumId: int.tryParse(song.albumId) ?? 0,
                albumAudioId: int.tryParse(song.albumAudioId) ?? 0,
                quality: q.value,
              ));
        } catch (e) {
          debugPrint('[player] probe ${q.value} failed: $e');
          return MapEntry<AudioQuality, PlayUrlResult?>(q, null);
        }
      }),
    );
    // 优先取**首个有 URL** 的并发结果（首选档优先，results 保序）。
    // 20028/权益错误收集到最后统一抛，保证验证链能拿到 ssaCode。
    int? lastErrorCode;
    String lastMessage = '';
    String lastSsaCode = '';
    for (final entry in results) {
      final q = entry.key;
      final result = entry.value;
      if (result == null) continue;
      if (result.hasUrl) {
        return PlayableResult(
          url: result.bestUrl!,
          quality: _qualityFromBitrate(result, q),
          isPreview: result.isPreview,
          expectedBytes: result.isPreview
              ? (result.offsetFileSize > 0
                  ? result.offsetFileSize
                  : result.previewFileSize)
              : result.previewFileSize,
        );
      }
      lastErrorCode = result.errorCode;
      lastMessage = result.message.isNotEmpty ? result.message : lastMessage;
      if (result.ssaCode != null && result.ssaCode!.isNotEmpty) {
        lastSsaCode = result.ssaCode!;
      }
      if (requiresVerification(ApiException(result.errorCode, result.message))) {
        break;
      }
      // 本档 fail_process（无权益/需购买）：并发发 freePart 试听兜底，
      // 与整曲探测同轮执行，不再让用户在「整曲失败→再等一次试听」间卡住。
      if (result.failProcess.isNotEmpty && !q.isSpecial) {
        try {
          final preview = await play.songUrl(
            hash: song.hash,
            albumId: int.tryParse(song.albumId) ?? 0,
            albumAudioId: int.tryParse(song.albumAudioId) ?? 0,
            quality: q.value,
            freePart: true,
          );
          if (preview.hasUrl) {
            return PlayableResult(
              url: preview.bestUrl!,
              quality: _qualityFromBitrate(preview, q),
              isPreview: true,
              expectedBytes: preview.offsetFileSize > 0
                  ? preview.offsetFileSize
                  : preview.previewFileSize,
            );
          }
        } catch (e) {
          debugPrint('[player] preview ${q.value} failed: $e');
        }
      }
    }
    if (lastErrorCode != null && lastErrorCode != 0) {
      throw ApiException(
        lastErrorCode,
        lastMessage.isEmpty ? '直连获取播放地址失败' : lastMessage,
        ssaCode: lastSsaCode.isNotEmpty ? lastSsaCode : null,
      );
    }
    return null;
  }

  static AudioQuality _qualityFromBitrate(PlayUrlResult r, AudioQuality requested) {
    // 服务端给了明确 extName/quality 时优先采信
    final q = AudioQuality.fromString(r.extName.isNotEmpty ? r.extName : r.quality);
    // V399-B3：特殊音源档（蝰蛇/魔法）不做码率推断——服务端对特殊档
    // 常回 bitRate=0/extName 缺失，推断会把 magic_atmos 错标成 q128
    //（第 15 条单位显式 / 第 16 条语义分离）。
    if (q != AudioQuality.q128 || requested.isSpecial) return q;
    // 否则按码率推断；未知/0 一律按最低，避免把试听错标为高音质
    // PLY-07（审查③）：服务端 bitRate 是 **bps**（320000/128000），
    // 此前按 kbps 阈值（2000/900/300）推断，128/320 恒被判成 flac。
    if (r.bitrate != null && r.bitrate > 0) {
      // V3-06 修正（复核②终审）：阈值对齐 AudioQuality 序位
      //（128 < 320 < flac < Hi-Res < super），192000 边界归 q320 侧：
      // <192000→q128；<500000→q320；≥500000→flac。
      final b = r.bitrate;
      if (b >= 500000) return AudioQuality.flac;
      if (b >= 192000) return AudioQuality.q320;
      return AudioQuality.q128;
    }
    return AudioQuality.q128;
  }

  /// 获取可播放 URL。从期望音质起逐级降级（super→high→flac→320→128）。
  ///
  /// 这里是 kapi 回退路径。
  Future<PlayableResult> _resolveViaKapi(Song song,
      {AudioQuality? preferred}) async {
    await ensureDfid();
    final start = preferred ?? song.quality;
    final order = AudioQuality.fallbackOrder;
    var startIndex = order.indexOf(start);
    if (startIndex < 0) startIndex = order.length - 1;

    ApiException? lastError;
    for (var i = startIndex; i < order.length; i++) {
      final q = order[i];
      final res = await _api.get('/song/url', query: {
        'hash': song.hash,
        'album_id': song.albumId,
        'album_audio_id': song.albumAudioId,
        'quality': q.value,
        // 不带 free_part：需要试听时由调用方显式传入（默认拿全曲）
      });
      final data = res['data'] is Map ? res['data'] as Map : res;
      final errorCode = _int(data['errcode'] ?? data['error_code']);
      final status = _int(data['status']);
      if (errorCode != 0 || (status != null && status != 1)) {
        // PLY-04（审查③）：单档失败应**继续尝试更低音质**（fail 常按 quality
        // 粒度返回：flac 需会员但 320 免费可播），throw 会让降级循环与
        // 下方 free_part 试听兜底全部变成死代码。
        lastError = ApiException(
          errorCode ?? -1,
          _songFailureMessage(data, q),
        );
        continue;
      }

      // 优先 url[0]，仅当主地址缺失时才使用 backupUrl[0]。
      final url = _firstUrl(data['url']) ?? _firstUrl(data['backupUrl']);
      if (url != null) {
        return PlayableResult(
          url: url,
          quality: _actualQuality(data, q),
          isPreview: (_int(data['priv_status']) == 0) ||
              data['hash_offset'] is Map,
          expectedBytes: _declaredBytes(data),
        );
      }
      lastError = ApiException(-1, '音质 ${q.value} 无可用播放地址');
    }
    // 全部音质都拿不到：再试一次官方 60 秒试听（VIP/付费曲的兜底）
    for (var i = startIndex; i < order.length; i++) {
      final q = order[i];
      try {
        final res = await _api.get('/song/url', query: {
          'hash': song.hash,
          'album_id': song.albumId,
          'album_audio_id': song.albumAudioId,
          'quality': q.value,
          'free_part': '1',
        });
        final data = res['data'] is Map ? res['data'] as Map : res;
        final url = _firstUrl(data['url']) ?? _firstUrl(data['backupUrl']);
        if (url != null) {
          return PlayableResult(
            url: url,
            quality: _actualQuality(data, q),
            isPreview: true,
            expectedBytes: _declaredBytes(data),
          );
        }
      } catch (e) {
        // v5.3 B-04：空吞修复——试听兜底失败必须留痕（第 6/9 条）。
        debugPrint('[player] kapi preview fallback failed (q=${q.value}): $e');
      }
    }
    throw lastError ?? ApiException(-1, '没有可尝试的播放音质');
  }

  /// 将部署版 /privilege/lite 的真实权益字段转换为可播放性。
  /// privilege 的 8 位表示无版权；接口顶层 status=1 且非无版权时可播放。
  /// v5.3 B-06：status 缺失按不可播处理（fail-closed，第 14 条）——
  /// 上游字段裁剪/改名后宁可多报一次权益错误，也不误判无版权曲可播。
  static bool canPlay(Map<dynamic, dynamic> privilege) {
    final status = _int(privilege['status']);
    if (status == null || status != 1) return false;
    final value = _int(privilege['privilege']) ?? 0;
    return value & 8 == 0;
  }

  static bool requiresVip(Map<dynamic, dynamic> privilege) {
    final payType = _int(privilege['pay_type']) ?? 0;
    return payType == 1 || payType == 3;
  }

  static String _songFailureMessage(Map data, AudioQuality quality) {
    if (_int(data['errcode'] ?? data['error_code']) == kVerificationRequired) {
      return '本次请求需要验证';
    }
    if (data['privilege'] != null && !canPlay(data)) {
      return (_int(data['privilege']) ?? 0) & 8 != 0 ? '歌曲暂无版权' : '歌曲不可播放';
    }
    if (requiresVip(data) || data['fail_process'] != null) {
      return '音质 ${quality.value} 需要会员或单独购买';
    }
    return '${data['error'] ?? data['error_msg'] ?? data['errmsg'] ?? '音质 ${quality.value} 暂不可播放'}';
  }

  static int? _int(Object? value) =>
      value is int ? value : int.tryParse('$value');

  /// V402：从播放 JSON 取声明字节数（优先 hash_offset 区间差值，
  /// 其次顶层 filesize；0=未声明 → 禁止永久缓存实际文件，第 14 条）。
  static int _declaredBytes(Map data) {
    final off = data['hash_offset'];
    if (off is Map) {
      final st = _int(off['start_byte']) ?? 0;
      final en = _int(off['end_byte']) ?? 0;
      if (en > st) return en - st;
      if (en > 0) return en;
    }
    return _int(data['filesize']) ?? 0;
  }



  static String? _firstUrl(Object? value) {
    final first = value is List && value.isNotEmpty ? value.first : value;
    if (first == null) return null;
    final url = first.toString().trim();
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return url;
  }

  /// 播放地址**不再**走前缀代理。
  ///
  /// 原因（真机实测）：
  /// - Android 的 network_security_config 已对 kugou.com（含子域）放行 cleartext；
  /// - 酷狗 CDN 支持 Range 请求，直连才能边下边播、seek、断点续传；
  /// - 走前缀代理时不转发 Range，表现为「只能播开头 / 卡住 / 播放态滞留」，
  ///   且多一跳中转明显更慢。
  /// 播放地址直连（CDN 支持 Range，直连才能边下边播/seek/断点续传）。
  /// 历史上的前缀代理方案已废弃：代理不转发 Range →「只能播开头」，
  /// 且多一跳更慢（V3-07：删除恒等包装 _proxyHttp，第 32 条死代码）。

  static AudioQuality _actualQuality(Map data, AudioQuality requested) {
    // V3-06（第5批复核②，P2）：与 _qualityFromBitrate 共用同一套阈值
    //（第 5 条：同一判断必须单一来源）。
    // V3-06 修正（复核②终审）：对齐 AudioQuality 序位，192000 归 q320 侧，
    // 消除「128k 显示高品 320、320k 显示 Hi-Res」的错档。
    final bitrate = _int(data['bitRate']);
    if (bitrate != null && bitrate > 0) {
      if (bitrate >= 500000) return AudioQuality.flac;
      if (bitrate >= 192000) return AudioQuality.q320;
      return AudioQuality.q128;
    }
    return AudioQuality.fromString('${data['extName'] ?? requested.value}');
  }
}
