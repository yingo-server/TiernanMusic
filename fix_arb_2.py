import json, re, sys, os
os.chdir('/var/minis/workspace/TiernanMusic/lib/l10n')

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
    lines = open(fn, encoding='utf-8').read().splitlines()
    # 找最后一个 "qualitySuper" 行，截断其后所有行（去掉坏块）
    idx = max(i for i, l in enumerate(lines) if '"qualitySuper"' in l)
    lines = lines[:idx+1]
    # qualitySuper 行补逗号
    if not lines[idx].rstrip().endswith(','):
        lines[idx] += ','
    lines += blk.split('\n')
    lines.append('}')
    s = '\n'.join(lines) + '\n'
    json.loads(s)
    open(fn, 'w', encoding='utf-8').write(s)
    print(fn, 'OK')
