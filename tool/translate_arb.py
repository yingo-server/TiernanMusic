#!/usr/bin/env python3
"""
从简中 ARB 生成 9 种目标语言 ARB（并发版）。
- 已存在的 key 保留人工修订，不覆盖。
- 多线程并发翻译，实时进度条。
- 失败自动重试，断点续传（增量翻译）。

用法：
  python3 tool/translate_arb.py                # 增量翻译全部语言
  python3 tool/translate_arb.py --force        # 强制重新翻译
  python3 tool/translate_arb.py --lang en,ja   # 只翻译指定语言
  python3 tool/translate_arb.py --workers 8    # 自定义并发数
"""

import argparse
import json
import sys
import threading
import time
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

API = "https://index-translate.bilibili.com/v1/chat/completions"
MODEL = "Index-Translate-35B-A3B"

# B 站 WAF 会拦截无 UA 请求（412），必须带浏览器 UA
HEADERS = {
    "Content-Type": "application/json",
    "User-Agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36",
}

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

MAX_RETRIES = 3
BATCH_SIZE = 10  # 每批翻译条数（批量效率高且不易触发风控）


class ProgressBar:
    """线程安全的进度条。"""

    def __init__(self, total: int, label: str, width: int = 40):
        self.total = max(total, 1)
        self.label = label
        self.width = width
        self.current = 0
        self.lock = threading.Lock()
        self.start = time.time()
        self.ok = 0
        self.fail = 0

    def update(self, success: bool = True, n: int = 1) -> None:
        with self.lock:
            self.current += n
            if success:
                self.ok += n
            else:
                self.fail += n
            self._render()

    def _render(self) -> None:
        ratio = min(self.current / self.total, 1.0)
        filled = int(self.width * ratio)
        bar = "█" * filled + "░" * (self.width - filled)
        elapsed = time.time() - self.start
        speed = self.current / elapsed if elapsed > 0 else 0
        eta = (self.total - self.current) / speed if speed > 0 else 0
        sys.stdout.write(
            f"\r  {self.label} |{bar}| "
            f"{self.current}/{self.total} ({ratio*100:.0f}%) "
            f"✓{self.ok} ✗{self.fail} "
            f"{speed:.1f}/s ETA {eta:.0f}s   "
        )
        sys.stdout.flush()

    def finish(self) -> None:
        self._render()
        sys.stdout.write("\n")
        sys.stdout.flush()


def translate_batch(lines: list[str], target_lang: str) -> list[str]:
    """批量翻译（一次请求多条，用换行分隔）。

    **多行文本（值里含 \\n）必须单独翻译**，否则响应按行切分后会与
    原列表错位，导致整批文案被写错 key。
    """
    # 先拆出含换行的条目，单独处理
    single: list[str] = []
    multi: list[tuple[int, str]] = []
    for i, line in enumerate(lines):
        if "\n" in line:
            multi.append((i, line))
        else:
            single.append(line)

    result: list[str] = [""] * len(lines)

    if single:
        for idx, txt in zip(
            [i for i, l in enumerate(lines) if "\n" not in l],
            _translate_lines(single, target_lang),
        ):
            result[idx] = txt

    for idx, txt in multi:
        result[idx] = _translate_block(txt, target_lang)

    return result


def _translate_lines(lines: list[str], target_lang: str) -> list[str]:
    """把若干条单行文案翻译为目标语言（严格按条对齐）。

    使用 **JSON 数组** 作为请求/响应格式：模型偶尔会多输出一行或漏掉一行，
    按行切分会导致整批文案**错位**（写到别的 key 上），JSON 数组可避免该问题。
    """
    prompt = (
        f"请将下面 JSON 数组里的 App 界面文案逐条翻译为{target_lang}。"
        f"只输出一个 JSON 字符串数组，元素个数与顺序必须与输入完全一致，"
        f"不要编号，不要解释，不要输出任何其它文字。"
        f"不要翻译品牌名。\n\n"
        + json.dumps(lines, ensure_ascii=False)
    )
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "max_tokens": 2048,
        "chat_template_kwargs": {"enable_thinking": False},
    }

    for attempt in range(MAX_RETRIES):
        try:
            req = urllib.request.Request(
                API,
                data=json.dumps(payload).encode(),
                headers=HEADERS,
            )
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.loads(resp.read())
            content = data["choices"][0]["message"]["content"].strip()
            parsed = _parse_json_array(content)
            if parsed is not None and len(parsed) == len(lines):
                return [
                    (parsed[i].strip() or lines[i]) if isinstance(parsed[i], str) else lines[i]
                    for i in range(len(lines))
                ]
            # 结构不对 → 重新请求
            if attempt < MAX_RETRIES - 1:
                time.sleep(1)
                continue
            break
        except urllib.error.HTTPError as e:
            if e.code == 412 and attempt < MAX_RETRIES - 1:
                time.sleep(2 * (attempt + 1))
                continue
            if attempt < MAX_RETRIES - 1:
                time.sleep(1)
                continue
            return lines  # 失败返回原文
        except Exception:
            if attempt < MAX_RETRIES - 1:
                time.sleep(1)
                continue
            return lines

    return lines


def _parse_json_array(content: str) -> list | None:
    """从模型输出里解析出 JSON 字符串数组（容忍 ```json 包裹）。"""
    text = content.strip()
    if text.startswith("```"):
        # ```json ... ```
        text = text.split("\n", 1)[-1] if "\n" in text else text
        if text.endswith("```"):
            text = text[:-3]
        text = text.strip()
    start = text.find("[")
    end = text.rfind("]")
    if start < 0 or end <= start:
        return None
    try:
        parsed = json.loads(text[start : end + 1])
    except Exception:
        return None
    if not isinstance(parsed, list):
        return None
    return parsed


def _translate_block(text: str, target_lang: str) -> str:
    """翻译一段可能含换行的文本（整体翻译，不再按行切分）。"""
    prompt = (
        f"请将以下 App 界面文案翻译为{target_lang}。"
        f"直接输出翻译结果，不要编号，不要解释，保留原有的换行结构。"
        f"不要翻译品牌名。\n\n{text}"
    )
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "max_tokens": 2048,
        "chat_template_kwargs": {"enable_thinking": False},
    }

    for attempt in range(MAX_RETRIES):
        try:
            req = urllib.request.Request(
                API,
                data=json.dumps(payload).encode(),
                headers=HEADERS,
            )
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.loads(resp.read())
            out = data["choices"][0]["message"]["content"].strip()
            if not out:
                return text
            return out
        except urllib.error.HTTPError as e:
            if e.code == 412 and attempt < MAX_RETRIES - 1:
                time.sleep(2 * (attempt + 1))
                continue
            if attempt < MAX_RETRIES - 1:
                time.sleep(1)
                continue
            return text
        except Exception:
            if attempt < MAX_RETRIES - 1:
                time.sleep(1)
                continue
            return text

    return text


def translate_language(
    code: str, name: str, texts: dict, meta: dict, root: Path, force: bool, workers: int
) -> None:
    target_path = root / "lib" / "l10n" / f"app_{code}.arb"
    existing = {}
    if target_path.exists() and not force:
        existing = json.loads(target_path.read_text(encoding="utf-8"))

    to_translate = [
        (k, v) for k, v in texts.items()
        if k not in existing or existing[k] != v
    ]

    if not to_translate:
        print(f"[{code}] 无需更新")
        return

    print(f"[{code}] 翻译 {len(to_translate)} 条（{workers} 并发）")

    result = dict(existing)
    result["@@locale"] = code

    # 分批
    batches = [
        to_translate[i : i + BATCH_SIZE]
        for i in range(0, len(to_translate), BATCH_SIZE)
    ]

    bar = ProgressBar(len(to_translate), code)

    def work(batch):
        keys = [k for k, _ in batch]
        values = [v for _, v in batch]
        translated = translate_batch(values, name)
        return keys, values, translated

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(work, b): b for b in batches}
        for future in as_completed(futures):
            keys, originals, translated = future.result()
            fail_count = sum(1 for o, t in zip(originals, translated) if o == t)
            for k, t in zip(keys, translated):
                result[k] = t
            bar.update(success=fail_count == 0, n=len(keys))

    bar.finish()

    output = dict(meta)
    output.update(result)
    target_path.write_text(
        json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"[{code}] ✓ 已写入")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--lang", help="只生成指定语言，逗号分隔")
    parser.add_argument("--workers", type=int, default=4, help="并发线程数（默认 4）")
    args = parser.parse_args()

    root = Path(__file__).parent.parent
    source = json.loads(
        (root / "lib" / "l10n" / "app_zh_CN.arb").read_text(encoding="utf-8")
    )

    texts = {k: v for k, v in source.items() if not k.startswith("@")}
    meta = {k: v for k, v in source.items() if k.startswith("@")}

    langs = LANGUAGES
    if args.lang:
        langs = {k: LANGUAGES[k] for k in args.lang.split(",") if k in LANGUAGES}

    start = time.time()
    for code, name in langs.items():
        translate_language(code, name, texts, meta, root, args.force, args.workers)

    print(f"\n全部完成，耗时 {time.time()-start:.1f}s")


if __name__ == "__main__":
    main()
