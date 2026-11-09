#!/usr/bin/env python3
"""V399-B3/B2：11 语言 ARB 补键（音质新档 + 存储探测失败提示）。"""
import json, os

ARB = 'lib/l10n'
KEYS = {
  "qualityViperTape": "Viper 磁带",
  "qualityViperClear": "Viper 清澈",
  "qualityViperAtmos": "Viper 全景",
  "qualityMagicPiano": "魔法钢琴",
  "qualityMagicAcappella": "魔法清唱",
  "qualityMagicDj": "魔法DJ",
  "qualityMagicSurnay": "魔法环绕",
  "qualityMagicSubwoofer": "魔法低音",
  "qualityMagicAncient": "魔法复古",
  "storageProbeFailed": "写入探测失败",
}
TR = {
 'zh': {},
 'zh_CN': {},
 'zh_TW': {
   "qualityMagicPiano": "魔法鋼琴", "qualityMagicAcappella": "魔法清唱",
   "qualityMagicAncient": "魔法復古", "storageProbeFailed": "寫入探測失敗",
   "qualityMagicDj": "魔法DJ", "qualityMagicSurnay": "魔法環繞",
   "qualityMagicSubwoofer": "魔法低音",
 },
 'en': {
   "qualityViperTape": "Viper Tape", "qualityViperClear": "Viper Clear",
   "qualityViperAtmos": "Viper Atmos", "qualityMagicPiano": "Magic Piano",
   "qualityMagicAcappella": "Magic Acapella", "qualityMagicDj": "Magic DJ",
   "qualityMagicSurnay": "Magic Surround", "qualityMagicSubwoofer": "Magic Bass",
   "qualityMagicAncient": "Magic Vintage", "storageProbeFailed": "Write probe failed",
 },
 'ja': {
   "qualityViperTape": "Viper テープ", "qualityViperClear": "Viper クリア",
   "qualityViperAtmos": "Viper Atmos", "qualityMagicPiano": "魔法ピアノ",
   "qualityMagicAcappella": "魔法アカペラ", "qualityMagicDj": "魔法DJ",
   "qualityMagicSurnay": "魔法サラウンド", "qualityMagicSubwoofer": "魔法低音",
   "qualityMagicAncient": "魔法レトロ", "storageProbeFailed": "書き込み検出失敗",
 },
 'ko': {
   "qualityViperTape": "Viper 테이프", "qualityViperClear": "Viper 클리어",
   "qualityViperAtmos": "Viper Atmos", "qualityMagicPiano": "매직 피아노",
   "qualityMagicAcappella": "매직 아카펠라", "qualityMagicDj": "매직 DJ",
   "qualityMagicSurnay": "매직 서라운드", "qualityMagicSubwoofer": "매직 베이스",
   "qualityMagicAncient": "매직 빈티지", "storageProbeFailed": "쓰기 탐지 실패",
 },
 'de': {
   "qualityViperTape": "Viper Band", "qualityViperClear": "Viper Klar",
   "qualityViperAtmos": "Viper Atmos", "qualityMagicPiano": "Magisches Klavier",
   "qualityMagicAcappella": "Magischer A-cappella", "qualityMagicDj": "Magischer DJ",
   "qualityMagicSurnay": "Magischer Surround", "qualityMagicSubwoofer": "Magischer Bass",
   "qualityMagicAncient": "Magisch Vintage", "storageProbeFailed": "Schreibtest fehlgeschlagen",
 },
 'fr': {
   "qualityViperTape": "Viper Bande", "qualityViperClear": "Viper Clair",
   "qualityViperAtmos": "Viper Atmos", "qualityMagicPiano": "Piano magique",
   "qualityMagicAcappella": "A-cappella magique", "qualityMagicDj": "DJ magique",
   "qualityMagicSurnay": "Surround magique", "qualityMagicSubwoofer": "Basses magiques",
   "qualityMagicAncient": "Vintage magique", "storageProbeFailed": "Test d'écriture échoué",
 },
 'es': {
   "qualityViperTape": "Viper Cinta", "qualityViperClear": "Viper Claro",
   "qualityViperAtmos": "Viper Atmos", "qualityMagicPiano": "Piano mágico",
   "qualityMagicAcappella": "A capela mágico", "qualityMagicDj": "DJ mágico",
   "qualityMagicSurnay": "Sonido envolvente mágico", "qualityMagicSubwoofer": "Bajos mágicos",
   "qualityMagicAncient": "Vintage mágico", "storageProbeFailed": "Prueba de escritura fallida",
 },
 'pt': {
   "qualityViperTape": "Viper Fita", "qualityViperClear": "Viper Claro",
   "qualityViperAtmos": "Viper Atmos", "qualityMagicPiano": "Piano mágico",
   "qualityMagicAcappella": "A capela mágico", "qualityMagicDj": "DJ mágico",
   "qualityMagicSurnay": "Surround mágico", "qualityMagicSubwoofer": "Graves mágicos",
   "qualityMagicAncient": "Vintage mágico", "storageProbeFailed": "Teste de gravação falhou",
 },
 'ru': {
   "qualityViperTape": "Viper Лента", "qualityViperClear": "Viper Чистый",
   "qualityViperAtmos": "Viper Atmos", "qualityMagicPiano": "Волшебное пианино",
   "qualityMagicAcappella": "Волшебное а капелла", "qualityMagicDj": "Волшебный DJ",
   "qualityMagicSurnay": "Волшебный объёмный звук", "qualityMagicSubwoofer": "Волшебные басы",
   "qualityMagicAncient": "Волшебный ретро", "storageProbeFailed": "Ошибка проверки записи",
 },
}

def insert_after(d, key, after, val):
    """把 key 插到 after 之后（保持文件尾部风格：直接追加亦可）。"""
    d[key] = val

for loc, tr in TR.items():
    path = os.path.join(ARB, f'app_{loc}.arb')
    with open(path, encoding='utf-8') as f:
        raw = f.read()
    d = json.loads(raw)
    for k, default in KEYS.items():
        if k in d:
            continue
        d[k] = tr.get(k, default)
    # 保持插入位置在文件末尾（与原文件风格一致，JSON 无序依赖）
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'{loc}: +{len(KEYS)} keys')
