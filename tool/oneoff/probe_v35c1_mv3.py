#!/usr/bin/env python3
"""v3.5 C1 原生实测③：kmr/audio/mv 走 openapi.kugou.com + KG-TID:38，POST body"""
import sys, json, urllib.request
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
import kg_probe as P

ctx = P.Ctx('anon')
aaid = '2320905'

r = P.request(ctx, '/kmr/v1/audio/mv',
              method='POST',
              data={'data': [{'album_audio_id': aaid}], 'fields': 'mkv,tags,h264,h265'},
              base='https://openapi.kugou.com',
              clear_default=True,
              extra_headers={'KG-TID': '38'})
print('kmr openapi:', r.summary())
data = r.body.get('data') if isinstance(r.body, dict) else None
items = []
if isinstance(data, list):
    for g in data:
        if isinstance(g, list): items += [x for x in g if isinstance(x, dict)]
        elif isinstance(g, dict): items.append(g)
print('items:', len(items))
for it in items[:2]:
    print('--- keys:', sorted(it.keys()))
    print('mv_name:', it.get('mv_name'), '| video_id:', it.get('video_id'), '| duration:', it.get('duration'))
    print('thumb:', it.get('thumb'))
    print('hdpic:', it.get('hdpic'))
    print('authors:', [a.get('author_name') for a in (it.get('authors') or []) if isinstance(a, dict)])
    h = it.get('h264'); m = it.get('mkv')
    print('h264 keys:', sorted(h.keys()) if isinstance(h, dict) else h)
    print('mkv keys:', sorted(m.keys()) if isinstance(m, dict) else m)

if items:
    th = items[0].get('thumb') or items[0].get('hdpic')
    if th:
        for size in (240, 320, 480, 720):
            u = str(th).replace('{size}', str(size))
            if not u.startswith('http'):
                u = 'http://imge.kugou.com/mvthumb/%s/%s' % (size, u)
            if u.startswith('http://'):
                u = 'https://' + u[7:]
            try:
                req = urllib.request.Request(u, method='HEAD', headers={'User-Agent': 'Mozilla/5.0'})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    print('thumb %s -> %s len=%s type=%s' % (size, resp.status, resp.headers.get('Content-Length'), resp.headers.get('Content-Type')))
            except Exception as e:
                print('thumb %s FAIL: %s' % (size, e))
