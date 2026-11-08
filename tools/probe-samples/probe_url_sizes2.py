#!/usr/bin/env python3
"""用真实 hash（我喜欢第1首）实测 /v5/url 全曲 vs 试听的 URL/filesize/hash_offset。"""
import sys, json, time
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
from kg_probe import Ctx, request, sig_key
HASH = json.load(open('/tmp/like_playlist_5x10.json'))[0]['hashes'][0].lower()
print('probe hash:', HASH)
for state in ('vip', 'nonvip'):
    c = Ctx(state)
    for free in (0, 1):
        p = {'album_id': 0, 'area_code': 1, 'hash': HASH,
             'mid': c.mid, 'userid': c.userid, 'token': c.token,
             'dfid': c.dfid, 'appid': 1005, 'clientver': 20489,
             'clienttime': int(time.time()),
             'key': sig_key(HASH, c.mid, c.userid),
             'quality': '128', 'IsFreePart': free}
        r = request(c, '/v5/url', params=p, base='https://trackercdn.kugou.com')
        b = r.body if isinstance(r.body, dict) else {}
        urls = b.get('url') if isinstance(b.get('url'), list) else []
        print(state, 'free=', free, 'status=', b.get('status'),
              'err=', b.get('error_code'), 'errcode=', b.get('errcode'),
              'filesize=', b.get('filesize'), 'bitRate=', b.get('bitRate'),
              'url[0]=', (urls[0][:90] if urls else None),
              'hash_offset=', json.dumps(b.get('hash_offset'), ensure_ascii=False)[:240] if b.get('hash_offset') else None)
