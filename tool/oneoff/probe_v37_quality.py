#!/usr/bin/env python3
"""先搜一首真实歌拿 hash，再测各音质档位"""
import sys, json
import importlib.util
spec = importlib.util.spec_from_file_location('kgp', '/var/minis/workspace/TiernanMusic/tool/kg_probe.py')
kgp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kgp)

ctx = kgp.Ctx('nonvip')
r = kgp.request(ctx, '/v2/search/song', params={
    'keyword': '周杰伦 晴天', 'page': 1, 'pagesize': 3, 'platform': 'AndroidFilter',
    'iscorrection': 1, 'privilegefilter': 0, 'area_code': 1, 'dopicfull': 1,
}, base='https://complexsearch.kugou.com', encrypt='android')
songs = (r.body.get('data') or {}).get('lists') or []
if not songs:
    print('search fail:', r.summary()); sys.exit(1)
s = songs[0]
HASH = (s.get('FileHash') or '').lower()
ALBUM = s.get('AlbumID') or 0
MIX = s.get('MixSongID') or 0
print('song:', s.get('OriSongName'), 'hash=', HASH, 'album=', ALBUM, 'mix=', MIX)

QUALITIES = ['128','320','flac','high','super','viper_tape','viper_clear','viper_atmos',
             'multitrack','magic_piano','magic_acappella','magic_dj','magic_surnay',
             'magic_subwoofer','magic_ancient','sc','hires']

def song_url_params(ctx, q):
    h = HASH
    return {
        'album_id': ALBUM,
        'area_code': 1,
        'hash': h,
        'ssa_flag': 'is_fromtrack',
        'version': 11430,
        'page_id': 151369488,
        'quality': q,
        'album_audio_id': MIX,
        'behavior': 'play',
        'pid': 2,
        'cmd': 26,
        'pidversion': 3001,
        'IsFreePart': 0,
        'ppage_id': '463467626,350369493,788954147',
        'cdnBackup': 1,
        'module': '',
        'clientver': 11430,
        'key': kgp.sig_key(h, ctx.mid, ctx.userid if ctx.userid and ctx.userid != '0' else '0'),
    }

for state in ['anon','nonvip','vip']:
    c = kgp.Ctx(state)
    print('===== state=%s userid=%s =====' % (state, c.userid))
    for q in QUALITIES:
        params = song_url_params(c, q)
        try:
            rr = kgp.request(c, '/v5/url', params=params, method='GET',
                             base='https://trackercdn.kugou.com', encrypt='android')
            body = rr.body if isinstance(rr.body, dict) else {}
            urls = body.get('url') or []
            n = len(urls) if isinstance(urls, list) else 0
            if n:
                print('%-16s OK n=%s bitrate=%s ext=%r fallback=%s' % (
                    q, n, body.get('bitrate'), body.get('ext_name') or body.get('ext'),
                    body.get('quality_degradable')))
                print('    ', urls[0][:120])
            else:
                print('%-16s FAIL %s' % (q, rr.summary()))
        except Exception as e:
            print('%-16s EXC %s' % (q, e))
