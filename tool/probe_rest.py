#!/usr/bin/env python3
"""第二批：评论楼中楼 / 歌单 / MV / 推荐（带 data body）"""
import json, sys, time
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
from kg_probe import request, Ctx, STATES, md5, APPID, CLIENTVER

HASH = 'B3A52A7A958BF0AED0EBFBA2E9A818B7'
MIX = 32100650
HASHL = HASH.lower()


def rpt(tag, r):
    if not isinstance(r.body, dict):
        print('  %-26s http=%s RAW=%r' % (tag, r.status, r.body[:200]))
        return None
    b = r.body
    print('  %-26s http=%s status=%s err=%s/%s msg=%r' % (
        tag, r.status, b.get('status'), b.get('error_code'), b.get('errcode'),
        b.get('error') or b.get('error_msg') or b.get('errmsg') or b.get('info')))
    d = b.get('data')
    if isinstance(d, dict):
        print('     data keys %s' % list(d.keys())[:16])
        for k, v in list(d.items()):
            if isinstance(v, list):
                print('       data.%s list[%d]' % (k, len(v)))
                if v and isinstance(v[0], dict):
                    print('         [0] %s' % list(v[0].keys())[:22])
    elif isinstance(d, list):
        print('     data list[%d]' % len(d))
        if d:
            print('       [0] %r' % (repr(d[0])[:200]))
    return b


def run(name, fn):
    print('\n=== %s ===' % name)
    for st in STATES:
        rpt('%-8s' % st, fn(Ctx(st)))


# ---- 取真实歌单ID ----
c0 = Ctx('anon')
r0 = request(c0, '/v1/search/special', params={'keyword': '周杰伦', 'page': 1,
             'pagesize': 3, 'platform': 'AndroidFilter'}, xrouter='complexsearch.kugou.com')
sp = r0.body['data']['lists'][0]
print('SPECIAL ITEM FULL:', json.dumps(sp, ensure_ascii=False)[:1200])
GID = sp.get('gid') or sp.get('global_collection_id') or sp.get('specialid')
print('SPECIALID/GID =', GID, 'specialid=', sp.get('specialid'))

# ---- 取 MV hash ----
r1 = request(c0, '/v1/search/mv', params={'keyword': '周杰伦', 'page': 1,
             'pagesize': 3, 'platform': 'AndroidFilter'}, xrouter='complexsearch.kugou.com')
mv = r1.body['data']['lists'][0]
print('MV ITEM:', json.dumps(mv, ensure_ascii=False)[:900])
MVHASH = mv.get('MvHash') or mv.get('FileHash')
MVID = mv.get('AudioID') or mv.get('MixSongID')
print('MVHASH=%s MVID=%s' % (MVHASH, MVID))

# ---------- 评论楼中楼 ----------
run('hot_replylist(song)', lambda c: request(c, '/mcomment/v1/hot_replylist', method='POST', params={
    'childrenid': 20505418, 'need_show_image': 1, 'p': 1, 'pagesize': 5,
    'show_classify': 1, 'show_hotword_list': 1,
    'code': 'fc4be23b4e972707f36b8a828a93ba8a', 'tid': 1723639894,
    'mixsongid': MIX}))

# ---------- 歌单详情 ----------
run('playlist/detail', lambda c: request(c, '/v3/get_list_info', method='POST',
    xrouter='pubsongs.kugou.com',
    data={'listid': [str(GID)], 'area_code': 1, 'show_landingpage': 1, 'request_mac': ''}))

# ---------- 歌单歌曲 ----------
run('playlist/track/all', lambda c: request(c, '/pubsongs/v2/get_other_list_file_nofilt',
    params={'area_code': 1, 'begin_idx': 0, 'plat': 1, 'type': 1, 'mode': 1,
            'personal_switch': 1, 'extend_fields': 'abtags,hot_cmt,popularization',
            'pagesize': 30, 'global_collection_id': GID}))

# ---------- MV ----------
run('kmr/audio/mv', lambda c: request(c, '/kmr/v1/audio/mv', method='POST',
    xrouter='openapi.kugou.com', extra_headers={'KG-TID': '38'},
    data={'data': [{'album_audio_id': str(MVID)}], 'fields': ''}))

run('video/url', lambda c: request(c, '/v2/interface/index',
    xrouter='trackermv.kugou.com',
    params={'backupdomain': 1, 'cmd': 123, 'ext': 'mp4', 'ismp3': 0,
            'hash': MVHASH, 'pid': 1, 'type': 1,
            'key': __import__('kg_probe').sig_key(MVHASH, c.mid, c.userid)}))

# ---------- 推荐（带完整 data body）----------
run('special_recommend(full)', lambda c: request(c, '/v2/special_recommend', method='POST',
    xrouter='specialrec.service.kugou.com', params={},
    data={'appid': APPID, 'mid': c.mid, 'clientver': CLIENTVER, 'platform': 'android',
          'clienttime': time.strftime('%Y%m%d%H'), 'userid': c.userid, 'module_id': 1,
          'page': 1, 'pagesize': 30,
          'key': md5('%s%s%s%s' % (APPID, 'OIlwieks28dk2k092lksi2UIkp', CLIENTVER, time.strftime('%Y%m%d%H'))),
          'special_recommend': {'withtag': 1, 'withsong': 1, 'categoryid': 0, 'tagids': ''},
          'req_multi': 1, 'retrun_min': 5, 'return_special_falg': 1}))
