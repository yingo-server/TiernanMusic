#!/usr/bin/env python3
"""v5.3-R2：新增 10 个 l10n 键 × 11 语 + 修复 fr.notPlaying 语义反转 + addToPlaylist 语义澄清。

来源：docs/v53_r1_c.md C-55 / C-56；PLAN P4 文案审计。
追加到各 arb 末尾（保持 JSON 合法），@ 元数据仅加到模板 zh_CN。
"""
import json, collections, io, sys

NEW = {
  # key: {loc: value}
  'storageDiag': {
    'zh': '存储状态', 'zh_CN': '存储状态', 'en': 'Storage status',
    'de': 'Speicherstatus', 'es': 'Estado del almacenamiento', 'fr': 'État du stockage',
    'ja': 'ストレージ状態', 'ko': '저장소 상태', 'pt': 'Estado do armazenamento',
    'ru': 'Состояние хранилища', 'zh_TW': '儲存狀態'},
  'storageReprobe': {
    'zh': '重新探测', 'zh_CN': '重新探测', 'en': 'Re-probe',
    'de': 'Erneut prüfen', 'es': 'Volver a probar', 'fr': 'Retester',
    'ja': '再検出', 'ko': '다시 검사', 'pt': 'Testar novamente',
    'ru': 'Проверить снова', 'zh_TW': '重新探測'},
  'storageLevel': {
    'zh': '生效级别', 'zh_CN': '生效级别', 'en': 'Active level',
    'de': 'Aktive Stufe', 'es': 'Nivel activo', 'fr': 'Niveau actif',
    'ja': '有効レベル', 'ko': '활성 등급', 'pt': 'Nível ativo',
    'ru': 'Активный уровень', 'zh_TW': '生效級別'},
  'storageProbeLog': {
    'zh': '探测历史', 'zh_CN': '探测历史', 'en': 'Probe history',
    'de': 'Prüfverlauf', 'es': 'Historial de pruebas', 'fr': 'Historique des tests',
    'ja': '検出履歴', 'ko': '검사 기록', 'pt': 'Histórico de testes',
    'ru': 'Журнал проверок', 'zh_TW': '探測歷史'},
  'storageProbeRunning': {
    'zh': '正在探测…', 'zh_CN': '正在探测…', 'en': 'Probing…',
    'de': 'Wird geprüft…', 'es': 'Probando…', 'fr': 'Test en cours…',
    'ja': '検出中…', 'ko': '검사 중…', 'pt': 'Testando…',
    'ru': 'Проверка…', 'zh_TW': '正在探測…'},
  'storageProbeFailedShort': {
    'zh': '探测失败', 'zh_CN': '探测失败', 'en': 'Probe failed',
    'de': 'Prüfung fehlgeschlagen', 'es': 'Prueba fallida', 'fr': 'Test échoué',
    'ja': '検出失敗', 'ko': '검사 실패', 'pt': 'Falha no teste',
    'ru': 'Проверка не удалась', 'zh_TW': '探測失敗'},
  'goGrant': {
    'zh': '去授权', 'zh_CN': '去授权', 'en': 'Grant access',
    'de': 'Zugriff erteilen', 'es': 'Conceder acceso', 'fr': 'Autoriser l’accès',
    'ja': '許可する', 'ko': '권한 부여', 'pt': 'Conceder acesso',
    'ru': 'Разрешить доступ', 'zh_TW': '去授權'},
  'errorRetryHint': {
    'zh': '播放出错，可点重试', 'zh_CN': '播放出错，可点重试', 'en': 'Playback failed. Tap retry',
    'de': 'Wiedergabefehler. Zum Wiederholen tippen', 'es': 'Error de reproducción. Toca reintentar',
    'fr': 'Échec de lecture. Touchez Réessayer', 'ja': '再生エラー。再試行をタップ',
    'ko': '재생 오류. 다시 시도를 누르세요', 'pt': 'Falha na reprodução. Toque em tentar novamente',
    'ru': 'Ошибка воспроизведения. Нажмите «Повторить»', 'zh_TW': '播放出錯，可點重試'},
  'loadingStream': {
    'zh': '正在连接…', 'zh_CN': '正在连接…', 'en': 'Connecting…',
    'de': 'Verbindung…', 'es': 'Conectando…', 'fr': 'Connexion…',
    'ja': '接続中…', 'ko': '연결 중…', 'pt': 'Conectando…',
    'ru': 'Подключение…', 'zh_TW': '正在連接…'},
  'bufferingStream': {
    'zh': '缓冲中…', 'zh_CN': '缓冲中…', 'en': 'Buffering…',
    'de': 'Puffert…', 'es': 'Almacenando en búfer…', 'fr': 'Mise en mémoire tampon…',
    'ja': 'バッファ中…', 'ko': '버퍼링 중…', 'pt': 'Armazenando em buffer…',
    'ru': 'Буферизация…', 'zh_TW': '緩衝中…'},
}
# C-55：fr.notPlaying 语义反转修复
FIX_NOTPLAYING = {'fr': 'Lecture non active'}
# C-56：addToPlaylist 语义澄清（zh 收藏→收藏到歌单，en Save→Add to playlist）
FIX_ADD = {
  'zh': '收藏到歌单', 'zh_CN': '收藏到歌单', 'zh_TW': '收藏到歌單',
  'en': 'Add to playlist', 'de': 'Zur Playlist hinzufügen',
  'es': 'Añadir a playlist', 'fr': 'Ajouter à la playlist',
  'ja': 'プレイリストに追加', 'ko': '재생목록에 추가',
  'pt': 'Adicionar à playlist', 'ru': 'В плейлист',
}
META = {
  'storageDiag': '设置 → 存储状态诊断页入口标题',
  'storageReprobe': '诊断页：一键重新探测按钮（loading 态禁点）',
  'storageLevel': '诊断页：当前生效回退级别标签',
  'storageProbeLog': '诊断页：五级探测历史区标题',
  'storageProbeRunning': '诊断页：探测进行中文案',
  'storageProbeFailedShort': '诊断页：探测失败短文案（详情见日志）',
  'goGrant': '诊断页/设置页：跳系统授权页按钮',
  'errorRetryHint': '播放页：错误横幅主文案（发生了什么+下一步）',
  'loadingStream': '播放页：resolve 阶段指示文案',
  'bufferingStream': '播放页：缓冲阶段指示文案',
}

def dump(d):
    return json.dumps(d, ensure_ascii=False, indent=2)

for loc in ['zh','zh_CN','en','de','es','fr','ja','ko','pt','ru','zh_TW']:
    p = f'lib/l10n/app_{loc}.arb'
    with open(p, encoding='utf-8') as f:
        d = json.load(f, object_pairs_hook=collections.OrderedDict)
    for k, m in NEW.items():
        d[k] = m[loc]
        if loc == 'zh_CN':
            d['@' + k] = {'description': META[k]}
    if loc in FIX_NOTPLAYING:
        d['notPlaying'] = FIX_NOTPLAYING[loc]
    d['addToPlaylist'] = FIX_ADD[loc]
    with open(p, 'w', encoding='utf-8') as f:
        f.write(dump(d) + '\n')
    print(loc, 'ok', len([k for k in d if not k.startswith('@')]), 'keys')
print('done')
