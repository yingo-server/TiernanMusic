#!/usr/bin/env python3
"""三个真实歌单 × 3 页分页留样（VIP 态，原生直连）。

输出 /tmp/three_playlists.json：每页 hash 序列与分页字段，供用户裁定拼接规则。
"""
import json, sys
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
import kg_probe as k

ctx = k.Ctx('vip')

def hashes(body):
    d = body.get('data', body) if isinstance(body, dict) else {}
    lst = []
    if isinstance(d, dict):
        for key in ('info', 'songlist', 'songs', 'list'):
            if isinstance(d.get(key), list):
                lst = d[key]
                break
    elif isinstance(d, list):
        lst = d
    out = []
    for s in lst:
        if isinstance(s, dict):
            h = (s.get('hash') or s.get('Hash') or s.get('file_hash')
                 or s.get('album_audio_id') or s.get('audio_id')
                 or s.get('filename') or s.get('songname') or s.get('name'))
            out.append(str(h))
    return out, (d.get('count') if isinstance(d, dict) else None), (d.get('total') if isinstance(d, dict) else None)

# 拿用户歌单列表
r = k.request(ctx, '/v7/get_all_list',
              params={'plat': 1, 'userid': ctx.userid, 'token': ctx.token},
              data={'userid': ctx.userid, 'token': ctx.token,
                    'total_ver': 979, 'type': 2, 'page': 1, 'pagesize': 30},
              method='POST', xrouter='cloudlist.service.kugou.com')
lists = []
if isinstance(r.body, dict):
    d = r.body.get('data', {})
    if isinstance(d, dict) and isinstance(d.get('info'), list):
        lists = d['info']
print('user playlists:', [(x.get('listid'), x.get('name'), x.get('global_collection_id')) for x in lists if isinstance(x, dict)][:10])

OUT = {}
for i, item in enumerate(lists[:3]):
    if not isinstance(item, dict):
        continue
    lid = str(item.get('listid') or '')
    gid = str(item.get('global_collection_id') or '')
    label = 'user_%s' % lid
    pages = []
    for p in (1, 2, 3):
        rr = k.request(ctx, '/v4/get_list_all_file_v3',
                       params={'userid': ctx.userid, 'token': ctx.token},
                       data={'listid': lid, 'userid': ctx.userid,
                             'type': 0, 'page': p, 'pagesize': 5,
                             'area_code': 1, 'allplatform': 1,
                             'show_cover': 1, 'token': ctx.token},
                       method='POST', xrouter='cloudlist.service.kugou.com')
        b = rr.body if isinstance(rr.body, dict) else {}
        hs, cnt, tot = hashes(b)
        pages.append({'page': p, 'status': b.get('status'),
                      'error_code': b.get('error_code'),
                      'count': cnt, 'total': tot,
                      'hashes': hs})
    OUT[label] = {'listid': lid, 'gid': gid, 'name': item.get('name'),
                  'pages': pages}

json.dump(OUT, open('/tmp/three_playlists.json', 'w'), ensure_ascii=False, indent=1)
for label, pl in OUT.items():
    print('===', label, pl['name'], 'gid', pl['gid'])
    for pg in pl['pages']:
        print(' page', pg['page'], 'status', pg['status'], 'err', pg['error_code'],
              'count', pg['count'], 'len', len(pg['hashes']))
        print('   ', pg['hashes'])
print('saved /tmp/three_playlists.json')
