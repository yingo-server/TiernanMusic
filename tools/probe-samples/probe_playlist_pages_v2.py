#!/usr/bin/env python3
"""歌单分页实测 v2：与 Dart 客户端完全同形态（page 只放 body / query 无 page）。

三歌单：①公共歌单 detail ②公共歌单 tracks ③用户歌单 tracks。
每歌单取 3 页，记录 hash 全序列与分页字段，供用户裁定拼接规则。
"""
import json, sys
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
import kg_probe as k

ctx = k.Ctx('vip')
OUT = {}

def hashes_of(body):
    data = body.get('data', body) if isinstance(body, dict) else {}
    songs = []
    if isinstance(data, dict):
        for key in ('songlist', 'info', 'songs', 'list', 'candidates', 'data'):
            v = data.get(key)
            if isinstance(v, list):
                songs = v
                break
    elif isinstance(data, list):
        songs = data
    hs = []
    for s in songs:
        if isinstance(s, dict):
            h = (s.get('hash') or s.get('Hash') or s.get('file_hash')
                 or s.get('mv_hash') or s.get('audio_id')
                 or s.get('album_audio_id') or s.get('name')
                 or s.get('filename') or s.get('songname'))
            hs.append(str(h))
    return hs, data

def probe(label, path, base, xrouter, method, build_params, build_data, pagekey):
    rows = []
    for p in (1, 2, 3):
        params = build_params(p)
        data = build_data(p)
        r = k.request(ctx, path, params=params, data=data, method=method,
                      base=base, xrouter=xrouter)
        body = r.body if isinstance(r.body, dict) else {}
        hs, data_obj = hashes_of(body)
        rows.append({
            'page': p,
            'status': body.get('status'),
            'error_code': body.get('error_code', body.get('errcode')),
            'count': body.get('count') or (data_obj.get('count') if isinstance(data_obj, dict) else None),
            'total': body.get('total') or (data_obj.get('total') if isinstance(data_obj, dict) else None),
            'len': len(hs), 'hashes': hs,
        })
    OUT[label] = rows

# ① 公共歌单详情 /v3/get_list_info：data 数组，无 page 概念——只取 1 次做对照
r = k.request(ctx, '/v3/get_list_info',
              params={'userid': ctx.userid, 'token': ctx.token},
              data={'data': [{'global_collection_id': 'collection_3_1666835066_1_0'}],
                    'userid': ctx.userid, 'token': ctx.token},
              method='POST', base='https://pubsongs.kugou.com')
OUT['public_detail'] = {
    'status': r.body.get('status') if isinstance(r.body, dict) else None,
    'error_code': r.body.get('error_code') if isinstance(r.body, dict) else None,
    'keys': list(r.body.keys())[:10] if isinstance(r.body, dict) else [],
}

# ② 公共歌单歌曲：/v2/get_other_list_file_nofilt，page 放 body? Dart 放 query，实测两种
def pub_q(p):
    return {'area_code': 1, 'plat': 1, 'type': 1, 'mode': 1,
            'personal_switch': 1,
            'extend_fields': 'abtags,hot_cmt,popularization',
            'global_collection_id': 'collection_3_1666835066_1_0',
            'pagesize': 5, 'begin_idx': (p - 1) * 5}
probe('public_tracks_query', '/v2/get_other_list_file_nofilt', 'https://pubsongs.kugou.com',
      None, 'GET', pub_q, lambda p: None, 'begin_idx')

def pub_d(p):
    return {'listid': 'collection_3_1666835066_1_0',
            'userid': ctx.userid, 'type': 1, 'page': p, 'pagesize': 5,
            'area_code': 1, 'allplatform': 1, 'show_cover': 1,
            'token': ctx.token}
probe('public_tracks_body', '/v2/get_other_list_file_nofilt', 'https://pubsongs.kugou.com',
      None, 'POST', lambda p: {'userid': ctx.userid, 'token': ctx.token},
      pub_d, 'page')

# ③ 用户歌单歌曲：/v4/get_list_all_file_v3（与 Dart 完全一致：page 在 body）
def usr_d(p):
    return {'listid': '1', 'userid': ctx.userid, 'type': 0, 'page': p,
            'pagesize': 5, 'area_code': 1, 'allplatform': 1,
            'show_cover': 1, 'token': ctx.token}
probe('user_tracks', '/v4/get_list_all_file_v3', k.GATEWAY,
      'cloudlist.service.kugou.com', 'POST',
      lambda p: {'userid': ctx.userid, 'token': ctx.token}, usr_d, 'page')

json.dump(OUT, open('/tmp/playlist_pages_v2.json', 'w'), ensure_ascii=False, indent=1)
print('detail:', OUT['public_detail'])
for k2, rows in OUT.items():
    if not isinstance(rows, list):
        continue
    print('===', k2)
    for pg in rows:
        print(' page', pg['page'], 'status', pg['status'], 'err', pg['error_code'],
              'count', pg['count'], 'total', pg['total'], 'len', pg['len'])
        print('   head', pg['hashes'][:5])
        print('   tail', pg['hashes'][-3:])
print('saved /tmp/playlist_pages_v2.json')
