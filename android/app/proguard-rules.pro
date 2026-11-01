# R8 / ProGuard 规则
#
# Flutter 引擎与插件的通用 keep 规则已由 Flutter Gradle 插件自动注入，
# 这里只补充本项目特有或第三方库反射敏感的类。

# --- 酷狗直连：RSA/AES 通过反射调用 pointycastle，需保留 ---
-keep class org.pointycastle.** { *; }
-dontwarn org.pointycastle.**
-keepclassmembers class * extends org.bouncycastle.crypto.Cipher {
    public <init>(org.bouncycastle.crypto.CipherParameters);
    public int doFinal(byte[], int, int, byte[]);
}

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

# --- Flutter 插件入口 ---
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.ryanheise.** { *; }
-keep class com.ryanheise.audioservice.** { *; }
-dontwarn com.ryanheise.**

# --- WebView（人机验证页用 TCaptcha） ---
-keep class com.tencent.tcaptcha.** { *; }
-dontwarn com.tencent.**

# --- Kotlin 元数据 ---
-keepattributes *Annotation*, InnerClasses, Signature, Exceptions

# --- 保留行号便于崩溃栈还原 ---
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
