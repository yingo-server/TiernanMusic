#!/usr/bin/env python3
"""三态 × 内容接口实测"""
import json, sys, collections
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
from kg_probe import request, Ctx, STATES

OUT = {}


def show(tag, r, depth_keys=3):
    if not isinstance(r.body, dict):
        print('  %-24s HTTP %s body=%r' % (tag, r.status, r.body[:200]))
        return
    b = r.body
    print('  %-24s http=%s status=%s err=%s/%s msg=%r' % (
        tag, r.status, b.get('status'), b.get('error_code'), b.get('errcode'),
        b.get('error') or b.get('error_msg') or b.get('errmsg') or b.get('info')))
    d = b.get('data')
    if isinstance(d, dict):
        print('     data keys: %s' % list(d.keys())[:18])
        for k in list(d.keys()):
            v = d[k]
            if isinstance(v, list):
                print('       data.%s : list[%d]' % (k, len(v)))
                if v and isinstance(v[0], dict):
                    print('         [0] %s' % list(v[0].keys())[:25])
            elif isinstance(v, dict):
                print('       data.%s : dict %s' % (k, list(v.keys())[:14]))
    elif isinstance(d, list):
        print('     data: list[%d]' % len(d))
        if d and isinstance(d[0], dict):
            print('       [0] %s' % list(d[0].keys())[:25])
    elif d is not None:
        print('     data: %r' % (repr(d)[:200],))


def run(name, fn, states=STATES, dump=None):
    print('\n=== %s ===' % name)
    for st in states:
        ctx = Ctx(st)
        try:
            r = fn(ctx)
        except Exception as e:
            print('  %-8s EXC %s' % (st, e))
            continue
        show('%-8s' % st, r)
        OUT.setdefault(name, {})[st] = {'status': r.status, 'body_head': None}
        if dump:
            dump(st, r)


# ---------- helpers for common test data ----------
def first_hash(ctx=None):
    """拿一首已知歌曲用于后续测试"""
    ctx = ctx or Ctx('anon')
    r = request(ctx, '/v2/search/song', params={
        'keyword': '周杰伦', 'page': 1, 'pagesize': 3, 'platform': 'AndroidFilter',
        'iscorrection': 1, 'privilegefilter': 0, 'area_code': 1, 'dopicfull': 1},
        xrouter='complexsearch.kugou.com')
    return r


def song_ctx():
    r = first_hash()
    items = r.body['data']['lists']
    return items[0]


def main():
    item = song_ctx()
    HASH = item.get('FileHash')
    AID = item.get('AlbumID')
    MIX = item.get('MixSongID') or item.get('Audioid')
    NAME = item.get('SongName')
    DUR = item.get('Duration')
    print('BASE SONG: %s hash=%s albumid=%s mixsongid=%s dur=%s' % (NAME, HASH, AID, MIX, DUR))
    print('ITEM KEYS: %s' % list(item.keys()))

    # ---------- 搜索 ----------
    run('search/song', lambda c: request(c, '/v2/search/song', params={
        'keyword': '周杰伦', 'page': 1, 'pagesize': 5, 'platform': 'AndroidFilter',
        'iscorrection': 1, 'privilegefilter': 0, 'area_code': 1, 'dopicfull': 1},
        xrouter='complexsearch.kugou.com'))
    run('search/special', lambda c: request(c, '/v1/search/special', params={
        'keyword': '周杰伦', 'page': 1, 'pagesize': 5, 'platform': 'AndroidFilter'},
        xrouter='complexsearch.kugou.com'))
    run('search/album', lambda c: request(c, '/v1/search/album', params={
        'keyword': '周杰伦', 'page': 1, 'pagesize': 5, 'platform': 'AndroidFilter',
        'iscorrection': 1, 'category': '1', 'sorttype': 0, 'searchsong': 0},
        xrouter='complexsearch.kugou.com'))
    run('search/mv', lambda c: request(c, '/v1/search/mv', params={
        'keyword': '周杰伦', 'page': 1, 'pagesize': 5, 'platform': 'AndroidFilter'},
        xrouter='complexsearch.kugou.com'))
    run('search/author', lambda c: request(c, '/v1/search/author', params={
        'keyword': '周杰伦', 'page': 1, 'pagesize': 5, 'platform': 'AndroidFilter'},
        xrouter='complexsearch.kugou.com'))

    # ---------- 歌词 ----------
    def lyric_search(c):
        return request(c, '/v1/search', base='https://lyrics.kugou.com',
                       clear_default=True, not_sign=True,
                       params={'album_audio_id': 0, 'appid': 1005, 'clientver': 20489,
                               'duration': DUR, 'hash': HASH, 'keyword': NAME,
                               'lrctxt': 1, 'man': 'no'})
    run('lyric/search', lyric_search)

    print('\n--- lyric search variations (anon) ---')
    c = Ctx('anon')
    variants = [
        ('baseline', dict()),
        ('with-UA-kugou', dict(extra_headers={'User-Agent': 'KugouMusic/20489'})),
        ('with-referer', dict(extra_headers={'Referer': 'https://www.kugou.com/'})),
        ('with-accept', dict(extra_headers={'Accept': '*/*', 'Accept-Encoding': 'identity'})),
        ('man=yes', dict(params_override={'man': 'yes'})),
        ('lrctxt=0', dict(params_override={'lrctxt': 0})),
        ('keyword-only', dict(only_kw=True)),
        ('android-params', dict(with_default=True)),
    ]
    for label, opt in variants:
        p = {'album_audio_id': 0, 'appid': 1005, 'clientver': 20489,
             'duration': DUR, 'hash': HASH, 'keyword': NAME, 'lrctxt': 1, 'man': 'no'}
        if opt.get('only_kw'):
            p = {'keyword': NAME, 'appid': 1005, 'clientver': 20489, 'lrctxt': 1, 'man': 'no'}
        if opt.get('params_override'):
            p.update(opt['params_override'])
        r = request(c, '/v1/search', base='https://lyrics.kugou.com',
                    clear_default=not opt.get('with_default'), not_sign=True,
                    params=p, extra_headers=opt.get('extra_headers'))
        show(label, r)

    # ---------- 评论 ----------
    run('comment/cmtlist', lambda c: request(c, '/mcomment/v1/cmtlist', method='POST', params={
        'ver': 6, 'mixsongid': MIX, 'need_show_image': 1, 'p': 1, 'pagesize': 10,
        'show_classify': 1, 'show_hotword_list': 1, 'extdata': '0',
        'code': 'fc4be23b4e972707f36b8a828a93ba8a'}))
    run('comment/count', lambda c: request(c, '/index.php', method='GET', encrypt='web',
        xrouter='sum.comment.service.kugou.com',
        params={'r': 'comments/getcommentsnum',
                'code': 'fc4be23b4e972707f36b8a828a93ba8a', 'hash': HASH}))

    # ---------- 首页 ----------
    run('yueku/recommend_v2', lambda c: request(c, '/v1/yueku/recommend_v2',
        xrouter='service.mobile.kugou.com',
        params={'operator': 7, 'plat': 0, 'type': 11, 'area_code': 1, 'req_multi': 1}))
    run('rank/list', lambda c: request(c, '/ocean/v6/rank/list',
        params={'plat': 2, 'withsong': 1, 'parentid': 0}))
    run('everyday_song_recommend', lambda c: request(c, '/everyday_song_recommend',
        method='POST', xrouter='everydayrec.service.kugou.com',
        params={'platform': 'ios'}))
    run('special_recommend', lambda c: request(c, '/v2/special_recommend',
        method='POST', xrouter='specialrec.service.kugou.com', params={}))


if __name__ == '__main__':
    main()
