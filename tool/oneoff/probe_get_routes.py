#!/usr/bin/env python3
"""验证 GET 语义的路由（仓库实际用 _api.get 调用）"""
import json, sys, time
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
import kg_probe
from kg_probe import request, Ctx, STATES, md5, APPID, CLIENTVER

GID = 'collection_3_2132029040_287_0'
MIX = '32100650'


def rpt(tag, r):
    if not isinstance(r.body, dict):
        print('  %-34s http=%s RAW=%r' % (tag, r.status, r.body[:160]))
        return
    b = r.body
    print('  %-34s http=%s status=%s err=%s msg=%r' % (
        tag, r.status, b.get('status'), b.get('error_code') or b.get('errcode'),
        (b.get('errmsg') or b.get('error')) if (b.get('error_code') or b.get('errcode')) else ''))
    d = b.get('data')
    if isinstance(d, list):
        print('       data list[%d]' % len(d))
        if d and isinstance(d[0], dict):
            print('       [0] %s' % list(d[0].keys())[:20])


print('=== GET /v2/special_recommend (top/playlist) ===')
dt = time.strftime('%Y%m%d%H')
key = kg_probe.sig_android.__module__ and md5('%s%s%s%s' % (APPID, 'OIlwieks28dk2k092lksi2UIkp', CLIENTVER, dt))
for st in STATES:
    c = Ctx(st)
    # A: 仅 query
    r = request(c, '/v2/special_recommend', method='GET', xrouter='specialrec.service.kugou.com',
                params={'module_id': 1, 'page': 1, 'pagesize': 30, 'clienttime': dt, 'key': key})
    rpt('%s GET-query' % st, r)
    # B: GET + body
    r = request(c, '/v2/special_recommend', method='GET', xrouter='specialrec.service.kugou.com',
                params={}, data={'appid': APPID, 'mid': c.mid, 'clientver': CLIENTVER,
                                 'platform': 'android', 'clienttime': dt, 'userid': int(c.userid or 0),
                                 'module_id': 1, 'page': 1, 'pagesize': 30, 'key': key,
                                 'special_recommend': {'withtag': 1, 'withsong': 1, 'categoryid': 0, 'tagids': ''},
                                 'req_multi': 1, 'retrun_min': 5, 'return_special_falg': 1})
    rpt('%s GET+body' % st, r)

print('\n=== GET /everyday_song_recommend ===')
for st in STATES:
    c = Ctx(st)
    r = request(c, '/everyday_song_recommend', method='GET',
                xrouter='everydayrec.service.kugou.com', params={'platform': 'ios'})
    rpt('%s GET-query' % st, r)

print('\n=== GET /kmr/v1/audio/mv ===')
for st in STATES:
    c = Ctx(st)
    r = request(c, '/kmr/v1/audio/mv', method='GET', xrouter='openapi.kugou.com',
                extra_headers={'KG-TID': '38'},
                params={'album_audio_id': MIX, 'fields': 'mkv,tags,h264,h265,authors'})
    rpt('%s GET-query' % st, r)

print('\n=== GET /v3/get_list_info ===')
for st in STATES:
    c = Ctx(st)
    r = request(c, '/v3/get_list_info', method='GET', xrouter='pubsongs.kugou.com',
                params={'global_collection_id': GID, 'area_code': 1})
    rpt('%s GET-query' % st, r)
    r = request(c, '/v3/get_list_info', method='GET', xrouter='pubsongs.kugou.com',
                params={}, data={'data': [{'global_collection_id': GID}]})
    rpt('%s GET+body' % st, r)
