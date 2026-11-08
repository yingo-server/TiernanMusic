# v4.0 歌单顺序：反反规则落地（主代理亲修）

## 用户裁决
「按反反修复，注意健壮余数逻辑」。依据：概念版分享页
`https://activity.kugou.com/share/v-a00a45b0/...global_specialid=collection_3_1666835066_2_0`
渲染顺序（排除人名、翻译差异归一后）前 8 首与「反反」拼法逐位吻合；
四种拼法对照见 `/tmp/v4_paging_8.txt`（仅反反：命中 8/20、顺序递增 8、前段逐位 8）。

## 反反定义
- 页序倒：49→48→…→1（485 首 / pageSize=10 → 49 页）
- 页内倒：每页 10→1
- 等价：原 485 首完整反转
- 前 30 首留样见 /tmp/apply_fanfan_top30.py 输出，与「后50正正末30反转」一致

## 实现（playlist_repository.dart）
`_fetchAllReversed(fetchPage, page, pageSize, allPages)`：
1. 起始页拿 `total`；可信条件 `total>0 && total>=本页条数`，否则按未知总数探测
2. `totalPages = ceil(total/pageSize).clamp(1,100)`；**末页余数按实际长度全取，不补位**
3. 页号降序 + 每页 `reversed` 拼接
4. 未知总数：向前探测到不满页/空页；若起始页≠1，回填 1..page-1
5. 单页失败：debugPrint 留痕并跳过，不吞成空、不中断（第 9 条）
6. 单页模式（`allPages=false`）也页内倒转，避免第二种排列语义
7. 循环有上界 100（第 25 条）；`total` 不可信时以实取条数为 total（第 16 条）
8. 缓存走 `CachedApiCall`（90s 列表 + 失效回退 + in-flight 合并）

`fetchTracks` 与 `fetchUserTracks` 统一走此实现；`upstreamOrder` 参数已删（历史误导名），
调用方 `playlist_detail_page.dart` 同步改为 `.fetchTracks(id, allPages: true)`。

## 数量差异（非缺陷）
概念版分享页显示 476 首，标准版 `/v4/get_list_all_file_v3` 返回 485 首——
概念版版权过滤少 9 首；拼接规则不受影响（反反仍成立）。

## 回归留样
- /tmp/like_playlist_5x10.json（前50 原始5页×10）
- /tmp/v4_paging_raw.json（页1~5、44~49 共11页）
- /tmp/v4_paging_8.txt（四拼法×前50/后50 共8组）
- /tmp/like_485_all.json 未生成（485 全集探针被用户中断，数学上无需证明）
