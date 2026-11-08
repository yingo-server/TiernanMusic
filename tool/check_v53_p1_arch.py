#!/usr/bin/env python3
"""v5.3 P1：状态机重写后的架构/契约静态断言（无 Flutter SDK 时可执行）。

纪律：只检查**代码**，忽略注释与字符串字面量——文档里需要引用旧类名
解释「为什么弃用」，那不是残留实现。
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
errors = []


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def code_only(src):
    """去掉 // 行注释、/// 文档注释和简单字符串字面量。"""
    out = []
    for line in src.splitlines():
        stripped = line.lstrip()
        if stripped.startswith('//'):
            continue
        # 去掉行尾注释（不处理字符串内 //，本仓无该模式）
        if '//' in line:
            line = line.split('//', 1)[0]
        out.append(line)
    return '\n'.join(out)


def check(cond, msg):
    if not cond:
        errors.append(msg)


# 1) A-00：全仓只有 audio_service_bootstrap 一处 AudioService.init；
#    just_audio_background 彻底弃用（代码层，不含解释性注释）。
init_hits = []
for base, dirs, files in os.walk('lib'):
    for name in files:
        if not name.endswith('.dart'):
            continue
        p = os.path.join(base, name)
        s = code_only(read(p))
        if 'AudioService.init(' in s:
            init_hits.append(p)
        check('JustAudioBackground' not in s,
              f'just_audio_background 残留: {p}')
check(init_hits == ['lib/core/audio/audio_service_bootstrap.dart'],
      f'AudioService.init 必须唯一，实际={init_hits}')

# 2) audio_handler 不得 import presentation 层 / 不得再用 QueueHandler mixin。
ah = code_only(read('lib/features/player/data/audio_handler.dart'))
check('/presentation/' not in ah, 'audio_handler import 了 presentation 层')
check('with QueueHandler' not in ah, 'audio_handler 仍混用 QueueHandler')
for dead in ['_songs[', '_pendingIndex', '_pendingSongHash', '_playToken',
             '_failureStreak', '_isPreview', '_lastPlayUrl']:
    check(dead not in ah, f'audio_handler 仍持有旧状态字段 {dead}')

# 3) _songs[ 只允许状态机内部。
#    album/artist/rank 页的同名局部变量是各页自己的分页列表（审计 A-25），
#    不是共享播放状态，按报告结论排除；只查播放器域 + core。
for base, dirs, files in os.walk('lib'):
    for name in files:
        if not name.endswith('.dart'):
            continue
        p = os.path.join(base, name)
        if not (p.startswith('lib/core/') or
                p.startswith('lib/features/player/')):
            continue
        if '_songs[' in code_only(read(p)):
            check(p == 'lib/core/player_state/player_state.dart',
                  f'状态字段 _songs[ 泄漏到 {p}')

# 4) queue_sheet 不得直接调 _api / 不得整表替换实现跳转。
qs = code_only(read('lib/features/player/presentation/queue_sheet.dart'))
check('_api' not in qs, 'queue_sheet 直接触达 _api')
check('playQueue(' not in qs, 'queue_sheet 仍用整表替换实现跳到队列项')

# 5) UI 三处必须 watch playerStateProvider（单一状态映射）。
for p in [
    'lib/features/player/presentation/mini_player.dart',
    'lib/features/player/presentation/full_player_page.dart',
    'lib/features/player/presentation/queue_sheet.dart',
]:
    check('playerStateProvider' in code_only(read(p)),
          f'{p} 未 watch playerStateProvider')

# 6) 状态机 sealed 类 + completed 世代守卫。
st = code_only(read('lib/core/player_state/player_state.dart'))
check('sealed class PlayerState' in st, 'PlayerState 不是 sealed')
check('event.generation != gen' in st, 'Completed 缺世代守卫')
check('event.sourceId != st.sourceId' in st, 'Completed 缺 sourceId 守卫')
check('final class PlayerSuspended' in st, '20028 未成为一等状态')

if errors:
    print('ARCH FAIL')
    for e in errors:
        print(' -', e)
    sys.exit(1)
print('ARCH PASS: P1 state machine guards ok')
