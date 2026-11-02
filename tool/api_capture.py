#!/usr/bin/env python3
"""API 三态样本采集器。

用途
----
对 App 实际使用的每个接口，采集**匿名 / 非VIP / VIP** 三种登录态的真实返回，
落盘到 docs/api_samples/<接口名>/<state>.json，并生成 INDEX.md 归档调用方式。

为什么需要
----------
酷狗各接口的「成功语义」并不统一（status=1 / status=200 / errcode 151/152/200
都可能是成功），字段结构也随登录态变化。凭猜测写解析代码必然出错。
把三态真实样本固化下来，才能：
  1) 实现时逐字段对照，而不是猜；
  2) 回归时对比结构是否漂移；
  3) 明确哪些接口匿名不可用、哪些只是参数问题。

用法
----
    python3 tool/api_capture.py --state anon
    python3 tool/api_capture.py --state nonvip --cookie /path/cookies.txt
    python3 tool/api_capture.py --state vip    --cookie /path/cookies.txt
    python3 tool/api_capture.py --all          # 三态全跑（需两个 cookie 文件）

cookie 文件格式：curl 的 Netscape cookie jar（curl -c 生成）或
`token=xxx; userid=yyy` 单行文本。
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

BASE = "https://kapi.344977.xyz"
OUT_ROOT = os.path.join(os.path.dirname(__file__), "..", "docs", "api_samples")
UA = ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36")

# 实测可用的固定样本（免费曲 / VIP 曲 / 公共歌单 / MV）
FREE_HASH = "9839C10AB3BE538976A3D1157B3707DB"      # 免费曲
FREE_ALBUM = "212744061"
FREE_AAID = "979006105"
VIP_HASH = "B3A52A7A958BF0AED0EBFBA2E9A818B7"        # 周杰伦《晴天》
VIP_ALBUM = "966846"
VIP_AAID = "32100650"
GID = "collection_3_520033052_181_0"                 # 公共歌单（516 首）
MV_ID = "117613"

# 接口清单：name -> (HTTP 方法, 路径, 查询参数, 成功判定说明)
SPECS = [
    ("search_song", "GET", "/search",
     {"keywords": "晴天", "type": "song", "page": 1, "pagesize": 5},
     "status=1 + data.lists[]"),
    ("search_album", "GET", "/search",
     {"keywords": "晴天", "type": "album", "page": 1, "pagesize": 3},
     "status=1 + data.lists[]"),
    ("search_special", "GET", "/search",
     {"keywords": "流行", "type": "special", "page": 1, "pagesize": 3},
     "status=1 + data.lists[]（gid 字段）"),
    ("search_author", "GET", "/search",
     {"keywords": "周杰伦", "type": "author", "page": 1, "pagesize": 3},
     "status=1 + data.lists[]"),
    ("search_mv", "GET", "/search",
     {"keywords": "晴天", "type": "mv", "page": 1, "pagesize": 3},
     "status=1 + data.lists[]（MvHash 才是视频 hash）"),
    ("search_hot", "GET", "/search/hot", {}, "status=1 + data.list[]"),
    ("search_suggest", "GET", "/search/suggest", {"keywords": "周杰"}, "data[].RecordDatas[].HintInfo"),
    ("search_lyric", "GET", "/search/lyric",
     {"hash": VIP_HASH, "album_audio_id": VIP_AAID, "duration": 269, "man": "yes"},
     "**status=200 + errcode=200（成功，不是错误）** + candidates[]"),
    ("lyric", "GET", "/lyric",
     {"id": "274944371", "accesskey": "2A7B35884B3C20E9D3281686BA59A3F8",
      "fmt": "krc", "decode": "true"},
     "status=1 + decodeContent / content(base64 加密 KRC)"),
    ("song_url", "GET", "/song/url",
     {"hash": FREE_HASH, "album_id": FREE_ALBUM, "album_audio_id": FREE_AAID,
      "quality": "128"},
     "status=1 + data.url[]（数组）；VIP 曲匿名 status=2"),
    ("song_url_vip", "GET", "/song/url",
     {"hash": VIP_HASH, "album_id": VIP_ALBUM, "album_audio_id": VIP_AAID,
      "quality": "128"},
     "匿名 status=2 fail_process=[pkg,buy]；加 free_part=1 得 60 秒试听"),
    ("privilege_lite", "GET", "/privilege/lite",
     {"hash": FREE_HASH, "album_id": FREE_ALBUM, "qualities": "128,320,flac,high"},
     "status=1 + data[]（relate_goods 内才是各档权益）"),
    ("kmr_audio_mv", "GET", "/kmr/audio/mv",
     {"album_audio_id": VIP_AAID, "fields": "mkv,tags,h264,h265,authors"},
     "status=1 + data[0] 为数组"),
    ("video_detail", "GET", "/video/detail", {"id": MV_ID},
     "status=1 + data[]（首项为视频对象，hash 平铺顶层）"),
    ("video_url", "GET", "/video/url", {"hash": "C95D2E0D2A3B4B7B0F2E5E9C1A2B3C4D"},
     "status=1 + data[<hash小写>].downurl"),
    ("playlist_detail", "GET", "/playlist/detail", {"ids": GID},
     "status=1 + data[]（首项）；数字 id → data:{}"),
    ("playlist_track_all", "GET", "/playlist/track/all",
     {"id": GID, "page": 1, "pagesize": 5},
     "status=1 + data.songs[] + data.count"),
    ("top_playlist", "GET", "/top/playlist",
     {"category_id": 0, "withsong": 1, "withtag": 1, "page": 1, "pagesize": 5},
     "status=1 + data.special_list[]（global_collection_id）"),
    ("top_song", "GET", "/top/song", {"type": 21608, "page": 1, "pagesize": 5},
     "status=1 + data[]（新歌）"),
    ("rank_list", "GET", "/rank/list", {"withsong": 1}, "status=1 + data.info[]"),
    ("yueku", "GET", "/yueku", {}, "status=1 + data.info.{song,recommend}"),
    ("yueku_banner", "GET", "/yueku/banner", {}, "实测 error_code=31136（上游无数据）"),
    ("everyday_recommend", "GET", "/everyday/recommend", {"platform": "android"},
     "需登录；匿名 status=0 error_code=200103（缺 platform 参数时也是 200103）"),
    ("comment_music", "GET", "/comment/music",
     {"mixsongid": VIP_AAID, "page": 1, "pagesize": 3}, "status=1 + 顶层 list[]"),
    ("comment_count", "GET", "/comment/count", {"hash": VIP_HASH},
     "裸 Map {\"<hash>\": n}（无 status 包裹）"),
    ("comment_floor", "GET", "/comment/floor",
     {"special_id": "20505418", "mixsongid": VIP_AAID, "tid": "1"},
     "status=1 + 顶层 list[]"),
    ("comment_playlist", "GET", "/comment/playlist",
     {"id": GID, "page": 1, "pagesize": 3}, "status=1 + 顶层 list[]"),
    ("register_dev", "GET", "/register/dev", {}, "status=1 + data.dfid"),
    ("user_detail", "GET", "/user/detail", {},
     "需登录：status=1 + nickname/pic（无 userid）"),
    ("user_playlist", "GET", "/user/playlist", {"page": 1, "pagesize": 5},
     "需登录：status=1 + data.info[]"),
    ("get_verify_info", "GET", "/get/verify/info",
     {"eventid": "gz_tx_event_invalid_sample"}, "无效 eventid → 36001（仅验证连通）"),
]


def load_cookie(path):
    if not path or not os.path.exists(path):
        return ""
    raw = open(path, "r", errors="ignore").read()
    if ";" in raw and "\t" not in raw:
        return raw.strip()
    pairs = []
    for line in raw.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) >= 7:
            pairs.append(f"{parts[5]}={parts[6]}")
    return "; ".join(pairs)


def fetch(method, path, params, cookie):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    headers = {"User-Agent": UA}
    if cookie:
        headers["Cookie"] = cookie
    req = urllib.request.Request(url, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            body = r.read().decode("utf-8", errors="replace")
            status = r.status
    except Exception as e:  # noqa: BLE001
        return {"_http_error": str(e)}, 0
    try:
        return json.loads(body), status
    except json.JSONDecodeError:
        return {"_raw": body[:2000]}, status


def classify(doc):
    """按实测口径判定成功/失败，写进样本便于后续对照。"""
    if not isinstance(doc, dict):
        return "unknown"
    if "_http_error" in doc:
        return "http_error"
    status = doc.get("status")
    code = doc.get("error_code", doc.get("errcode"))
    if status in (1, 200) and code in (None, 0, 151, 152, 200, 201):
        return "ok"
    if code == 20028:
        return "needs_verification"
    if status in (0, 2):
        return "failed"
    return "unknown"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", default="anon", choices=["anon", "nonvip", "vip"])
    ap.add_argument("--cookie", default="")
    ap.add_argument("--all", action="store_true")
    args = ap.parse_args()

    states = []
    if args.all:
        states = [("anon", ""),
                  ("nonvip", os.environ.get("NONVIP_COOKIE", "")),
                  ("vip", os.environ.get("VIP_COOKIE", ""))]
    else:
        states = [(args.state, load_cookie(args.cookie))]

    os.makedirs(OUT_ROOT, exist_ok=True)
    index_lines = ["# API 三态样本索引", "",
                   "自动生成，勿手改。每行对应 `docs/api_samples/<name>/<state>.json`。", "",
                   "| 接口 | 方法 | 路径 | 关键参数 | 成功判定 | anon | nonvip | vip |",
                   "|---|---|---|---|---|---|---|---|"]

    for state, cookie in states:
        if state != "anon" and not cookie:
            print(f"[{state}] 无 cookie，跳过")
            continue
        for name, method, path, params, expect in SPECS:
            d = os.path.join(OUT_ROOT, name)
            os.makedirs(d, exist_ok=True)
            doc, http = fetch(method, path, params, cookie)
            verdict = classify(doc)
            sample = {
                "_meta": {
                    "endpoint": path,
                    "method": method,
                    "base": BASE,
                    "params": params,
                    "state": state,
                    "http": http,
                    "verdict": verdict,
                    "expect": expect,
                    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                },
                "response": doc,
            }
            with open(os.path.join(d, f"{state}.json"), "w") as f:
                json.dump(sample, f, ensure_ascii=False, indent=2)
            print(f"[{state}] {name:22s} http={http} {verdict}")
            time.sleep(0.15)

    # 汇总索引
    for name, method, path, params, expect in SPECS:
        marks = []
        for st in ("anon", "nonvip", "vip"):
            p = os.path.join(OUT_ROOT, name, f"{st}.json")
            if os.path.exists(p):
                try:
                    v = json.load(open(p))["_meta"]["verdict"]
                except Exception:  # noqa: BLE001
                    v = "?"
                marks.append(v)
            else:
                marks.append("—")
        key = ", ".join(f"{k}={v}" for k, v in params.items() if k in
                        ("keywords", "type", "hash", "id", "ids", "mixsongid",
                         "album_audio_id", "quality", "page", "platform"))
        index_lines.append(
            f"| {name} | {method} | `{path}` | `{key}` | {expect} | "
            + " | ".join(marks) + " |")

    with open(os.path.join(OUT_ROOT, "INDEX.md"), "w") as f:
        f.write("\n".join(index_lines) + "\n")
    print(f"\n索引已写入 {os.path.join(OUT_ROOT, 'INDEX.md')}")


if __name__ == "__main__":
    sys.exit(main())
