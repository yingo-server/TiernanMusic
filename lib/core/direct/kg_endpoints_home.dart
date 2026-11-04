import 'dart:convert';

import 'kg_client.dart';
import 'kg_crypto.dart';

import 'kg_direct_api_client.dart';

/// 首页与榜单端点（yueku/rank/top/everyday/banner）
///
/// 【实测结论见各方法注释与 docs/api_verified.md】
/// 从 kg_direct_api_client.dart 拆出（R1 重构）；由主类组合调用，
/// 行为与拆分前完全一致。
///
/// 方法签名与主类拆分前一致；由 KgDirectApiClient 组合委托。
class KgEndpointHome {
  KgEndpointHome(this.kg);
  final KgClient kg;



  Future<KgResponse> yueku() {
    // 实测 service.mobile.kugou.com 证书为网宿 CDN 证书（CN=default.chinanetcenter.com，
    // SAN 不含该三标签域名），Dart/Dio 会 TLS 拒绝 → 保持 gateway + x-router。
    return kg.request('/v1/yueku/recommend_v2',
        method: 'GET',
        headers: {'x-router': 'service.mobile.kugou.com'},
        params: {
          'operator': 7,
          'plat': 0,
          'type': 11,
          'area_code': 1,
          'req_multi': 1,
        });
  }



  /// 歌手详情（module/artist_detail.js）

  Future<KgResponse> rankList(Map<String, dynamic> q) {
    // 原生域名 ocean.kugou.com：gateway 的路由前缀 ocean/ 需去掉（带前缀 404）。
    return kg.request('/v6/rank/list',
        method: 'GET',
        baseUrl: 'https://ocean.kugou.com',
        params: {
          'plat': 2,
          'withsong': q['withsong'] ?? 1,
          'parentid': 0,
        });
  }

  /// 新歌速递（module/top_song.js）。
  /// 原生域名 musicadservice.kugou.com（去掉 gateway 路由前缀 musicadservice/）。
  /// 实测：POST body {rank_id,userid,page,pagesize,tags:[]}，data 为数组，
  /// 与 kapi /top/song 结构逐字段一致（0 差异）。
  Future<KgResponse> topSong(Map<String, dynamic> q) {
    return kg.request('/container/v1/newsong_publish',
        method: 'POST',
        baseUrl: 'https://musicadservice.kugou.com',
        data: {
          'rank_id': q['type'] ?? q['rank_id'] ?? 21608,
          'userid': q['userid'] ?? kg.userid,
          'page': q['page'] ?? 1,
          'pagesize': q['pagesize'] ?? 30,
          'tags': const <String>[],
        });
  }

  Future<KgResponse> everydayRecommend(Map<String, dynamic> q) {
    // 实测 everydayrec.service.kugou.com 为三标签域名，*.kugou.com 通配符证书
    // 不覆盖 → Dart/Dio TLS 拒绝，保持 gateway + x-router。
    //
    // 【实测】`platform` 必须是 **query 参数**（放 body 里无效，上游不认），
    // 默认 'ios'。
    return kg.request('/everyday_song_recommend',
        method: 'POST',
        headers: {'x-router': 'everydayrec.service.kugou.com'},
        params: {'platform': '${q['platform'] ?? 'ios'}'});
  }

  Future<KgResponse> topPlaylist(Map<String, dynamic> q) {
    // Node top_playlist.js: `const dateTime = (Date.now()/1000).toFixed(0)` —— **秒级**。
    // （此前误用 YYYYMMDDHH，导致 signParamsKey 的输入与 Node 不一致 → ec=200101）
    final dateTime = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    return kg.request('/v2/special_recommend',
        method: 'POST',
        // 【实测】special_recommend 直连恒 ec=200101（匿名/VIP、多组参数均
        // 复现，Node 上游同样如此），该端点疑似上游已收紧 → 保留 kapi 回退。
        // 实测 specialrec.service.kugou.com 为三标签域名，*.kugou.com 证书不覆盖
        // （SAN 仅 *.kugou.com），Dart/Dio TLS 拒绝 → 保持 gateway + x-router。
        headers: {'x-router': 'specialrec.service.kugou.com'},
        data: {
          'appid': kg.lite ? KgConfig.liteAppid : KgConfig.appid,
          'mid': kg.device.mid,
          'clientver':
              kg.lite ? KgConfig.liteClientver : KgConfig.clientver,
          'platform': 'android',
          'clienttime': dateTime,
          'userid': kg.userid,
          'module_id': q['module_id'] ?? 1,
          'page': q['page'] ?? 1,
          'pagesize': q['pagesize'] ?? 30,
          'key': KgSignature.paramsKey(dateTime, lite: kg.lite),
          'special_recommend': {
            'withtag': q['withtag'] ?? 1,
            'withsong': q['withsong'] ?? 1,
            'categoryid': q['category_id'] ?? 0,
            'tagids': q['tagids'] ?? '',
          },
          'req_multi': 1,
          'retrun_min': 5,
          'return_special_falg': 1,
        });
  }

  /// 热搜（search_hot.js）。
  /// 原生域名 msearch.kugou.com（两标签，*.kugou.com 通配证书覆盖，实测 TLS OK），
  /// gateway 路由前缀 msearch/ 需去掉。实测 200 status=1，data.list[] 每项
  /// 含 name + keywords[]，与 kapi /search/hot 结构一致。
  Future<KgResponse> searchHot(Map<String, dynamic> q) {
    return kg.request('/api/v3/search/hot_tab',
        method: 'GET',
        baseUrl: 'https://msearch.kugou.com',
        params: {
          'navid': q['navid'] ?? 1,
          'plat': q['plat'] ?? 2,
        });
  }

  /// 乐库 banner（yueku_banner.js）。
  /// 源码无 x-router/baseURL → gateway 的 /ads.gateway/v3/listen_banner。
  /// 【实测】匿名态恒返回 error_code=31136（无数据）——Node 版同样如此
  /// （依赖登录态/风控态），属上游行为非实现差异；失败由 _wrap 抛出 →
  /// _directOrFallback 回退 kapi（同样 31136）→ fetchBanners 容错置空。
  Future<KgResponse> yuekuBanner(Map<String, dynamic> q) {
    return kg.request('/ads.gateway/v3/listen_banner',
        method: 'POST',
        data: {
          'plat': 0,
          'channel': 201,
          'operator': 7,
          'networktype': 2,
          'userid': q['userid'] ?? kg.userid,
          'vip_type': 0,
          'm_type': 0,
          'tags': const <String>[],
          'apiver': 5,
          'ability': 2,
          'mode': 'normal',
        });
  }

  /// 视频详情（video_detail.js）。
  /// 原生域名 kmr.service.kugou.com 为三标签域名，*.kugou.com 单层通配证书
  /// 不覆盖（docs/api_report_player.md：TLS 硬失败）→ 保持 gateway + x-router。
  /// 实测 200 status=1，data 数组首项含 hd/sd/qhd/ld_hash、timelength 等，
  /// 与 kapi /video/detail 结构一致（既往验证 + 本轮复核）。
  Future<KgResponse> videoDetail(Map<String, dynamic> q) {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final dfid = kg.device.dfid.isEmpty ? '-' : kg.device.dfid;
    return kg.request('/v1/video',
        method: 'POST',
        clearDefaultParams: true,
        headers: {'x-router': 'kmr.service.kugou.com'},
        data: {
          'appid': kg.lite ? KgConfig.liteAppid : KgConfig.appid,
          'clientver': kg.lite ? KgConfig.liteClientver : KgConfig.clientver,
          'clienttime': clienttime,
          'mid': kg.device.mid,
          'uuid': KgCrypto.md5('$dfid${kg.device.mid}'),
          'dfid': dfid,
          'token': kg.token,
          'key': KgSignature.paramsKey('$clienttime', lite: kg.lite),
          'show_resolution': 1,
          'data': [
            for (final id in '${q['id'] ?? q['ids'] ?? ''}'.split(','))
              if (id.trim().isNotEmpty) {'video_id': id.trim()},
          ],
        });
  }
}
