# Tiernan Music · 汀澜音乐

> 非官方酷狗音乐第三方 Android 客户端，基于 Flutter 构建。

[![Build](https://github.com/yingo-server/TiernanMusic/actions/workflows/build.yml/badge.svg)](https://github.com/yingo-server/TiernanMusic/actions/workflows/build.yml)

## 特性

- 🎵 **完整音乐体验**：搜索、播放、歌单、收藏、评论、MV
- 🎨 **Material 3 Expressive**：深色默认、封面动态取色、纯黑模式
- 🔐 **多账号管理**：手机号/密码、酷狗二维码登录，人机验证自动处理
- 📝 **KRC 逐字歌词**：客户端解密、逐字时间轴、逐行翻译（原文/双语/译文）
- 🌐 **10 种语言**：简中、繁中、英、日、韩、西、法、德、葡、俄
- 📦 **智能缓存**：音频/图片/视频持久缓存，其他数据 90s 内存缓存
- 🎬 **MV 播放**：代理转发 HTTP 流，无需 cleartext

## 技术栈

- **框架**：Flutter 3.x + Riverpod + GoRouter
- **音频**：just_audio_background（通知栏 + 耳机控制）
- **网络**：dio（统一 Cookie/Token/timestamp）
- **存储**：flutter_secure_storage（凭证）+ hive（缓存）
- **人机验证**：flutter_inappwebview（腾讯 TCaptcha JS 桥接）
- **构建**：GitHub Actions（本地无 Flutter 环境）

## 项目结构

```
lib/
├── core/               # 基础设施
│   ├── api/            # API 客户端（KugouApi, TranslateApi）
│   ├── cache/          # 缓存管理（音频/图片/视频/内存）
│   ├── config/         # 常量、环境配置
│   ├── router/         # GoRouter 路由
│   ├── storage/        # 安全存储、Hive
│   └── theme/          # Material 3 主题
├── features/           # 功能模块
│   ├── auth/           # 登录、多账号、人机验证
│   ├── home/           # 首页聚合
│   ├── search/         # 搜索
│   ├── player/         # 播放器、队列、后台
│   ├── playlist/       # 歌单
│   ├── favorite/       # 收藏
│   ├── comment/        # 评论
│   ├── mv/             # MV
│   ├── lyric/          # KRC 解析、翻译
│   └── settings/       # 设置
├── l10n/               # 国际化
└── main.dart
```

## 许可证

**源代码可见，但禁止任何使用、复制、修改、分发。**  
详见 [LICENSE](LICENSE)。

Copyright © 2026 yingo-server. All rights reserved.
