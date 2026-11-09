#!/usr/bin/env python3
"""v3.5 C1 原生实测②：/kmr/audio/mv 直连（重试多 x-router 变体）"""
import sys, json
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
import kg_probe as P

ctx = P.Ctx('anon')

# 换用 web 网关搜索（ mobilecdn ）
s = P.request(ctx, '/api/v3/search/song',
              params={'keyword': '晴天', 'pagesize': 3, 'page': 1},
              base='https://mobiles.kugou.com', clear_default=True, encrypt='web')
print('search:', s.summary(), json.dumps(s.body)[:200] if isinstance(s.body, dict) else '')
aaid = None
if isinstance(s.body, dict):
    for it in (s.body.get('data', {}).get('lists') or [])[:5]:
        info = it.get('info', it) if isinstance(it, dict) else {}
        aid = str(info.get('album_audio_id') or info.get('mixsongid') or '')
        if aid and aid != '0':
            aaid = aid; break

if not aaid:
    # 兜底：已知晴天 album_audio_id=2320905（如有误则弃用）
    aaid = '2320905'
    print('fallback aaid', aaid)

for xr in ('kmrservice.kugou.com', None):
    if xr:
        r = P.request(ctx, '/kmr/audio/mv',
                      params={'album_audio_id': aaid, 'fields': 'mkv,tags,h264,h265'},
                      xrouter=xr, clear_default=True)
    else:
        r = P.request(ctx, '/kmr/audio/mv',
                      params={'album_audio_id': aaid, 'fields': 'mkv,tags,h264,h265'},
                      base='https://kmrservice.kugou.com', clear_default=True)
    print('kmr via %s:' % xr, r.summary())
    if isinstance(r.body, dict) and r.body.get('status') == 1:
        break
