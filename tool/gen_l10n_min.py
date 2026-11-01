#!/usr/bin/env python3
"""Minimal offline ARB → app_localizations.dart generator.

Emits a lookup-map based AppLocalizations (same public API shape as
flutter gen-l10n: `comments`, `repliesCount(count)`, ...), with
per-locale overrides falling back to the template (zh_CN).
Placeholders are substituted at runtime via simple string replace,
so no intl dependency is required.
"""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
OUT = os.path.join(ARB_DIR, 'app_localizations.dart')

def load(fname):
    with open(os.path.join(ARB_DIR, fname), encoding='utf-8') as f:
        return json.load(f)

def main():
    template = load('app_zh_CN.arb')
    keys = [k for k in template if not k.startswith('@')]

    locales = {}
    for f in sorted(os.listdir(ARB_DIR)):
        if f.startswith('app_') and f.endswith('.arb'):
            locales[f[4:-4]] = load(f)

    def esc(s):
        return s.replace('\\', '\\\\').replace("'", "\\'").replace('\n', '\\n').replace('$', r'\$')

    def sig(key):
        ph = template.get('@' + key, {}).get('placeholders', {})
        if not ph:
            return key
        params = ', '.join(f'{t} {p}' for p, t in ph.items())
        return f"{key}({params})"

    def call_expr(key):
        ph = list(template.get('@' + key, {}).get('placeholders', {}))
        if not ph:
            return f"_t('{key}')"
        args = '{' + ', '.join(f"'{p}': {p}" for p in ph) + '}'
        return f"_t('{key}').r({args})"

    out = []
    out.append('// GENERATED CODE - DO NOT MODIFY BY HAND (offline gen-l10n equivalent)')
    out.append('// See tool/gen_l10n_min.py — regenerates from lib/l10n/app_*.arb.')
    out.append("import 'package:flutter/foundation.dart';")
    out.append("import 'package:flutter/widgets.dart';")
    out.append('')
    out.append('// ---- generated message maps ----')

    # locale -> (key -> text)
    for locale, data in sorted(locales.items()):
        out.append(f"const _strings_{locale.replace('-', '_').replace('.','_')} = <String, String>{{")
        for k in keys:
            if k in data:
                out.append(f"  '{k}': '{esc(data[k])}',")
        out.append('};')
        out.append('')

    # template (zh_CN) map is fallback; ensure _strings_zh_CN exists
    out.append("const _template = _strings_zh_CN;")
    out.append('')
    out.append('class _Msg {')
    out.append('  _Msg(this.text);')
    out.append('  final String text;')
    out.append('  // 按占位符【名字】替换（与 flutter gen-l10n 语义一致，避免翻译调整')
    out.append('  // 占位符顺序后参数错位）。')
    out.append('  String r(Map<String, Object?> args) => text.replaceAllMapped(')
    out.append(r"        RegExp(r'\{(\w+)\}'),")
    out.append("        (m) => args[m.group(1)]?.toString() ?? m.group(0)!,")
    out.append('      );')
    out.append('}')
    out.append('')
    out.append('class AppLocalizations {')
    out.append('  AppLocalizations(this.locale);')
    out.append('  final Locale locale;')
    out.append('')
    out.append('  static AppLocalizations of(BuildContext context) {')
    out.append('    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;')
    out.append('  }')
    out.append('')
    out.append('  static const localizationsDelegates = _Delegate();')
    out.append('  static const supportedLocales = <Locale>[')
    for locale in sorted(locales):
        parts = locale.split('_')
        if len(parts) == 2:
            out.append(f"    Locale('{parts[0]}', '{parts[1]}'),")
        else:
            out.append(f"    Locale('{parts[0]}'),")
    out.append('  ];')
    out.append('')
    out.append("  static const _maps = <String, Map<String, String>>{")
    for locale in sorted(locales):
        v = locale.replace('-', '_')
        out.append(f"    '{locale}': _strings_{v},")
    out.append('  };')
    out.append('')
    out.append("  String _t(String key) {")
    out.append("    final lang = locale.languageCode;")
    out.append("    final country = locale.countryCode;")
    out.append("    final full = country == null || country.isEmpty ? lang : '${lang}_$country';")
    out.append("    return _maps[full]?[key] ?? _maps[lang]?[key] ?? _template[key] ?? key;")
    out.append('  }')
    out.append('')

    for k in keys:
        ph = template.get('@' + k, {}).get('placeholders', {})
        if ph:
            args = '{' + ', '.join(f"'{p}': {p}" for p in ph) + '}'
            items = list(ph.items())
            if len(items) == 1:
                (p0, meta0), = items
                t0 = meta0.get('type', 'Object') if isinstance(meta0, dict) else 'Object'
                out.append(f"  String {k}({t0} {p0}) => _t('{k}').r({args});")
            else:
                params = ', '.join(
                    f"{(m.get('type','Object') if isinstance(m, dict) else 'Object')} {p}"
                    for p, m in items)
                out.append(f"  String {k}({params}) => _t('{k}').r({args});")
        else:
            out.append(f"  String get {k} => _t('{k}');")
    out.append('}')
    out.append('')
    out.append('class _Delegate extends LocalizationsDelegate<AppLocalizations> {')
    out.append('  const _Delegate();')
    out.append('')
    out.append('  @override')
    out.append('  bool isSupported(Locale locale) => true;')
    out.append('')
    out.append('  @override')
    out.append('  Future<AppLocalizations> load(Locale locale) async {')
    out.append('    return SynchronousFuture<AppLocalizations>(AppLocalizations(locale));')
    out.append('  }')
    out.append('')
    out.append('  @override')
    out.append('  bool shouldReload(_Delegate old) => false;')
    out.append('}')

    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out) + '\n')
    print(f'wrote {OUT}: {len(keys)} keys, {len(locales)} locales')

if __name__ == '__main__':
    main()
