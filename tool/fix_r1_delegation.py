import re

p = 'lib/core/direct/kg_direct_api_client.dart'
s = open(p).read()

# 1) 端点组名映射（case 前缀 → 端点类字段）
mapping = {
    'search': '_searchE', 'comment': '_commentE', 'playlist': '_playlistE',
    'artist': '_artistE', 'album': '_artistE',  # album 方法也在 ArtistAlbum 组
    'user': '_playlistE', 'everyday': '_homeE', 'yueku': '_homeE',
    'top': '_homeE', 'rank': '_homeE', 'kmr': '_mediaE', 'video': '_mediaE',
    'login': '_authE', 'captcha': '_authE', 'get/verify': '_authE',
    'verify/user': '_authE', 'register': '_authE',
}

# 2) 主类中把 `_xxx(` 调用改为 `_xE._xxx(`
#    只处理 get()/post() switch 与 _directOrFallback 调用上下文（缩进 ≥ 6 空格的行）
lines = s.split('\n')
out = []
in_switch = False
for ln in lines:
    m = re.match(r"^(\s{6,})(_[a-z][A-Za-z]*)\(", ln)
    if m:
        indent, method = m.groups()
        owner = None
        for prefix, field in mapping.items():
            if method.startswith(prefix) or method == prefix.replace('/', ''):
                owner = field
                break
        if owner is None:
            # 逐个方法反查：从端点文件里找该方法定义
            import glob
            for f in glob.glob('lib/core/direct/kg_endpoints_*.dart'):
                if re.search(r'Future<KgResponse> ' + method + r'\(', open(f).read()):
                    cls = re.search(r'class (KgEndpoint\w+)', open(f).read()).group(1)
                    for prefix, field in mapping.items():
                        pass
                    # 直接用类名反查字段
                    field_by_cls = {
                        'KgEndpointSearch': '_searchE', 'KgEndpointComment': '_commentE',
                        'KgEndpointPlaylist': '_playlistE', 'KgEndpointArtistAlbum': '_artistE',
                        'KgEndpointHome': '_homeE', 'KgEndpointMedia': '_mediaE',
                        'KgEndpointAuth': '_authE',
                    }
                    owner = field_by_cls.get(cls)
                    break
        if owner:
            ln = f"{indent}{owner}.{method}("
    out.append(ln)

s = '\n'.join(out)
open(p, 'w').write(s)
print('done, delegated calls:', sum(1 for l in out if re.search(r'_\w+E\._\w+\(', l)))
