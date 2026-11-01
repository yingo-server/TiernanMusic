#!/usr/bin/env python3
"""第3顺位：播放/评论/MV/权益类接口原生域名实测（匿名 + VIP）。

模块对应：
  song_url.js        → trackercdn.kugou.com  /v5/url
  privilege_lite.js  → media.store.kugou.com /v2/get_res_privilege/lite
  comment_music.js   → 无 x-router，默认 gateway.kugou.com /mcomment/v1/cmtlist
  comment_floor.js   → mcomment / m.comment.service（均无独立 baseURL，走 gateway）
  comment_count.js   → sum.comment.service.kugou.com /index.php?r=comments/getcommentsnum (web 签名)
  kmr_audio_mv.js    → openapi.kugou.com /kmr/v1/audio/mv
  video_url.js       → trackermv.kugou.com /v2/interface/index
  video_detail.js    → kmr.service.kugou.com /v1/video
"""
import json, sys, time, hashlib
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
from kg_probe import Ctx, request, md5, ANDROID_SALT

SONG = {'hash': 'B6ED2F5D161AF9C1BD3C1D6F13BED3E8', 'album_id': 3765762,
        'mixsongid': 498926161, 'album_audio_id': 498926161}
VIDEO_HASH = '94D3B7AB47E3D40C15AB935DB6D33A25'
VIDEO_ID = '9484796'

def paramskey(dt_s, appid=1005, clientver=20489):
    return hashlib.md5(('%s%s%s%s' % (appid, ANDROID_SALT, clientver, dt_s)).encode()).hexdigest()

def probe(ctx, name, method, host, path, params=None, data=None, xrouter=None,
          encrypt='android', clear=False, not_sign=False, extra_headers=None,
          desc=''):
    print('== [%s][%s] %s %s%s %s' % (ctx.state, name, host, path, ' ' + desc if desc else '', '(x-router=%s)' % xrouter if xrouter else ''))
    try:
        r = request(ctx, path, params=params, data=data, method=method,
                    base='https://' + host if host else None or 'https://gateway.kugou.com',
                    xrouter=xrouter, encrypt=encrypt, clear_default=clear,
                    not_sign=not_sign, extra_headers=extra_headers)
    except TypeError:
        # host None 走 gateway
        r = request(ctx, path, params=params, data=data, method=method,
                    xrouter=xrouter, encrypt=encrypt, clear_default=clear,
                    not_sign=not_sign, extra_headers=extra_headers)
    print('   ' + r.summary())
    return r

def run(state):
    ctx = Ctx(state)
    print('\n########## state = %s (userid=%s) ##########' % (state, ctx.userid))

    # ---- 1. song_url：trackercdn 直连 ----
    probe(ctx, 'song_url', 'GET', 'trackercdn.kugou.com', '/v5/url', params={
        'album_id': SONG['album_id'], 'area_code': 1, 'hash': SONG['hash'].lower(),
        'ssa_flag': 'is_fromtrack', 'version': 11430, 'page_id': 151369488,
        'quality': 128, 'album_audio_id': SONG['album_audio_id'],
        'behavior': 'play', 'pid': 2, 'cmd': 26, 'pidversion': 3001,
        'IsFreePart': 1, 'ppage_id': '463467626,350369493,788954147',
        'cdnBackup': 1, 'module': '', 'clientver': 11430})
    # 对照：gateway x-router
    probe(ctx, 'song_url(gw)', 'GET', None, '/v5/url', params={
        'album_id': SONG['album_id'], 'area_code': 1, 'hash': SONG['hash'].lower(),
        'ssa_flag': 'is_fromtrack', 'version': 11430, 'page_id': 151369488,
        'quality': 128, 'album_audio_id': SONG['album_audio_id'],
        'behavior': 'play', 'pid': 2, 'cmd': 26, 'pidversion': 3001,
        'IsFreePart': 1, 'ppage_id': '463467626,350369493,788954147',
        'cdnBackup': 1, 'module': '', 'clientver': 11430},
        xrouter='trackercdn.kugou.com')

    # ---- 2. privilege/lite：media.store 直连 ----
    probe(ctx, 'privilege', 'POST', 'media.store.kugou.com', '/v2/get_res_privilege/lite', data={
        'appid': 1005, 'area_code': 1, 'behavior': 'play', 'clientver': 20489,
        'need_hash_offset': 1, 'relate': 1, 'support_verify': 1,
        'resource': [{'type': 'audio', 'page_id': 0, 'hash': SONG['hash'].lower(),
                      'album_id': SONG['album_id']}],
        'qualities': ['128', '320', 'flac', 'high', 'viper_atmos', 'viper_tape',
                      'viper_clear', 'super', 'multitrack']})
    probe(ctx, 'privilege(gw)', 'POST', None, '/v2/get_res_privilege/lite', data={
        'appid': 1005, 'area_code': 1, 'behavior': 'play', 'clientver': 20489,
        'need_hash_offset': 1, 'relate': 1, 'support_verify': 1,
        'resource': [{'type': 'audio', 'page_id': 0, 'hash': SONG['hash'].lower(),
                      'album_id': SONG['album_id']}],
        'qualities': ['128', '320', 'flac', 'high', 'viper_atmos', 'viper_tape',
                      'viper_clear', 'super', 'multitrack']},
        xrouter='media.store.kugou.com')

    # ---- 3. comment/music：无 x-router（gateway 本身即原生域名），验证 gateway 直打 ----
    probe(ctx, 'comment_music', 'POST', 'gateway.kugou.com', '/mcomment/v1/cmtlist', params={
        'ver': 6, 'mixsongid': SONG['mixsongid'], 'need_show_image': 1, 'p': 1,
        'pagesize': 5, 'show_classify': 1, 'show_hotword_list': 1,
        'extdata': '0', 'code': 'fc4be23b4e972707f36b8a828a93ba8a'})

    # ---- 4. comment/floor：song 走 mcomment；playlist/album 走 m.comment.service（gateway 路由）----
    probe(ctx, 'comment_floor(song)', 'POST', 'gateway.kugou.com', '/mcomment/v1/hot_replylist', params={
        'need_show_image': 1, 'p': 1, 'pagesize': 5, 'show_classify': 1,
        'show_hotword_list': 1, 'code': 'fc4be23b4e972707f36b8a828a93ba8a',
        'mixsongid': SONG['mixsongid'], 'tid': 0})
    probe(ctx, 'comment_floor(svc)', 'POST', None, '/m.comment.service/v1/hot_replylist', params={
        'childrenid': 0, 'need_show_image': 1, 'p': 1, 'pagesize': 5,
        'show_classify': 1, 'show_hotword_list': 1,
        'code': 'ca53b96fe5a1d9c22d71c8f522ef7c4f', 'tid': 0})

    # ---- 5. comment/count：sum.comment.service 直连（web 签名）----
    probe(ctx, 'comment_count', 'GET', 'sum.comment.service.kugou.com', '/index.php', params={
        'r': 'comments/getcommentsnum', 'code': 'fc4be23b4e972707f36b8a828a93ba8a',
        'hash': SONG['hash']}, encrypt='web')

    # ---- 6. kmr/audio/mv：openapi.kugou.com 直连 ----
    probe(ctx, 'kmr_audio_mv', 'POST', 'openapi.kugou.com', '/kmr/v1/audio/mv', data={
        'data': [{'mixsongid': SONG['mixsongid']}], 'fields': ''},
        extra_headers={'KG-TID': '38'})
    probe(ctx, 'kmr_audio_mv(gw)', 'POST', None, '/kmr/v1/audio/mv', data={
        'data': [{'mixsongid': SONG['mixsongid']}], 'fields': ''},
        xrouter='openapi.kugou.com', extra_headers={'KG-TID': '38'})

    # ---- 7. video/url：trackermv 直连 ----
    probe(ctx, 'video_url', 'GET', 'trackermv.kugou.com', '/v2/interface/index', params={
        'backupdomain': 1, 'cmd': 123, 'ext': 'mp4', 'ismp3': 0,
        'hash': VIDEO_HASH, 'pid': 1, 'type': 1})
    probe(ctx, 'video_url(gw)', 'GET', None, '/v2/interface/index', params={
        'backupdomain': 1, 'cmd': 123, 'ext': 'mp4', 'ismp3': 0,
        'hash': VIDEO_HASH, 'pid': 1, 'type': 1}, xrouter='trackermv.kugou.com')

    # ---- 8. video/detail：kmr.service 直连（三标签域名，重点 TLS）----
    dt = str(int(time.time()))
    probe(ctx, 'video_detail', 'POST', 'kmr.service.kugou.com', '/v1/video', data={
        'appid': 1005, 'clientver': 20489, 'clienttime': int(dt), 'mid': ctx.mid,
        'uuid': md5('-%s' % ctx.mid), 'dfid': '-', 'token': ctx.token,
        'key': paramskey(dt), 'show_resolution': 1,
        'data': [{'video_id': VIDEO_ID}]}, clear=True, not_sign=True)
    probe(ctx, 'video_detail(gw)', 'POST', None, '/v1/video', data={
        'appid': 1005, 'clientver': 20489, 'clienttime': int(dt), 'mid': ctx.mid,
        'uuid': md5('-%s' % ctx.mid), 'dfid': '-', 'token': ctx.token,
        'key': paramskey(dt), 'show_resolution': 1,
        'data': [{'video_id': VIDEO_ID}]}, clear=True, not_sign=True,
        xrouter='kmr.service.kugou.com')

if __name__ == '__main__':
    states = sys.argv[1:] or ['anon', 'vip']
    for s in states:
        run(s)
