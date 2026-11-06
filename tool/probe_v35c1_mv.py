#!/usr/bin/env python3
"""v3.5 C1 原生实测：/kmr/audio/mv 缩略图字段与 {size} 档位验证（第 33 条）"""
import sys, json
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
import kg_probe as P

ctx = P.Ctx('anon')

# 1) 已知热门歌曲（周杰伦 晴天 album_audio_id 实测值，若无效则用搜索换取）
# 先用移动端搜索直连接口拿一首歌的 album_audio_id
s = P.request(ctx, '/search', params={'keyword': '晴天 周杰伦', 'type': 'song', 'pagesize': 3},
              xrouter='searchservice.kugou.com', clear_default=True)
print('search:', s.summary())
aaid = None
try:
    d = s.body.get('data', {})
    lists = d.get('lists') or []
    for it in lists:
        info = it.get('info', it)
        aid = str(info.get('album_audio_id') or info.get('mixsongid') or '')
        if aid and aid != '0':
            aaid = aid
            print('candidate:', aid, info.get('songname'), info.get('filename'))
            break
except Exception as e:
    print('parse search fail', e)

if not aaid:
    print('NO album_audio_id, abort')
    sys.exit(0)

r = P.request(ctx, '/kmr/audio/mv',
              params={'album_audio_id': aaid, 'fields': 'mkv,tags,h264,h265'},
              xrouter='kmrservice.kugou.com', clear_default=True)
print('kmr:', r.summary())
try:
    data = r.body.get('data')
    items = []
    if isinstance(data, list):
        for g in data:
            if isinstance(g, list):
                items.extend([x for x in g if isinstance(x, dict)])
            elif isinstance(g, dict):
                items.append(g)
    if not items:
        print('kmr data empty or shape:', json.dumps(r.body)[:300])
    for it in items[:2]:
        print('--- item keys:', sorted(it.keys()))
        print('mv_name:', it.get('mv_name'))
        print('video_id:', it.get('video_id'))
        print('duration(ms):', it.get('duration'))
        print('thumb:', it.get('thumb'))
        print('hdpic:', it.get('hdpic'))
        print('authors:', [a.get('author_name') for a in (it.get('authors') or []) if isinstance(a, dict)])
        print('h264 keys:', sorted((it.get('h264') or {}).keys()) if isinstance(it.get('h264'), dict) else it.get('h264'))
        print('mkv keys:', sorted((it.get('mkv') or {}).keys()) if isinstance(it.get('mkv'), dict) else it.get('mkv'))
except Exception as e:
    print('parse fail', e, json.dumps(r.body)[:400])

# 2) 验证缩略图 URL 拼接档位 320 是否真实可取
th = None
try:
    th = items[0].get('thumb') if items else None
except Exception:
    pass
if th:
    import urllib.request
    for size in (240, 320, 480, 720):
        u = th.replace('{size}', str(size))
        if not u.startswith('http'):
            u = 'http://imge.kugou.com/mvthumb/%s/%s' % (size, u)
        if u.startswith('http://'):
            u = 'https://' + u[7:]
        try:
            req = urllib.request.Request(u, method='HEAD', headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=10) as resp:
                print('thumb HEAD %s -> %s len=%s' % (size, resp.status, resp.headers.get('Content-Length')))
        except Exception as e:
            print('thumb HEAD %s FAIL: %s' % (size, e))
else:
    print('no thumb to verify')
