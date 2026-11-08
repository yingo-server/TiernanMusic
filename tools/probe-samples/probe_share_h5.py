#!/usr/bin/env python3
"""复刻分享页 H5 取数：appid=1058 module=playlist pagesize=20 page 递增 concat。
打印前 30 / 后 30 与 485 留样对照（不反复请求其他 API）。
"""
import json, sys, urllib.parse, urllib.request
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
import kg_probe as k

GID = 'collection_3_1666835066_2_0'
BASE = 'https://gateway.kugou.com/kmr/v1/album_songlist'
UA = ('Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 '
      'Chrome/120 Mobile Safari/537.36')

def call(page, size=20):
    # H5 分享页参数：appid/type/module/page/pagesize/global_collection_id
    params = {'appid': 1058, 'type': 0, 'module': 'playlist',
              'page': page, 'pagesize': size,
              'global_collection_id': GID}
    # 先尝试 GET（H5 网关常见形态），失败再试 POST
    url = BASE + '?' + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={'User-Agent': UA,
                                                 'Referer': 'https://activity.kugou.com/'})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
    except Exception as e:
        return {'error': str(e)}
    try:
        return json.loads(raw.decode('utf-8', 'replace'))
    except Exception:
        return {'error': 'non-json', 'raw': raw[:200]}

def name(s):
    for key in ('songname', 'name', 'filename', 'file_name', 'fileName', 'remark'):
        v = s.get(key) if isinstance(s, dict) else None
        if isinstance(v, str) and v.strip():
            return v.strip()
    return '(无名)'

out = []
for p in (1, 2, 3):
    b = call(p)
    out.append({'page': p, 'body_keys': list(b.keys())[:8],
                'status': b.get('status'),
                'error_code': b.get('error_code', b.get('errcode')),
                'data': b.get('data') if isinstance(b, dict) else None})
    info = []
    d = b.get('data')
    if isinstance(d, dict):
        for key in ('info', 'list', 'songlist', 'songs'):
            if isinstance(d.get(key), list):
                info = d[key]
                break
    elif isinstance(d, list):
        info = d
    names = [name(s) for s in info]
    print('=== page %d: keys=%s status=%s err=%s len=%d' % (
        p, out[-1]['body_keys'], out[-1]['status'],
        out[-1]['error_code'], len(names)))
    for i, n in enumerate(names[:30], 1):
        print(' %2d. %s' % (i, n))
    print()

json.dump(out, open('/tmp/share_h5_probe.json', 'w'), ensure_ascii=False, indent=1)
print('saved /tmp/share_h5_probe.json')
