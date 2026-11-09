#!/usr/bin/env python3
"""补测：song_url / video_url 加 key 参数；取真实 hash；comment_floor 用真实 tid。"""
import json, sys, urllib.request, gzip
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
from kg_probe import Ctx, request, sig_key

def kapi(path):
    with urllib.request.urlopen('https://kapi.344977.xyz/' + path, timeout=25) as r:
        raw = r.read()
        if r.headers.get('Content-Encoding') == 'gzip':
            raw = gzip.decompress(raw)
        return json.loads(raw)

# 真实歌曲
d = kapi('search?keywords=%E6%99%B4%E5%A4%A9&type=song')
s = d['data']['lists'][0]
HASH = s['FileHash']; ALBUM = s['AlbumID']; MIX = s['MixSongID']
print('song:', HASH, ALBUM, MIX, s.get('OriSongName'))

# 真实 MV
m = kapi('search?keywords=%E5%91%A8%E6%9D%B0%E4%BC%A6&type=mv')
mv = m['data']['lists'][0]
MVHASH = mv.get('MvHash') or mv.get('FileHash')
print('mv:', mv.get('MvName'), 'hash=', MVHASH, json.dumps(mv)[:300])

def probe(ctx, name, host, path, params, xrouter=None, method='GET'):
    try:
        r = request(ctx, path, params=params, method=method,
                    base='https://' + host if host else 'https://gateway.kugou.com',
                    xrouter=xrouter)
    except Exception as e:
        print('== [%s][%s] EXC %s' % (ctx.state, name, e)); return None
    print('== [%s][%s] %s%s %s' % (ctx.state, name, host, path, '(x-router)' if xrouter else ''))
    print('   ' + r.summary())
    return r

for state in (sys.argv[1:] or ['anon', 'vip']):
    ctx = Ctx(state)
    print('\n##### %s (userid=%s) #####' % (state, ctx.userid))
    p = {'album_id': int(ALBUM), 'area_code': 1, 'hash': HASH.lower(),
         'ssa_flag': 'is_fromtrack', 'version': 11430, 'page_id': 151369488,
         'quality': 128, 'album_audio_id': int(MIX), 'behavior': 'play',
         'pid': 2, 'cmd': 26, 'pidversion': 3001, 'IsFreePart': 1,
         'ppage_id': '463467626,350369493,788954147', 'cdnBackup': 1,
         'module': '', 'clientver': 11430}
    p['key'] = sig_key(HASH.lower(), ctx.mid, ctx.userid)
    r1 = probe(ctx, 'song_url', 'trackercdn.kugou.com', '/v5/url', p)
    r2 = probe(ctx, 'song_url(gw)', None, '/v5/url', p, xrouter='trackercdn.kugou.com')
    for r in (r1, r2):
        if r and isinstance(r.body, dict) and r.body.get('url'):
            print('   url[0]=', str(r.body['url'])[:100], ' backupUrl len=', len(r.body.get('backupUrl') or []))

    vp = {'backupdomain': 1, 'cmd': 123, 'ext': 'mp4', 'ismp3': 0,
          'hash': MVHASH, 'pid': 1, 'type': 1}
    vp['key'] = sig_key(MVHASH, ctx.mid, ctx.userid)
    rv = probe(ctx, 'video_url', 'trackermv.kugou.com', '/v2/interface/index', vp)
    rvg = probe(ctx, 'video_url(gw)', None, '/v2/interface/index', vp, xrouter='trackermv.kugou.com')
    for r in (rv, rvg):
        if r and isinstance(r.body, dict):
            dd = r.body.get('data') or {}
            ent = dd.get(MVHASH.lower()) if isinstance(dd, dict) else None
            if ent:
                print('   downurl=', str(ent.get('downurl'))[:90])
                print('   backup=', str(ent.get('backupdownurl'))[:90])

    # comment_floor 真实 tid：先取 comment/music 首条 id
    try:
        cm = kapi('comment/music?mixsongid=%s&pagesize=5' % MIX)
        tid = cm['data']['list'][0]['id']
        print('tid =', tid)
        probe(ctx, 'comment_floor(song)', 'gateway.kugou.com', '/mcomment/v1/hot_replylist', {
            'need_show_image': 1, 'p': 1, 'pagesize': 5, 'show_classify': 1,
            'show_hotword_list': 1, 'code': 'fc4be23b4e972707f36b8a828a93ba8a',
            'mixsongid': MIX, 'tid': tid}, method='POST')
    except Exception as e:
        print('comment_floor tid fetch fail:', e)
