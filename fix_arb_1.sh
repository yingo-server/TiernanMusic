#!/bin/sh
# V34-UI 修复批：向 12 个 arb 文件追加新键（i18n 补键必须 10 语言全齐）
set -e
cd /var/minis/workspace/TiernanMusic/lib/l10n

append() { # $1=file  $2=block(json lines, without trailing brace handling)
  file="$1"; shift
  # 去掉文件末尾的 "}"
  sed -i '$ d' "$file"
  # 去掉新块之前遗留的尾逗号问题：原最后一行若以 }, 结尾则安全；若原最后键无逗号需补
  # （各文件最后一键均带逗号结尾？检查：sed 后最后行是 "qualitySuper": "...", 或不带逗号）
  printf '%s\n}\n' "$@" >> "$file"
}

# ---------- 1) previewOnly / loginRequired* 4 键修复（app_en 与各非中文语言） ----------
# zh 模板保持中文原文；其余语言补英文/对应语言。

append app_en.arb ',\
  "previewOnly": "Preview",\
  "loginRequiredTitle": "Sign in required",\
  "loginRequiredHint": "This feature requires signing in to a KuGou account.",\
  "loginRequiredAction": "Sign in to use \"{action}\"."'

append app_de.arb ',\
  "previewOnly": "Vorschau",\
  "loginRequiredTitle": "Anmeldung erforderlich",\
  "loginRequiredHint": "Diese Funktion erfordert die Anmeldung mit einem KuGou-Konto.",\
  "loginRequiredAction": "Melden Sie sich an, um \"{action}\" zu verwenden."'

append app_es.arb ',\
  "previewOnly": "Vista previa",\
  "loginRequiredTitle": "Se requiere iniciar sesión",\
  "loginRequiredHint": "Esta función requiere iniciar sesión con una cuenta de KuGou.",\
  "loginRequiredAction": "Inicia sesión para usar \"{action}\"."'

append app_fr.arb ',\
  "previewOnly": "Aperçu",\
  "loginRequiredTitle": "Connexion requise",\
  "loginRequiredHint": "Cette fonctionnalité nécessite une connexion à un compte KuGou.",\
  "loginRequiredAction": "Connectez-vous pour utiliser \"{action}\"."'

append app_ja.arb ',\
  "previewOnly": "試聴",\
  "loginRequiredTitle": "ログインが必要です",\
  "loginRequiredHint": "この機能は KuGou アカウントへのログインが必要です。",\
  "loginRequiredAction": "「{action}」を使用するにはログインしてください。"'

append app_ko.arb ',\
  "previewOnly": "미리듣기",\
  "loginRequiredTitle": "로그인이 필요합니다",\
  "loginRequiredHint": "이 기능은 KuGou 계정 로그인이 필요합니다.",\
  "loginRequiredAction": "\"{action}\"을(를) 사용하려면 로그인하세요."'

append app_pt.arb ',\
  "previewOnly": "Prévia",\
  "loginRequiredTitle": "Login necessário",\
  "loginRequiredHint": "Este recurso requer login com uma conta KuGou.",\
  "loginRequiredAction": "Faça login para usar \"{action}\"."'

append app_ru.arb ',\
  "previewOnly": "Предпрослушивание",\
  "loginRequiredTitle": "Требуется вход",\
  "loginRequiredHint": "Для этой функции нужно войти в аккаунт KuGou.",\
  "loginRequiredAction": "Войдите, чтобы использовать «{action}»."'

append app_zh_TW.arb ',\
  "previewOnly": "試聽",\
  "loginRequiredTitle": "需要登入",\
  "loginRequiredHint": "此功能需要登入酷狗帳號後使用。",\
  "loginRequiredAction": "「{action}」需要登入後才能使用。"'

echo OK1
