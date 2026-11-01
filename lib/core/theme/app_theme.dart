import 'package:flutter/material.dart';

/// 应用主题：Material 3 + Expressive 风格。
///
/// 精致度要点：
/// - 统一的形状体系（卡片 20 / 按钮全圆角 / 输入 16）
/// - 统一的动效曲线与时长
/// - 列表项使用 M3 的 `ListItem` 风格间距
/// - 深浅两套主题共享同一套形状/动效 token
class AppTheme {
  AppTheme._();

  /// 品牌青蓝
  static const seed = Color(0xFF00D4FF);

  /// 形状 token
  static const double radiusCard = 20;
  static const double radiusButton = 24;
  static const double radiusInput = 16;
  static const double radiusSmall = 12;

  /// 动效 token
  static const Duration motionShort = Duration(milliseconds: 200);
  static const Duration motionMedium = Duration(milliseconds: 320);
  static const Curve motionCurve = Curves.easeOutCubic;

  static ThemeData dark() => _base(
        ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      );

  static ThemeData light() => _base(
        ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
      );

  static ThemeData _base(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // 显式指定 Scaffold 底色，避免路由切换瞬间闪白
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      splashFactory: InkSparkle.splashFactory,
      materialTapTargetSize: MaterialTapTargetSize.padded,

      // ---------- 形状 ----------
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard + 4),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),

      // ---------- 搜索 ----------
      // M3 规范：搜索一律用 SearchBar 组件，不用裸 TextField 塞 AppBar。
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
        side: WidgetStatePropertyAll(
          BorderSide(color: scheme.outlineVariant),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w400),
      ),

      // ---------- 按钮 ----------
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: const StadiumBorder(),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const StadiumBorder(),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: const CircleBorder(),
        ),
      ),

      // ---------- 输入 ----------
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          borderSide: BorderSide(color: scheme.error),
        ),
      ),

      // ---------- 导航 ----------
      appBarTheme: AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        elevation: 0,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),

      // ---------- 列表 ----------
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        minVerticalPadding: 10,
        iconColor: scheme.onSurfaceVariant,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        thickness: 1,
        space: 1,
      ),

      // ---------- 芯片 / 徽章 ----------
      chipTheme: ChipThemeData(
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        labelStyle: const TextStyle(fontSize: 13),
      ),

      // M3 规范：筛选类选择用 FilterChip（带选中态图标 + 描边），
      // 分段选择用 SegmentedButton，多标签切换用 TabBar。
      filterChipTheme: FilterChipThemeData(
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        showCheckmark: true,
        labelStyle: const TextStyle(fontWeight: FontWeight.w500),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSmall),
            ),
          ),
          minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: scheme.error,
        textStyle: TextStyle(
          color: scheme.onError,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),

      // ---------- 其它 ----------
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
      ),
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith(
          (states) => Icon(
            states.contains(WidgetState.selected)
                ? Icons.check
                : Icons.close,
            size: 16,
          ),
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      extensions: <ThemeExtension<dynamic>>[
        if (isDark) const _GlowShadows(),
      ],
    );
  }
}

/// 深色主题下的发光阴影（封面/卡片用）。
class _GlowShadows extends ThemeExtension<_GlowShadows> {
  const _GlowShadows();

  @override
  _GlowShadows copyWith() => this;

  @override
  _GlowShadows lerp(ThemeExtension<_GlowShadows>? other, double t) =>
      this;

  /// 封面卡片的外发光
  List<BoxShadow> get coverGlow => const [
        BoxShadow(
          color: Color(0x3300D4FF),
          blurRadius: 24,
          spreadRadius: -4,
          offset: Offset(0, 8),
        ),
      ];
}
