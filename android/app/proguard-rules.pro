# R8 / ProGuard 规则
#
# Flutter 引擎与插件的通用 keep 规则已由 Flutter Gradle 插件自动注入，
# 这里只补充本项目特有或第三方库反射敏感的类。

# --- 酷狗直连 ---
# pointycastle 是纯 Dart 包，Dart 代码不参与 R8，无需 keep（R2 已清理死规则）。

# --- Dio / OkHttp ---
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**
-keepclasseswithmembers class * {
    @retrofit2.http.* <methods>;
}
-keep class retrofit2.** { *; }
-keepattributes Signature, InnerClasses, EnclosingMethod
-keepattributes RuntimeVisibleAnnotations, RuntimeVisibleParameterAnnotations
-keepattributes AnnotationDefault

# --- Gson（部分插件用 JSON 反射） ---
-keepattributes Signature
-keep class com.google.gson.** { *; }
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer

# --- Flutter 引擎与插件 ---
# Flutter Gradle 插件会自动注入 io.flutter 的 consumer rules，
# 这里额外保留关键入口，避免第三方插件反射找不到实现。
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.ryanheise.** { *; }
-keep class com.ryanheise.audioservice.** { *; }
-dontwarn com.ryanheise.**
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.window.** { *; }

# --- Google Play Core（deferred components，App 不用但引擎引用） ---
# FlutterPlayStoreSplitApplication / PlayStoreDeferredComponentManager 引用
# com.google.android.play.core.*，未引入该依赖时 R8 报 Missing class。
# 本项目不用 deferred components，dontwarn 即可。
-dontwarn com.google.android.play.core.**

# --- WebView（人机验证页为 TCaptcha，纯 JS 实现，无原生类，R2 已清理死规则） ---

# --- 视频播放（ExoPlayer/Media3 反射） ---
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# --- 权限处理器 ---
-keep class com.baseflow.permissionhandler.** { *; }
-dontwarn com.baseflow.permissionhandler.**

# --- Kotlin 元数据 ---
-keepattributes *Annotation*, InnerClasses, Signature, Exceptions

# --- 保留行号便于崩溃栈还原 ---
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
