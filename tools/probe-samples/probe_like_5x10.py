#!/usr/bin/env python3
"""「我喜欢」(listid=2) 每页 10 首 × 5 页，直连 VIP 态，打印歌名，观察拼接。"""
import json, sys
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
import kg_probe as k

ctx = k.Ctx('vip')
PAGES = 5
SIZE = 10

def name_of(s):
    # 优先纯歌名，其次 filename（常为「歌手 - 歌名」）
    for key in ('songname', 'song_name', 'name', 'filename', 'file_name', 'remark'):
        v = s.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return '(无歌名:%s)' % (s.get('hash') or '?')

all_pages = []
for p in range(1, PAGES + 1):
    r = k.request(ctx, '/v4/get_list_all_file_v3',
                  params={'userid': ctx.userid, 'token': ctx.token},
                  data={'listid': '2', 'userid': ctx.userid, 'type': 0,
                        'page': p, 'pagesize': SIZE, 'area_code': 1,
                        'allplatform': 1, 'show_cover': 1,
                        'token': ctx.token},
                  method='POST', xrouter='cloudlist.service.kugou.com')
    b = r.body if isinstance(r.body, dict) else {}
    d = b.get('data', {})
    info = d.get('info') if isinstance(d, dict) else []
    if not isinstance(info, list):
        info = []
    names = [name_of(s) for s in info if isinstance(s, dict)]
    hashes = [str(s.get('hash') or '') for s in info if isinstance(s, dict)]
    all_pages.append({'page': p, 'status': b.get('status'),
                      'error_code': b.get('error_code'),
                      'count': d.get('count') if isinstance(d, dict) else None,
                      'names': names, 'hashes': hashes})

for pg in all_pages:
    print('===== 第 %d 页 (status=%s err=%s 总数count=%s 本页%d首) =====' % (
        pg['page'], pg['status'], pg['error_code'], pg['count'], len(pg['names'])))
    for i, n in enumerate(pg['names'], 1):
        print('  %2d. %s' % (i, n))
    print()

flat = [n for pg in all_pages for n in pg['names']]
print('===== 按 page 升序直接拼接后的前 50 首（当前客户端做法）=====')
for i, n in enumerate(flat, 1):
    print('  %2d. %s' % (i, n))

hs = [h for pg in all_pages for h in pg['hashes']]
print()
print('拼接总条数:', len(flat), '| 去重后:', len(set(hs)), '| 跨页重叠:', len(hs) - len(set(hs)))
json.dump(all_pages, open('/tmp/like_playlist_5x10.json', 'w'), ensure_ascii=False, indent=1)
print('留样 /tmp/like_playlist_5x10.json')
