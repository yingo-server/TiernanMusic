# v33 第 3 批审查②：用户路径回归复核

依据：docs/QUALITY_STANDARD.md（33 条）。证据等级：**实测 / 静态推导 / 推测**（推测不作依据）。
范围：用户三条实测反馈全链路。只读，未修改代码。

---

## 反馈①：歌单仅首次登录能加载

链路：library_page `_userPlaylistsProvider` → playlist_repository.fetchUserPlaylists → kg_endpoints_playlist.userPlaylist → 签名 → gateway。
