#!/usr/bin/env python3
"""第2顺位任务：内容类接口原生域名实测（匿名）。

对 10 个接口分别测：
  A. 原生域名直打（x-router 目标域名作为 host，url 路径不变，带完整默认参数+android 签名）
  B. 原生域名 + 路径变体（部分服务域名下要去掉路由前缀）
对比 gateway 打法（x-router）是否可用。
"""
import json, sys, urllib.parse
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
from kg_probe import Ctx, request, Raw

ctx = Ctx('anon')

CASES = [
    # name, method, gateway_path, xrouter_host, params(data), native path variants
    ('search/song', 'GET', '/v2/search/song', 'complexsearch.kugou.com',
     {'keyword': '晴天', 'page': 1, 'pagesize': 30, 'platform': 'AndroidFilter',
      'iscorrection': 1, 'privilegefilter': 0, 'area_code': 1, 'dopicfull': 1},
     None, []),
    ('search/album', 'GET', '/v1/search/album', 'complexsearch.kugou.com',
     {'keyword': '晴天', 'page': 1, 'pagesize': 20, 'platform': 'AndroidFilter',
      'iscorrection': 1, 'category': '1', 'sorttype': 0, 'searchsong': 0},
     None, []),
    ('search/special', 'GET', '/v1/search/special', 'complexsearch.kugou.com',
     {'keyword': '晴天', 'page': 1, 'pagesize': 20, 'platform': 'AndroidFilter',
      'albumhide': 0, 'iscorrection': 1, 'nocollect': 0},
     None, []),
    ('yueku', 'GET', '/v1/yueku/recommend_v2', 'service.mobile.kugou.com',
     {'operator': 7, 'plat': 0, 'type': 11, 'area_code': 1, 'req_multi': 1},
     None, []),
    ('rank_list', 'GET', '/ocean/v6/rank/list', 'ocean.kugou.com',
     {'plat': 2, 'withsong': 1, 'parentid': 0},
     None, ['/ocean/v6/rank/list']),
    ('top_song', 'POST', '/musicadservice/container/v1/newsong_publish', 'musicadservice.kugou.com',
     {'rank_id': 21608, 'userid': 0, 'page': 1, 'pagesize': 30, 'tags': []},
     'json', []),
    ('top_playlist', 'POST', '/v2/special_recommend', 'specialrec.service.kugou.com',
     None, 'json', ['/v2/special_recommend']),
    ('everyday_recommend', 'POST', '/everyday_song_recommend', 'everydayrec.service.kugou.com',
     {'platform': 'ios'}, 'params_post', ['/everyday_song_recommend']),
]

# playlist_detail 与 playlist_track_all 的 payload 较复杂，单独构造
import time
def paramskey(dt_s, appid=1005, clientver=20489):
    import hashlib
    # signParamsKey: MD5(appid + ANDROID_SALT + clientver + data)
    return hashlib.md5(('%s%s%s%s' % (appid, 'OIlwieks28dk2k092lksi2UIkp', clientver, dt_s)).encode()).hexdigest()

def top_playlist_payload():
    dt = str(int(time.time()))
    return {
        'appid': 1005, 'mid': ctx.mid, 'clientver': 20489, 'platform': 'android',
        'clienttime': dt, 'userid': 0, 'module_id': 1, 'page': 1, 'pagesize': 30,
        'key': paramskey(dt), 'special_recommend': {
            'withtag': 1, 'withsong': 1, 'sort': 1, 'ugc': 1, 'is_selected': 0,
            'withrecommend': 1, 'area_code': 1, 'categoryid': 0},
        'req_multi': 1, 'retrun_min': 5, 'return_special_falg': 1,
    }

def summarize(raw):
    if raw.status == 0:
        return raw.summary()
    b = raw.body if isinstance(raw.body, dict) else {}
    extra = ''
    d = b.get('data')
    if isinstance(d, dict):
        for k in ('lists', 'song_list', 'special_list', 'songs', 'info'):
            if k in d:
                v = d[k]
                if isinstance(v, list):
                    extra = ' data.%s len=%d' % (k, len(v))
                break
    if isinstance(d, list) and d:
        extra = ' data len=%d keys0=%s' % (len(d), list(d[0].keys())[:8])
    return raw.summary() + extra

def run():
    results = {}
    for name, method, path, host, params, ptype, variants in CASES:
        print('===== %s -> %s =====' % (name, host))
        # A. 原生域名直打（host 域名 + 原 url 路径）
        data = None
        p = params
        if name == 'top_playlist':
            data = top_playlist_payload()
            p = None
        r = request(ctx, path, params=p, data=data, method=method,
                    base='https://' + host,
                    extra_headers={'x-router': host})
        print('  [native-host] ' + summarize(r))
        results.setdefault(name, {})['native'] = r

    # ---- playlist_detail: POST https://pubsongs.kugou.com/v3/get_list_info ----
    print('===== playlist_detail -> pubsongs.kugou.com =====')
    r = request(ctx, '/v3/get_list_info', method='POST',
                base='https://pubsongs.kugou.com',
                data={'data': [{'global_collection_id': '33560430'}], 'userid': 0, 'token': ''},
                extra_headers={'x-router': 'pubsongs.kugou.com'})
    print('  [native-host] ' + summarize(r))
    results.setdefault('playlist_detail', {})['native'] = r

    # ---- playlist_track_all: GET https://pubsongs.kugou.com/pubsongs/v2/get_other_list_file_nofilt ----
    print('===== playlist_track_all -> pubsongs.kugou.com =====')
    r = request(ctx, '/pubsongs/v2/get_other_list_file_nofilt',
                params={'area_code': 1, 'begin_idx': 0, 'plat': 1, 'type': 1,
                        'mode': 1, 'personal_switch': 1,
                        'extend_fields': 'abtags,hot_cmt,popularization',
                        'pagesize': 30, 'global_collection_id': '33560430'},
                base='https://pubsongs.kugou.com')
    print('  [native-host] ' + summarize(r))
    results.setdefault('playlist_track_all', {})['native'] = r

    # ---- search_lyric: GET https://lyrics.kugou.com/search (不签名) ----
    print('===== search_lyric -> lyrics.kugou.com =====')
    r = request(ctx, '/search',
                params={'appid': 1005, 'clientver': 20489, 'keyword': '晴天',
                        'lrctxt': 1, 'man': 'no', 'duration': 0, 'hash': '',
                        'album_audio_id': 0},
                base='https://lyrics.kugou.com',
                clear_default=True, not_sign=True)
    print('  [native-host] ' + summarize(r))
    results.setdefault('search_lyric', {})['native'] = r

    json.dump({k: summarize(v.get('native')) for k, v in results.items()},
              open('/tmp/native_content_probe.json', 'w'), ensure_ascii=False, indent=1)

if __name__ == '__main__':
    run()
