class AppConfig {
  AppConfig._();

  static const String appName = 'Tiernan Music';
  static const String appNameCn = '汀澜音乐';
  static const String appId = 'com.tiernan.music';

  // API 基址
  //
  // P1（第5批复核③）：kapi（kapi.344977.xyz）**只是原生接口的参考实现，
  // 运行期绝不调用**（QUALITY_STANDARD 第 27 条）。该常量仅供
  // KugouApiClient 的 CookieJar 域名占位使用（Cookie 只存本地，不发包），
  // 直连层 KgClient 全部使用酷狗原生域名。清理计划：待 Cookie 存储迁移到
  // 原生域后删除本常量。
  static const String kugouApiBase = 'https://kapi.344977.xyz';
  static const String translateApiBase =
      'https://index-translate.bilibili.com/v1/chat/completions';
  static const String proxyBase = 'https://proxy.344977.xyz';
  static const String translateModel = 'Index-Translate-35B-A3B';

  // 平台：kugou 标准版（API 实测使用标准版接口）
  static const String platform = '';

  // 缓存
  static const int memoryCacheSeconds = 90;

  // 歌词
  static const int lyricTranslateMaxLinesPerBatch = 40;
  static const int lyricTranslateMaxTokens = 4096;

  // 10 种界面语言
  static const List<String> supportedLocales = [
    'zh_CN', 'zh_TW', 'en', 'ja', 'ko', 'es', 'fr', 'de', 'pt', 'ru',
  ];

  static const Map<String, String> localeNames = {
    'zh_CN': '简体中文',
    'zh_TW': '繁體中文',
    'en': 'English',
    'ja': '日本語',
    'ko': '한국어',
    'es': 'Español',
    'fr': 'Français',
    'de': 'Deutsch',
    'pt': 'Português',
    'ru': 'Русский',
  };
}
