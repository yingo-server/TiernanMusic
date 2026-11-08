#!/usr/bin/env python3
"""「我喜欢」485首：pagesize=10，只请求页1~5 与页44~49（11次）。
前50=页1~5；后50=页44末5首 + 页45~48 + 页49(5首)。
四种拼法：正正/正反/反正/反反；正=原序，反=倒转。
结果写 /tmp/v4_paging_8.txt，一次生成8组，不反复请求API。
"""
import json, sys
sys.path.insert(0, '/var/minis/workspace/TiernanMusic/tool')
import kg_probe as k

ctx = k.Ctx('vip')
SIZE = 10
WANT = [1, 2, 3, 4, 5, 44, 45, 46, 47, 48, 49]

def name_of(s):
    for key in ('songname', 'song_name', 'name', 'filename', 'file_name', 'remark'):
        v = s.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return '(无歌名:%s)' % (s.get('hash') or '?')

pages = {}
for p in WANT:
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
    pages[p] = {
        'status': b.get('status'), 'err': b.get('error_code'),
        'count': d.get('count') if isinstance(d, dict) else None,
        'names': [name_of(s) for s in info if isinstance(s, dict)],
        'hashes': [str(s.get('hash') or '') for s in info if isinstance(s, dict)],
    }

# 参与片段：(页号, 该页参与后50的 names/hashes 切片)
def front():
    return [(p, pages[p]['names'], pages[p]['hashes']) for p in (1, 2, 3, 4, 5)]

def back():
    segs = []
    # 页44 末5首（436~440）
    segs.append((44, pages[44]['names'][-5:], pages[44]['hashes'][-5:]))
    for p in (45, 46, 47, 48, 49):
        segs.append((p, pages[p]['names'], pages[p]['hashes']))
    return segs

def compose(segs, rev_pages, rev_inner):
    ps = list(reversed(segs)) if rev_pages else list(segs)
    names, hashes = [], []
    for _, ns, hs in ps:
        names.extend(list(reversed(ns)) if rev_inner else list(ns))
        hashes.extend(list(reversed(hs)) if rev_inner else list(hs))
    return names, hashes

MODES = [('正正', False, False), ('正反', False, True),
         ('反正', True, False), ('反反', True, True)]

out = []
def emit(line=''):
    out.append(line)
    print(line, flush=True)

emit('参数: pagesize=10, 485首→49页(末页5首), 请求页 1,2,3,4,5,44,45,46,47,48,49 (共11次)')
emit('页长度: ' + ', '.join('p%d=%d' % (p, len(pages[p]['names'])) for p in WANT))
emit('页状态: ' + ', '.join('p%d:status=%s,err=%s,count=%s' % (
    p, pages[p]['status'], pages[p]['err'], pages[p]['count']) for p in WANT))
emit('')

for label, segs in (('前50', front()), ('后50', back())):
    for mname, rp, ri in MODES:
        names, hashes = compose(segs, rp, ri)
        emit('===== %s × %s （页序%s + 页内%s）=====' % (
            label, mname, '倒' if rp else '正', '倒' if ri else '正'))
        for i, n in enumerate(names, 1):
            emit('%2d. %s' % (i, n))
        emit('条数=%d 去重=%d 重复=%d 首=%s 末=%s' % (
            len(names), len(set(hashes)), len(hashes) - len(set(hashes)),
            names[0] if names else '-', names[-1] if names else '-'))
        emit('')

# 交叉验证：四种拼法集合一致（数学上必然，但仍核对）
front_sets = {}
for mname, rp, ri in MODES:
    _, hs = compose(front(), rp, ri)
    front_sets[mname] = set(hs)
emit('前50 四种拼法集合相同: ' + str(all(v == front_sets['正正'] for v in front_sets.values())))
back_sets = {}
for mname, rp, ri in MODES:
    _, hs = compose(back(), rp, ri)
    back_sets[mname] = set(hs)
emit('后50 四种拼法集合相同: ' + str(all(v == back_sets['正正'] for v in back_sets.values())))
emit('前50∩后50 交集: %d (应为0)' % len(front_sets['正正'] & back_sets['正正']))

open('/tmp/v4_paging_8.txt', 'w').write('\n'.join(out) + '\n')
json.dump({str(p): pages[p] for p in WANT}, open('/tmp/v4_paging_raw.json', 'w'),
          ensure_ascii=False, indent=1)
