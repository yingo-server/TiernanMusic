#!/usr/bin/env python3
"""批3修3：添加退出登录/切换账号相关 l10n key（带 @key 占位符元数据）。"""
import json, os

ROOT = '/var/minis/workspace/TiernanMusic'
ARB = os.path.join(ROOT, 'lib', 'l10n')

# key -> (zh_CN 文本, @key 元数据或 None)
NEW = {
    'logoutConfirm': ('确定要退出当前账号吗？', {
        'type': 'text', 'description': '退出登录确认弹窗文案'}),
    'logoutSuccess': ('已退出登录', None),
    'logoutFailed': ('退出登录失败：{error}', {
        'placeholders': {'error': {'type': 'String'}}}),
    'switchAccountSuccess': ('已切换账号', None),
    'switchAccountFailed': ('切换账号失败：{error}', {
        'placeholders': {'error': {'type': 'String'}}}),
    'accountNeedRelogin': ('该账号需要重新登录', None),
}

TEXTS = {
    'en': {
        'logoutConfirm': 'Log out of the current account?',
        'logoutSuccess': 'Logged out',
        'logoutFailed': 'Logout failed: {error}',
        'switchAccountSuccess': 'Account switched',
        'switchAccountFailed': 'Account switch failed: {error}',
        'accountNeedRelogin': 'This account needs to sign in again',
    },
    'de': {
        'logoutConfirm': 'Aktuelles Konto abmelden?',
        'logoutSuccess': 'Abgemeldet',
        'logoutFailed': 'Abmeldung fehlgeschlagen: {error}',
        'switchAccountSuccess': 'Konto gewechselt',
        'switchAccountFailed': 'Kontowechsel fehlgeschlagen: {error}',
        'accountNeedRelogin': 'Dieses Konto muss sich erneut anmelden',
    },
    'es': {
        'logoutConfirm': '¿Cerrar sesión de la cuenta actual?',
        'logoutSuccess': 'Sesión cerrada',
        'logoutFailed': 'Error al cerrar sesión: {error}',
        'switchAccountSuccess': 'Cuenta cambiada',
        'switchAccountFailed': 'Error al cambiar de cuenta: {error}',
        'accountNeedRelogin': 'Esta cuenta debe iniciar sesión de nuevo',
    },
    'fr': {
        'logoutConfirm': 'Se déconnecter du compte actuel ?',
        'logoutSuccess': 'Déconnecté',
        'logoutFailed': 'Échec de la déconnexion : {error}',
        'switchAccountSuccess': 'Compte changé',
        'switchAccountFailed': 'Échec du changement de compte : {error}',
        'accountNeedRelogin': 'Ce compte doit se reconnecter',
    },
    'ja': {
        'logoutConfirm': '現在のアカウントからログアウトしますか？',
        'logoutSuccess': 'ログアウトしました',
        'logoutFailed': 'ログアウトに失敗しました：{error}',
        'switchAccountSuccess': 'アカウントを切り替えました',
        'switchAccountFailed': 'アカウントの切り替えに失敗しました：{error}',
        'accountNeedRelogin': 'このアカウントは再ログインが必要です',
    },
    'ko': {
        'logoutConfirm': '현재 계정에서 로그아웃하시겠습니까?',
        'logoutSuccess': '로그아웃되었습니다',
        'logoutFailed': '로그아웃 실패: {error}',
        'switchAccountSuccess': '계정이 전환되었습니다',
        'switchAccountFailed': '계정 전환 실패: {error}',
        'accountNeedRelogin': '이 계정은 다시 로그인해야 합니다',
    },
    'pt': {
        'logoutConfirm': 'Sair da conta atual?',
        'logoutSuccess': 'Sessão encerrada',
        'logoutFailed': 'Falha ao sair: {error}',
        'switchAccountSuccess': 'Conta alterada',
        'switchAccountFailed': 'Falha ao alternar conta: {error}',
        'accountNeedRelogin': 'Esta conta precisa entrar novamente',
    },
    'ru': {
        'logoutConfirm': 'Выйти из текущего аккаунта?',
        'logoutSuccess': 'Вы вышли из аккаунта',
        'logoutFailed': 'Не удалось выйти: {error}',
        'switchAccountSuccess': 'Аккаунт переключён',
        'switchAccountFailed': 'Не удалось переключить аккаунт: {error}',
        'accountNeedRelogin': 'Этот аккаунт требует повторного входа',
    },
    'zh': {
        'logoutConfirm': '确定要退出当前账号吗？',
        'logoutSuccess': '已退出登录',
        'logoutFailed': '退出登录失败：{error}',
        'switchAccountSuccess': '已切换账号',
        'switchAccountFailed': '切换账号失败：{error}',
        'accountNeedRelogin': '该账号需要重新登录',
    },
    'zh_TW': {
        'logoutConfirm': '確定要登出目前帳號嗎？',
        'logoutSuccess': '已登出',
        'logoutFailed': '登出失敗：{error}',
        'switchAccountSuccess': '已切換帳號',
        'switchAccountFailed': '切換帳號失敗：{error}',
        'accountNeedRelogin': '該帳號需要重新登入',
    },
}

def load(name):
    with open(os.path.join(ARB, name), encoding='utf-8') as f:
        return json.load(f)

def save(name, data):
    with open(os.path.join(ARB, name), 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')

for fname in sorted(os.listdir(ARB)):
    if not (fname.startswith('app_') and fname.endswith('.arb')):
        continue
    loc = fname[4:-4]
    data = load(fname)
    if 'logout' not in data:
        continue  # sanity
    for key, (zh, meta) in NEW.items():
        text = TEXTS.get(loc, {}).get(key, zh)
        data[key] = text
        if meta is not None:
            data['@' + key] = meta
    save(fname, data)
    print(f'{fname}: +{len(NEW)} keys')
