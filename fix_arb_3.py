import json, os
os.chdir('/var/minis/workspace/TiernanMusic/lib/l10n')

# 新键（V34-UI-01 收藏弹层 2 键 + V34-UI-02 captcha 页文案）。
# 各语言块的键序一致：先 caption 键后占位符键。
keys = ['addedToPlaylist','playlistNameEmpty','captchaTitle','captchaLoadFailed',
        'captchaSmsTitle','captchaSmsHint','captchaSmsCodeLabel','captchaSmsCodeHint',
        'captchaSubmit','captchaNotPassed','captchaPassedButRetry','captchaSubmitFailed',
        'captchaTencentHint','captchaExternalHint','captchaClose','captchaUnknownType',
        'captchaNoVerifyUrl','captchaTryFingerprint']

zh = {
 'addedToPlaylist': '已加入歌单',
 'playlistNameEmpty': '请输入歌单名称',
 'captchaTitle': '人机验证',
 'captchaLoadFailed': '获取验证信息失败，请重试',
 'captchaSmsTitle': '短信验证',
 'captchaSmsHint': '请输入接收到的验证码完成验证',
 'captchaSmsCodeLabel': '验证码',
 'captchaSmsCodeHint': '6 位数字',
 'captchaSubmit': '提交验证',
 'captchaNotPassed': '验证未通过，请重试',
 'captchaPassedButRetry': '验证已通过，但请求仍需重试',
 'captchaSubmitFailed': '提交失败，请稍后重试',
 'captchaTencentHint': '如验证码未自动弹出，请点击页面中的「开始验证」',
 'captchaExternalHint': '该验证类型需要在酷狗官方 App 内完成。\n建议：先在官方 App 完成一次操作，再回到本应用重试。',
 'captchaClose': '关闭',
 'captchaUnknownType': '未知验证类型（v_type={type}）',
 'captchaNoVerifyUrl': '服务端未返回验证 url',
 'captchaTryFingerprint': '直接尝试提交指纹验证',
}

def tr(d, **over):
    r = dict(d); r.update(over); return r

langs = {
 'zh': zh,
 'zh_CN': zh,
 'zh_TW': {**zh,
  'addedToPlaylist':'已加入歌單','playlistNameEmpty':'請輸入歌單名稱','captchaTitle':'人機驗證',
  'captchaLoadFailed':'取得驗證資訊失敗，請重試','captchaSmsTitle':'簡訊驗證',
  'captchaSmsHint':'請輸入收到的驗證碼完成驗證','captchaSmsCodeLabel':'驗證碼','captchaSmsCodeHint':'6 位數字',
  'captchaSubmit':'提交驗證','captchaNotPassed':'驗證未通過，請重試','captchaPassedButRetry':'驗證已通過，但請求仍需重試',
  'captchaSubmitFailed':'提交失敗，請稍後重試','captchaTencentHint':'如驗證碼未自動彈出，請點擊頁面中的「開始驗證」',
  'captchaExternalHint':'該驗證類型需要在酷狗官方 App 內完成。\n建議：先在官方 App 完成一次操作，再回到本應用重試。',
  'captchaClose':'關閉','captchaUnknownType':'未知驗證類型（v_type={type}）','captchaNoVerifyUrl':'伺服器未回傳驗證 url',
  'captchaTryFingerprint':'直接嘗試提交指紋驗證'},
 'en': {
  'addedToPlaylist':'Added to playlist','playlistNameEmpty':'Please enter a playlist name',
  'captchaTitle':'Verification','captchaLoadFailed':'Failed to load verification info, please retry',
  'captchaSmsTitle':'SMS verification','captchaSmsHint':'Enter the verification code you received to continue',
  'captchaSmsCodeLabel':'Verification code','captchaSmsCodeHint':'6 digits',
  'captchaSubmit':'Submit','captchaNotPassed':'Verification failed, please try again',
  'captchaPassedButRetry':'Verification passed, but the request still needs to be retried',
  'captchaSubmitFailed':'Submit failed, please try again later',
  'captchaTencentHint':'If the captcha does not appear automatically, tap "Start verification" on the page',
  'captchaExternalHint':'This verification type must be completed in the official KuGou app.\nTip: complete the action once in the official app, then come back and retry.',
  'captchaClose':'Close','captchaUnknownType':'Unknown verification type (v_type={type})',
  'captchaNoVerifyUrl':'Server did not return a verification URL',
  'captchaTryFingerprint':'Try submitting fingerprint verification directly'},
 'ja': {
  'addedToPlaylist':'プレイリストに追加しました','playlistNameEmpty':'プレイリスト名を入力してください',
  'captchaTitle':'認証','captchaLoadFailed':'認証情報の取得に失敗しました。再試行してください',
  'captchaSmsTitle':'SMS認証','captchaSmsHint':'受信した認証コードを入力して完了してください',
  'captchaSmsCodeLabel':'認証コード','captchaSmsCodeHint':'6桁の数字',
  'captchaSubmit':'送信','captchaNotPassed':'認証に失敗しました。再試行してください',
  'captchaPassedButRetry':'認証は完了しましたが、リクエストを再試行する必要があります',
  'captchaSubmitFailed':'送信に失敗しました。しばらくしてから再試行してください',
  'captchaTencentHint':'認証が自動的に表示されない場合は、ページの「認証を開始」をタップしてください',
  'captchaExternalHint':'この認証タイプは KuGou 公式アプリで完了する必要があります。\n公式アプリで一度操作してから、本アプリに戻って再試行してください。',
  'captchaClose':'閉じる','captchaUnknownType':'不明な認証タイプ（v_type={type}）',
  'captchaNoVerifyUrl':'サーバーが認証 URL を返しませんでした',
  'captchaTryFingerprint':'指紋認証を直接送信してみる'},
 'ko': {
  'addedToPlaylist':'플레이리스트에 추가됨','playlistNameEmpty':'플레이리스트 이름을 입력하세요',
  'captchaTitle':'보안 인증','captchaLoadFailed':'인증 정보를 가져오지 못했습니다. 다시 시도하세요',
  'captchaSmsTitle':'SMS 인증','captchaSmsHint':'받은 인증 코드를 입력하여 완료하세요',
  'captchaSmsCodeLabel':'인증 코드','captchaSmsCodeHint':'숫자 6자리',
  'captchaSubmit':'제출','captchaNotPassed':'인증에 실패했습니다. 다시 시도하세요',
  'captchaPassedButRetry':'인증은 통과했지만 요청을 다시 시도해야 합니다',
  'captchaSubmitFailed':'제출에 실패했습니다. 잠시 후 다시 시도하세요',
  'captchaTencentHint':'인증이 자동으로 나타나지 않으면 페이지의 "인증 시작"을 누르세요',
  'captchaExternalHint':'이 인증 유형은 KuGou 공식 앱에서 완료해야 합니다.\n공식 앱에서 한 번 수행한 뒤 이 앱으로 돌아와 다시 시도하세요.',
  'captchaClose':'닫기','captchaUnknownType':'알 수 없는 인증 유형 (v_type={type})',
  'captchaNoVerifyUrl':'서버가 인증 URL을 반환하지 않았습니다',
  'captchaTryFingerprint':'지문 인증을 바로 제출해 보기'},
 'es': {
  'addedToPlaylist':'Añadido a la playlist','playlistNameEmpty':'Introduce un nombre para la playlist',
  'captchaTitle':'Verificación','captchaLoadFailed':'No se pudo cargar la información de verificación, reintenta',
  'captchaSmsTitle':'Verificación por SMS','captchaSmsHint':'Introduce el código de verificación recibido para continuar',
  'captchaSmsCodeLabel':'Código de verificación','captchaSmsCodeHint':'6 dígitos',
  'captchaSubmit':'Enviar','captchaNotPassed':'Verificación fallida, inténtalo de nuevo',
  'captchaPassedButRetry':'Verificación superada, pero hay que reintentar la solicitud',
  'captchaSubmitFailed':'Error al enviar, inténtalo más tarde',
  'captchaTencentHint':'Si el captcha no aparece automáticamente, pulsa "Iniciar verificación" en la página',
  'captchaExternalHint':'Este tipo de verificación debe completarse en la app oficial de KuGou.\nConsejo: completa la acción una vez en la app oficial y vuelve a intentarlo aquí.',
  'captchaClose':'Cerrar','captchaUnknownType':'Tipo de verificación desconocido (v_type={type})',
  'captchaNoVerifyUrl':'El servidor no devolvió una URL de verificación',
  'captchaTryFingerprint':'Probar la verificación de huella directamente'},
 'fr': {
  'addedToPlaylist':'Ajouté à la playlist','playlistNameEmpty':'Veuillez saisir un nom de playlist',
  'captchaTitle':'Vérification','captchaLoadFailed':'Échec du chargement des informations de vérification, réessayez',
  'captchaSmsTitle':'Vérification par SMS','captchaSmsHint':'Saisissez le code de vérification reçu pour continuer',
  'captchaSmsCodeLabel':'Code de vérification','captchaSmsCodeHint':'6 chiffres',
  'captchaSubmit':'Envoyer','captchaNotPassed':'Vérification échouée, veuillez réessayer',
  'captchaPassedButRetry':'Vérification réussie, mais la requête doit être retentée',
  'captchaSubmitFailed':'Échec de l\'envoi, réessayez plus tard',
  'captchaTencentHint':'Si le captcha n\'apparaît pas automatiquement, appuyez sur « Démarrer la vérification »',
  'captchaExternalHint':'Ce type de vérification doit être effectué dans l\'application officielle KuGou.\nAstuce : effectuez l\'action une fois dans l\'application officielle, puis revenez et réessayez.',
  'captchaClose':'Fermer','captchaUnknownType':'Type de vérification inconnu (v_type={type})',
  'captchaNoVerifyUrl':'Le serveur n\'a pas renvoyé d\'URL de vérification',
  'captchaTryFingerprint':'Essayer directement la vérification par empreinte'},
 'de': {
  'addedToPlaylist':'Zur Playlist hinzugefügt','playlistNameEmpty':'Bitte einen Playlist-Namen eingeben',
  'captchaTitle':'Sicherheitsprüfung','captchaLoadFailed':'Verifizierungsinformationen konnten nicht geladen werden, bitte wiederholen',
  'captchaSmsTitle':'SMS-Verifizierung','captchaSmsHint':'Geben Sie den erhaltenen Code ein, um fortzufahren',
  'captchaSmsCodeLabel':'Code','captchaSmsCodeHint':'6 Ziffern',
  'captchaSubmit':'Absenden','captchaNotPassed':'Verifizierung fehlgeschlagen, bitte erneut versuchen',
  'captchaPassedButRetry':'Verifizierung erfolgreich, die Anfrage muss jedoch erneut versucht werden',
  'captchaSubmitFailed':'Absenden fehlgeschlagen, bitte später erneut versuchen',
  'captchaTencentHint':'Falls das Captcha nicht automatisch erscheint, tippen Sie auf „Verifizierung starten“',
  'captchaExternalHint':'Diese Art der Verifizierung muss in der offiziellen KuGou-App abgeschlossen werden.\nTipp: Führen Sie den Vorgang einmal in der offiziellen App aus und versuchen Sie es hier erneut.',
  'captchaClose':'Schließen','captchaUnknownType':'Unbekannter Verifizierungstyp (v_type={type})',
  'captchaNoVerifyUrl':'Server hat keine Verifizierungs-URL zurückgegeben',
  'captchaTryFingerprint':'Fingerabdruck-Verifizierung direkt versuchen'},
 'pt': {
  'addedToPlaylist':'Adicionado à playlist','playlistNameEmpty':'Digite um nome para a playlist',
  'captchaTitle':'Verificação','captchaLoadFailed':'Falha ao carregar informações de verificação, tente novamente',
  'captchaSmsTitle':'Verificação por SMS','captchaSmsHint':'Digite o código de verificação recebido para continuar',
  'captchaSmsCodeLabel':'Código de verificação','captchaSmsCodeHint':'6 dígitos',
  'captchaSubmit':'Enviar','captchaNotPassed':'Verificação falhou, tente novamente',
  'captchaPassedButRetry':'Verificação concluída, mas a solicitação precisa ser repetida',
  'captchaSubmitFailed':'Falha no envio, tente novamente mais tarde',
  'captchaTencentHint':'Se o captcha não aparecer automaticamente, toque em "Iniciar verificação" na página',
  'captchaExternalHint':'Este tipo de verificação deve ser concluído no app oficial do KuGou.\nDica: conclua a ação uma vez no app oficial e volte para tentar novamente aqui.',
  'captchaClose':'Fechar','captchaUnknownType':'Tipo de verificação desconhecido (v_type={type})',
  'captchaNoVerifyUrl':'O servidor não retornou uma URL de verificação',
  'captchaTryFingerprint':'Tentar verificação por impressão digital diretamente'},
 'ru': {
  'addedToPlaylist':'Добавлено в плейлист','playlistNameEmpty':'Введите название плейлиста',
  'captchaTitle':'Проверка','captchaLoadFailed':'Не удалось загрузить данные проверки, повторите попытку',
  'captchaSmsTitle':'Проверка по SMS','captchaSmsHint':'Введите полученный код подтверждения',
  'captchaSmsCodeLabel':'Код подтверждения','captchaSmsCodeHint':'6 цифр',
  'captchaSubmit':'Отправить','captchaNotPassed':'Проверка не пройдена, попробуйте ещё раз',
  'captchaPassedButRetry':'Проверка пройдена, но запрос нужно повторить',
  'captchaSubmitFailed':'Ошибка отправки, попробуйте позже',
  'captchaTencentHint':'Если капча не появилась автоматически, нажмите «Начать проверку» на странице',
  'captchaExternalHint':'Этот тип проверки нужно пройти в официальном приложении KuGou.\nСовет: выполните действие в официальном приложении, затем вернитесь и повторите попытку.',
  'captchaClose':'Закрыть','captchaUnknownType':'Неизвестный тип проверки (v_type={type})',
  'captchaNoVerifyUrl':'Сервер не вернул URL проверки',
  'captchaTryFingerprint':'Попробовать сразу отправить проверку по отпечатку'},
}

for lang, d in langs.items():
    fn = f'app_{lang}.arb'
    lines = open(fn, encoding='utf-8').read().splitlines()
    lines = [l for l in lines if l.rstrip() != '}' and l.rstrip() != '},']
    # 去掉可能残留的孤立 ",\\" 行（上次失败运行遗留）
    lines = [l for l in lines if l.strip() not in (',\\', ',')]
    # 恢复被误删的 "},"：无法恢复——若发现以 '"..."' 结尾且下一个以 '"' 开头的键没有逗号则补
    out = []
    for i, l in enumerate(lines):
        out.append(l)
        if i + 1 < len(lines):
            nxt = lines[i+1].strip()
            if not l.rstrip().endswith((',', '{', '[', ':')) and (nxt.startswith('"') or nxt in ('{','[')):
                out[-1] = l.rstrip() + ','
    # 最后一行（最后一个键）若无逗号则补
    if not lines[-1].rstrip().endswith(','):
        lines[-1] += ','
    for k in keys:
        v = d[k].replace('\\', '\\\\').replace('\n', '\\n')
        if '{' in v and '{type}' in v:
            lines.append(f'  "{k}": "{v}",')
            lines.append(f'  "@{k}": {{')
            lines.append('    "placeholders": {')
            lines.append('      "type": {')
            lines.append('        "type": "String"')
            lines.append('      }')
            lines.append('    }')
            lines.append('  },')
        elif k == keys[-1]:
            lines.append(f'  "{k}": "{v}"')
        else:
            lines.append(f'  "{k}": "{v}",')
    lines.append('}')
    s = '\n'.join(lines) + '\n'
    json.loads(s)
    open(fn, 'w', encoding='utf-8').write(s)
    print(fn, 'OK')
