#!/bin/sh
# 括号/圆括号配平检查（忽略字符串与注释的粗略实现：逐字符扫描，处理 // 行注释、/* */、'..'、".."）
cd /var/minis/workspace/TiernanMusic
for f in $(find lib -name '*.dart'); do
python3 - "$f" <<'EOF'
import sys
src = open(sys.argv[1]).read()
i=0; n=len(src); stack=[]; line=1; bad=None
mode=None  # None, 'line', 'block', 'sq', 'dq', 'tsq', 'tdq', 'ch'
while i<n:
    c=src[i]
    if c=='\n': line+=1
    if mode=='line':
        if c=='\n': mode=None
        i+=1; continue
    if mode=='block':
        if c=='*' and i+1<n and src[i+1]=='/': mode=None; i+=2; continue
        i+=1; continue
    if mode in ('sq','dq'):
        if c=='\\': i+=2; continue
        if mode=='sq' and c=="'": mode=None
        elif mode=='dq' and c=='"': mode=None
        i+=1; continue
    if mode=='ch':
        if c=='\\': i+=2; continue
        if c=="'": mode=None
        i+=1; continue
    if mode=='tsq' or mode=='tdq':
        if c=='\\': i+=2; continue
        triple = "'''" if mode=='tsq' else '"""'
        if src[i:i+3]==triple: mode=None; i+=3; continue
        if c=='$' and i+1<n and src[i+1]=='{':
            stack.append(('interp',line)); i+=2; continue
        i+=1; continue
    # normal
    if c=='/' and i+1<n and src[i+1]=='/': mode='line'; i+=2; continue
    if c=='/' and i+1<n and src[i+1]=='*': mode='block'; i+=2; continue
    if c=='"':
        if src[i:i+3]=='"""': mode='tdq'; i+=3; continue
        mode='dq'; i+=1; continue
    if c=="'":
        if src[i:i+3]=="'''": mode='tsq'; i+=3; continue
        mode='ch'; i+=1; continue
    if c=='$' and i+1<n and src[i+1]=='{':
        stack.append(('interp',line)); i+=2; continue
    if c in '{([': stack.append((c,line)); i+=1; continue
    if c in '})]':
        pairs={')':'(',']':'[','}':'{'}
        if stack and stack[-1][0] in '{([' and pairs[c]==stack[-1][0]:
            stack.pop(); i+=1; continue
        if stack and stack[-1][0]=='interp':
            if c=='}': stack.pop(); i+=1; continue
        bad=(c,line); break
    i+=1
if bad: print(f"{sys.argv[1]}: UNBALANCED '{bad[0]}' at line {bad[1]}")
elif stack: print(f"{sys.argv[1]}: UNCLOSED {stack[-5:]}")
EOF
done
echo "brace check done"
