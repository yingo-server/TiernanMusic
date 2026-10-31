#!/usr/bin/env python3
"""歌词专项：/search + /download 三态 + 参数矩阵"""
import json, sys
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
from kg_probe import request, Ctx, STATES

HASH = 'B3A52A7A958BF0AED0EBFBA2E9A818B7'
NAME = '晴天'
SINGER = '周杰伦'
DUR = 269000
AAID = 32100650


def rpt(tag, r, n=300):
    if not isinstance(r.body, dict):
        print('  %-30s http=%s RAW=%r' % (tag, r.status, r.body[:150]))
        return
    b = r.body
    print('  %-30s http=%s status=%s errcode=%s errmsg=%r' % (
        tag, r.status, b.get('status'), b.get('errcode') or b.get('error_code'),
        b.get('errmsg') or b.get('error')))
    return b


print('===== 歌词搜索 /search 三态 =====')
base_p = {'appid': 1005, 'clientver': 20489, 'keyword': '%s - %s' % (SINGER, NAME),
          'duration': DUR, 'hash': HASH, 'lrctxt': 1, 'man': 'no'}
res = {}
for st in STATES:
    c = Ctx(st)
    r = request(c, '/search', base='https://lyrics.kugou.com',
                clear_default=True, not_sign=True, params=base_p)
    b = rpt('%-8s' % st, r)
    if b:
        res[st] = b
        cl = b.get('candidates') or []
        print('       candidates=%d proposal=%s' % (len(cl), b.get('proposal')))
        if cl:
            print('       [0] keys=%s' % list(cl[0].keys()))
            print('       [0] id=%s accesskey=%s duration=%s song=%s singer=%s' % (
                cl[0].get('id'), cl[0].get('accesskey'), cl[0].get('duration'),
                cl[0].get('song'), cl[0].get('singer')))
    res.setdefault('_raw', {})[st] = {'status': r.status, 'body': b}

print('\n===== 参数矩阵（anon）=====')
c = Ctx('anon')
cases = [
    ('keyword-only', {'appid': 1005, 'clientver': 20489, 'keyword': NAME, 'lrctxt': 1, 'man': 'no'}),
    ('kw+dur+hash', base_p),
    ('kw+dur+hash+aaid', dict(base_p, album_audio_id=AAID)),
    ('no lrctxt/man', {'appid': 1005, 'clientver': 20489, 'keyword': NAME}),
    ('+signature(android)', None),
    ('+full defaults', dict(base_p)),
    ('lrc fmt hint', dict(base_p, fmt='lrc')),
]
for label, p in cases:
    if p is None:
        r = request(c, '/search', base='https://lyrics.kugou.com',
                    clear_default=False, params=base_p)
    elif label == '+full defaults':
        r = request(c, '/search', base='https://lyrics.kugou.com',
                    clear_default=False, params=p)
    else:
        r = request(c, '/search', base='https://lyrics.kugou.com',
                    clear_default=True, not_sign=True, params=p)
    b = rpt(label, r)
    if isinstance(b, dict):
        cl = b.get('candidates') or []
        print('       candidates=%d' % len(cl))

print('\n===== 歌词下载 /download 三态（krc）=====')
for st in STATES:
    c = Ctx(st)
    for fmt in ('krc', 'lrc'):
        r = request(c, '/download', base='https://lyrics.kugou.com',
                    params={'ver': 1, 'client': 'android', 'id': 274944371,
                            'accesskey': '2A7B35884B3C20E9D3281686BA59A3F8',
                            'fmt': fmt, 'charset': 'utf8'})
        b = rpt('%-8s fmt=%s' % (st, fmt), r)
        if isinstance(b, dict):
            content = b.get('content') or ''
            print('       contenttype=%s len(content)=%s id=%s keys=%s' % (
                b.get('contenttype'), len(content), b.get('id'), list(b.keys())))

print('\n===== /download 带 decode 参数与不同 accesskey 校验 =====')
c = Ctx('anon')
for st in STATES:
    c = Ctx(st)
    # 用三态各自搜索到的候选测试
    pass
