#!/usr/bin/env python3
"""V400-A-02: 按钮文案精简，只改 11 个 arb 的值（键集与结构不动）。
V400-A-02
"""
import json, io

BASE = '/var/minis/workspace/TiernanMusic/lib/l10n/'
FILES = ['app_de.arb','app_en.arb','app_es.arb','app_fr.arb','app_ja.arb',
         'app_ko.arb','app_pt.arb','app_ru.arb','app_zh.arb','app_zh_CN.arb','app_zh_TW.arb']

# 每语言新值（ addToPlaylist: 收藏（同 favorite），与 mvCollectAdd 以图标区分）
V = {
 'app_de.arb': {'addToPlaylist':'Merken','mvCollectAdd':'Merken','mvCollectRemove':'Entfernen',
   'downloadMv':'MV','downloadLyric':'Text','downloadCover':'Cover','downloadSong':'Lied',
   'showCover':'Cover','showLyrics':'Text','playAll':'Alle','playMv':'MV'},
 'app_en.arb': {'addToPlaylist':'Save','mvCollectAdd':'Save','mvCollectRemove':'Remove',
   'downloadMv':'MV','downloadLyric':'Lyrics','downloadCover':'Cover','downloadSong':'Song',
   'showCover':'Cover','showLyrics':'Lyrics','playAll':'Play all','playMv':'MV'},
 'app_es.arb': {'addToPlaylist':'Guardar','mvCollectAdd':'Guardar','mvCollectRemove':'Quitar',
   'downloadMv':'MV','downloadLyric':'Letra','downloadCover':'Portada','downloadSong':'Canción',
   'showCover':'Portada','showLyrics':'Letra','playAll':'Todo','playMv':'MV'},
 'app_fr.arb': {'addToPlaylist':'Ajouter','mvCollectAdd':'Ajouter','mvCollectRemove':'Retirer',
   'downloadMv':'Clip','downloadLyric':'Paroles','downloadCover':'Pochette','downloadSong':'Chanson',
   'showCover':'Pochette','showLyrics':'Paroles','playAll':'Tout','playMv':'Clip'},
 'app_ja.arb': {'addToPlaylist':'保存','mvCollectAdd':'保存','mvCollectRemove':'解除',
   'downloadMv':'MV','downloadLyric':'歌詞','downloadCover':'カバー','downloadSong':'曲',
   'showCover':'カバー','showLyrics':'歌詞','playAll':'全再生','playMv':'MV'},
 'app_ko.arb': {'addToPlaylist':'담기','mvCollectAdd':'담기','mvCollectRemove':'해제',
   'downloadMv':'MV','downloadLyric':'가사','downloadCover':'커버','downloadSong':'곡',
   'showCover':'커버','showLyrics':'가사','playAll':'전체','playMv':'MV'},
 'app_pt.arb': {'addToPlaylist':'Salvar','mvCollectAdd':'Salvar','mvCollectRemove':'Remover',
   'downloadMv':'MV','downloadLyric':'Letra','downloadCover':'Capa','downloadSong':'Música',
   'showCover':'Capa','showLyrics':'Letra','playAll':'Tudo','playMv':'MV'},
 'app_ru.arb': {'addToPlaylist':'В плейлист','mvCollectAdd':'В избранное','mvCollectRemove':'Убрать',
   'downloadMv':'Клип','downloadLyric':'Текст','downloadCover':'Обложка','downloadSong':'Песня',
   'showCover':'Обложка','showLyrics':'Текст','playAll':'Все','playMv':'Клип'},
 'app_zh.arb': {'addToPlaylist':'收藏','mvCollectAdd':'收藏','mvCollectRemove':'取消',
   'downloadMv':'MV','downloadLyric':'歌词','downloadCover':'封面','downloadSong':'歌曲',
   'showCover':'封面','showLyrics':'歌词','playAll':'全播','playMv':'MV'},
 'app_zh_CN.arb': {'addToPlaylist':'收藏','mvCollectAdd':'收藏','mvCollectRemove':'取消',
   'downloadMv':'MV','downloadLyric':'歌词','downloadCover':'封面','downloadSong':'歌曲',
   'showCover':'封面','showLyrics':'歌词','playAll':'全播','playMv':'MV'},
 'app_zh_TW.arb': {'addToPlaylist':'收藏','mvCollectAdd':'收藏','mvCollectRemove':'取消',
   'downloadMv':'MV','downloadLyric':'歌詞','downloadCover':'封面','downloadSong':'歌曲',
   'showCover':'封面','showLyrics':'歌詞','playAll':'全播','playMv':'MV'},
}

for fn in FILES:
    path = BASE + fn
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
    before_keys = [k for k in data if not k.startswith('@')]
    for k, v in V[fn].items():
        assert k in data, f'{fn} 缺键 {k}'
        assert data[k] != '' or True
        data[k] = v
    after_keys = [k for k in data if not k.startswith('@')]
    assert before_keys == after_keys, f'{fn} 键集变化!'
    # 保留原有顺序写回（json.load 保序）
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'{fn}: 11 值已改, 键数 {len(after_keys)} 不变')
print('V400-A-02 done')
