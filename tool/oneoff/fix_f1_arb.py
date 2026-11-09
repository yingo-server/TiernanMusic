#!/usr/bin/env python3
"""F1: add all/showPassword/hidePassword translations to 9 ARBs."""
import json, collections

T = {
 'en': {'all':'All','showPassword':'Show password','hidePassword':'Hide password'},
 'de': {'all':'Alle','showPassword':'Passwort anzeigen','hidePassword':'Passwort verbergen'},
 'es': {'all':'Todo','showPassword':'Mostrar contraseña','hidePassword':'Ocultar contraseña'},
 'fr': {'all':'Tout','showPassword':'Afficher le mot de passe','hidePassword':'Masquer le mot de passe'},
 'ja': {'all':'すべて','showPassword':'パスワードを表示','hidePassword':'パスワードを非表示'},
 'ko': {'all':'전체','showPassword':'비밀번호 표시','hidePassword':'비밀번호 숨기기'},
 'pt': {'all':'Tudo','showPassword':'Mostrar senha','hidePassword':'Ocultar senha'},
 'ru': {'all':'Все','showPassword':'Показать пароль','hidePassword':'Скрыть пароль'},
 'zh_TW': {'all':'全部','showPassword':'顯示密碼','hidePassword':'隱藏密碼'},
}
keys = ['all','showPassword','hidePassword']
for lang, tr in T.items():
    p = f'lib/l10n/app_{lang}.arb'
    with open(p, encoding='utf-8') as f:
        data = json.load(f, object_pairs_hook=collections.OrderedDict)
    changed = False
    for k in keys:
        if data.get(k) != tr[k]:
            data[k] = tr[k]
            changed = True
    if changed:
        with open(p, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write('\n')
    print(lang, 'ok' if changed else 'unchanged')
