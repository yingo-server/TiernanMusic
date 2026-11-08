#!/usr/bin/env python3
"""复刻 lib/core/direct/*.dart 的直连逻辑（仅 urllib，无 requests）"""
import hashlib, json, time, uuid as uuidmod, urllib.request, urllib.parse, http.cookiejar, sys, os, gzip, io

ANDROID_SALT = 'OIlwieks28dk2k092lksi2UIkp'
WEB_SALT = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt'
SIGNKEY_SALT = '57ae12eb6890223e355ccfcb74edf70d'
APPID = 1005
CLIENTVER = 20489
GATEWAY = 'https://gateway.kugou.com'

UA = 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi'


def md5(s):
    return hashlib.md5(s.encode('utf-8')).hexdigest()


def calc_mid(guid):
    d = md5(guid)
    v = 0
    n = len(d)
    for i, ch in enumerate(d):
        v = v + int(ch, 16) * (16 ** (n - 1 - i))
    return str(v)


def sig_android(params, data=''):
    ks = sorted(params.keys())
    s = ''.join('%s=%s' % (k, json.dumps(params[k], separators=(',', ':')) if isinstance(params[k], (dict, list)) else params[k]) for k in ks)
    return md5(ANDROID_SALT + s + data + ANDROID_SALT)


def sig_web(params, data=''):
    ks = sorted(params.keys())
    s = ''.join('%s=%s' % (k, params[k]) for k in ks)
    return md5(WEB_SALT + s + data + WEB_SALT)


def sig_key(hash_, mid, userid='0'):
    return md5('%s%s%s%s%s' % (hash_, SIGNKEY_SALT, APPID, mid, userid))


class Ctx:
    """三种状态上下文"""

    def __init__(self, state):
        self.state = state
        path = None
        if state == 'nonvip':
            path = '/var/minis/workspace/.test_creds/cj_nonvip.txt'
        elif state == 'vip':
            path = '/var/minis/workspace/.test_creds/cj_vip.txt'
        self.cookie_path = path
        # 从 cookie 文件读 userid / token（kapi 域名，但值可直接用于直连）
        self.userid = '0'
        self.token = ''
        self.mid = '281949768489412648962353822266799178366'
        self.dfid = '-'
        if path:
            for line in open(path):
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                parts = line.split('\t')
                if len(parts) >= 7:
                    name, val = parts[5], parts[6]
                    if name == 'userid' and val:
                        self.userid = val
                    elif name == 'token' and val:
                        self.token = val
                    elif name == 'KUGOU_API_MID' and val:
                        self.mid = val


class Raw:
    def __init__(self, status, body, headers, url):
        self.status, self.body, self.headers, self.url = status, body, headers, url

    @property
    def code(self):
        if isinstance(self.body, dict):
            v = self.body.get('error_code', self.body.get('errcode', 0))
            try:
                return int(v)
            except Exception:
                return 0
        return 0

    def summary(self):
        if not isinstance(self.body, dict):
            return 'HTTP %s non-json: %r' % (self.status, self.body[:120])
        b = self.body
        return 'http=%s status=%s errcode=%s errmsg=%r keys=%s' % (
            self.status, b.get('status'),
            b.get('error_code', b.get('errcode')),
            b.get('error') or b.get('error_msg') or b.get('errmsg') or b.get('info'),
            list(b.keys())[:12])


def request(ctx, path, params=None, data=None, method='GET',
            base=GATEWAY, xrouter=None, encrypt='android',
            clear_default=False, not_sign=False, extra_headers=None,
            cookies=True, timeout=25):
    params = dict(params or {})
    now = int(time.time())
    if not clear_default:
        base_params = {
            'dfid': ctx.dfid,
            'mid': ctx.mid,
            'uuid': '-',
            'appid': APPID,
            'clientver': CLIENTVER,
            'clienttime': now,
        }
        if ctx.token:
            base_params['token'] = ctx.token
        if ctx.userid and ctx.userid != '0':
            base_params['userid'] = ctx.userid
        for k, v in params.items():
            base_params[k] = v
        params = base_params

    body_str = ''
    if data is not None:
        body_str = data if isinstance(data, str) else json.dumps(data, separators=(',', ':'))

    if 'signature' not in params and not not_sign:
        if encrypt == 'web':
            params['signature'] = sig_web(params, body_str)
        else:
            params['signature'] = sig_android(params, body_str)

    qs = '&'.join('%s=%s' % (urllib.parse.quote(str(k), safe=''), urllib.parse.quote(str(v), safe='')) for k, v in params.items())
    url = base + path + (('?' + qs) if qs else '')

    headers = {
        'dfid': ctx.dfid,
        'clienttime': str(now),
        'mid': ctx.mid,
        'kg-rc': '1',
        'kg-thash': '5d816a0',
        'kg-rec': '1',
        'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
        'User-Agent': UA,
    }
    if xrouter:
        headers['x-router'] = xrouter
    if extra_headers:
        headers.update(extra_headers)

    cookie_hdr = ''
    if cookies and ctx.cookie_path:
        kv = []
        for line in open(ctx.cookie_path):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            p = line.split('\t')
            if len(p) >= 7 and p[6]:
                kv.append('%s=%s' % (p[5], p[6]))
        cookie_hdr = '; '.join(kv)

    if cookie_hdr:
        headers['Cookie'] = cookie_hdr

    req = urllib.request.Request(url, headers=headers, method=method)
    req_body = None
    if body_str:
        req_body = body_str.encode('utf-8')
        headers['Content-Type'] = 'application/json;charset=utf-8'
    # 重建 Request 以带上 content-type
    req = urllib.request.Request(url, data=req_body, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            if r.headers.get('Content-Encoding') == 'gzip':
                try:
                    raw = gzip.decompress(raw)
                except Exception:
                    pass
            txt = raw.decode('utf-8', 'replace')
            hdrs = {k.lower(): v for k, v in r.headers.items()}
            try:
                body = json.loads(txt)
            except Exception:
                body = txt
            return Raw(r.status, body, hdrs, url)
    except urllib.error.HTTPError as e:
        raw = e.read()
        hdrs = {k.lower(): v for k, v in e.headers.items()}
        try:
            body = json.loads(raw.decode('utf-8', 'replace'))
        except Exception:
            body = raw.decode('utf-8', 'replace')
        return Raw(e.code, body, hdrs, url)
    except Exception as e:
        return Raw(0, {'status': 0, 'error': 'EXC %s' % e}, {}, url)


STATES = ['anon', 'nonvip', 'vip']
