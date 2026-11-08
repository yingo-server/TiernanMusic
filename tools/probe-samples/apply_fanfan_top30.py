#!/usr/bin/env python3
"""反反规则作用于完整485首，取前30名。
反反 = 页序倒(49..1) + 页内倒 = 原序完整反转。
前30 = 页49(5,倒) + 页48(10,倒) + 页47(10,倒) + 页46(倒的前5)。
数据来自 /tmp/v4_paging_raw.json（已取的页44~49），零新增API请求。
并与「后50 正正序列的末30反转」交叉核对（应完全一致）。
"""
import json
raw = json.load(open('/tmp/v4_paging_raw.json'))
# 完整反反拼：需要页49..1，但前30只用到 49,48,47,46
order = [49, 48, 47, 46, 45, 44]  # 已有的末段页，足够覆盖前30
flat = []
for p in order:
    ns = raw[str(p)]['names']
    flat.extend(list(reversed(ns)))   # 页内倒

print('===== 反反（页序倒+页内倒）在 485 首中的前 30 名 =====')
for i, n in enumerate(flat[:30], 1):
    print('%2d. %s' % (i, n))
print('---')
print('可用末段总条数:', len(flat), '（页49..44 = 5+10*5 = 55）')

# 交叉核对：反反 = 完整反转 → 前30 == 后50(正正)的末30再反转
# 后50 正正 = 页44末5 + 页45..49 原序
back_normal = []
back_normal.extend(raw['44']['names'][-5:])
for p in (45, 46, 47, 48, 49):
    back_normal.extend(raw[str(p)]['names'])
expected = list(reversed(back_normal))[:30]
print('与「后50正正末30反转」一致:', flat[:30] == expected)
if flat[:30] != expected:
    for i, (a, b) in enumerate(zip(flat[:30], expected), 1):
        if a != b:
            print('  首个差异 @%d: 反反=%s / 期望=%s' % (i, a, b))
            break
