#!/usr/bin/env python3
"""
从简中 ARB 生成 9 种目标语言 ARB。
- 已存在的 key 保留人工修订，不覆盖。
- 缺失的 key 调用 Index-Translate API 生成。
- 元数据 key（@ 开头）不翻译。

用法：python3 tool/translate_arb.py [--force] [--lang zh_TW,en]
"""

import argparse
import json
import time
import urllib.request
from pathlib import Path

API = "https://index-translate.bilibili.com/v1/chat/completions"
MODEL = "Index-Translate-35B-A3B"

LANGUAGES = {
    "zh_TW": "繁体中文",
    "en": "English",
    "ja": "日本語",
    "ko": "한국어",
    "es": "Español",
    "fr": "Français",
    "de": "Deutsch",
    "pt": "Português",
    "ru": "Русский",
}

BATCH_SIZE = 20


def translate_batch(lines: list[str], target_lang: str) -> list[str]:
    """批量翻译，保留换行对齐。"""
    joined = "\n".join(lines)
    prompt = (
        f"请将以下文本翻译为{target_lang}，直接输出翻译结果，不要进行任何解释。"
        f"保持行数和换行不变。这是 App 界面文案，保持简洁。\n\n{joined}"
    )
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "max_tokens": 4096,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(
        API,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.loads(resp.read())
    content = data["choices"][0]["message"]["content"]
    translated = content.split("\n")
    return [
        translated[i].strip() if i < len(translated) else lines[i]
        for i in range(len(lines))
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true", help="强制重新翻译所有")
    parser.add_argument("--lang", help="只生成指定语言，逗号分隔")
    args = parser.parse_args()

    root = Path(__file__).parent.parent
    source_path = root / "lib" / "l10n" / "app_zh_CN.arb"
    source = json.loads(source_path.read_text(encoding="utf-8"))

    # 分离元数据和文案
    texts = {k: v for k, v in source.items() if not k.startswith("@")}
    meta = {k: v for k, v in source.items() if k.startswith("@")}

    langs = LANGUAGES
    if args.lang:
        langs = {k: LANGUAGES[k] for k in args.lang.split(",") if k in LANGUAGES}

    for code, name in langs.items():
        target_path = root / "lib" / "l10n" / f"app_{code}.arb"
        existing = {}
        if target_path.exists() and not args.force:
            existing = json.loads(target_path.read_text(encoding="utf-8"))

        # 找出需要翻译的 key
        to_translate = []
        for key, value in texts.items():
            if key not in existing or existing[key] != value:
                to_translate.append((key, value))

        if not to_translate:
            print(f"[{code}] 无需更新")
            continue

        print(f"[{code}] 需要翻译 {len(to_translate)} 条")

        # 分批翻译
        result = dict(existing)
        result["@@locale"] = code

        for i in range(0, len(to_translate), BATCH_SIZE):
            batch = to_translate[i : i + BATCH_SIZE]
            keys = [k for k, _ in batch]
            values = [v for _, v in batch]
            try:
                translated = translate_batch(values, name)
                for k, t in zip(keys, translated):
                    result[k] = t
                print(f"  批次 {i // BATCH_SIZE + 1}: {len(batch)} 条完成")
                time.sleep(0.5)
            except Exception as e:
                print(f"  批次 {i // BATCH_SIZE + 1} 失败: {e}")
                # 失败保留原文
                for k, v in batch:
                    result[k] = v

        # 写入
        output = dict(meta)
        output.update(result)
        target_path.write_text(
            json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"[{code}] 已写入 {target_path}")


if __name__ == "__main__":
    main()
