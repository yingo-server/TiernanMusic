class AppConfig {
  AppConfig._();

  static const String appName = 'Tiernan Music';
  static const String appNameCn = '汀澜音乐';
  static const String appId = 'com.tiernan.music';

  // API
  static const String kugouApiBase = 'https://kapi.344977.xyz';
  static const String translateApiBase =
      'https://index-translate.bilibili.com/v1/chat/completions';
  static const String proxyBase = 'https://proxy.344977.xyz';
  static const String translateModel = 'Index-Translate-35B-A3B';

  // 平台：kugou 标准版（API 实测使用标准版接口）
  static const String platform = '';

  // 缓存
  static const int memoryCacheSeconds = 90;
  static const int diskCacheMaxMb = 2048;
  static const Duration diskCacheMaxAge = Duration(days: 30);

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

  /// MV HTTP 地址转为代理 HTTPS
  static String proxyMvUrl(String httpUrl) {
    if (httpUrl.startsWith('https://')) return httpUrl;
    return '$proxyBase/$httpUrl';
  }
}
