#!/bin/sh
# 修正 fix_arb_1.sh 的拼接错误：sed '$ d' 删掉的不是纯 "}"（JSON 末行是 "}" 但
# 前一行 "qualitySuper" 无逗号）。统一用 python 修：删掉错误块、给 qualitySuper 补逗号、重拼。
set -e
cd /var/minis/workspace/TiernanMusic/lib/l10n
python3 - <<'EOF'
import json, io, re, sys

blocks = {
 'en': '  "previewOnly": "Preview",\n  "loginRequiredTitle": "Sign in required",\n  "loginRequiredHint": "This feature requires signing in to a KuGou account.",\n  "loginRequiredAction": "Sign in to use \\"{action}\\"."',
 'de': '  "previewOnly": "Vorschau",\n  "loginRequiredTitle": "Anmeldung erforderlich",\n  "loginRequiredHint": "Diese Funktion erfordert die Anmeldung mit einem KuGou-Konto.",\n  "loginRequiredAction": "Melden Sie sich an, um \\"{action}\\" zu verwenden."',
 'es': '  "previewOnly": "Vista previa",\n  "loginRequiredTitle": "Se requiere iniciar sesión",\n  "loginRequiredHint": "Esta función requiere iniciar sesión con una cuenta de KuGou.",\n  "loginRequiredAction": "Inicia sesión para usar \\"{action}\\"."',
 'fr': '  "previewOnly": "Aperçu",\n  "loginRequiredTitle": "Connexion requise",\n  "loginRequiredHint": "Cette fonctionnalité nécessite une connexion à un compte KuGou.",\n  "loginRequiredAction": "Connectez-vous pour utiliser \\"{action}\\"."',
 'ja': '  "previewOnly": "試聴",\n  "loginRequiredTitle": "ログインが必要です",\n  "loginRequiredHint": "この機能は KuGou アカウントへのログインが必要です。",\n  "loginRequiredAction": "「{action}」を使用するにはログインしてください。"',
 'ko': '  "previewOnly": "미리듣기",\n  "loginRequiredTitle": "로그인이 필요합니다",\n  "loginRequiredHint": "이 기능은 KuGou 계정 로그인이 필요합니다.",\n  "loginRequiredAction": "\\"{action}\\"을(를) 사용하려면 로그인하세요."',
 'pt': '  "previewOnly": "Prévia",\n  "loginRequiredTitle": "Login necessário",\n  "loginRequiredHint": "Este recurso requer login com uma conta KuGou.",\n  "loginRequiredAction": "Faça login para usar \\"{action}\\"."',
 'ru': '  "previewOnly": "Предпрослушивание",\n  "loginRequiredTitle": "Требуется вход",\n  "loginRequiredHint": "Для этой функции нужно войти в аккаунт KuGou.",\n  "loginRequiredAction": "Войдите, чтобы использовать «{action}»."',
 'zh_TW': '  "previewOnly": "試聽",\n  "loginRequiredTitle": "需要登入",\n  "loginRequiredHint": "此功能需要登入酷狗帳號後使用。",\n  "loginRequiredAction": "「{action}」需要登入後才能使用。"',
}

for lang, blk in blocks.items():
    fn = f'app_{lang}.arb'
    s = open(fn, encoding='utf-8').read()
    # 删除上次脚本追加的错误块：从 ',\\n' 行（质量行后）到文件尾
    m = re.search(r',\\\n  "previewOnly".*\n\}\n?$', s, re.S)
    if m:
        s = s[:m.start()] + '\n'
    else:
        # 也许文件现在以 '  "loginRequiredAction": "..."。\n}' 结尾（无 \\）
        m2 = re.search(r',\\\n', s)
        print(fn, 'pattern miss — inspect manually'); sys.exit(1)
    # qualitySuper 行补逗号
    s = re.sub(r'("qualitySuper": "[^"]*")\n\}', r'\1,\n}\n', s)
    # 追加新块
    s = s[:-2] + blk + '\n}\n'
    json.loads(s)  # 校验
    open(fn, 'w', encoding='utf-8').write(s)
    print(fn, 'OK')
EOF
