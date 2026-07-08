# ============================================================
# ThunderPeak — release proguard rules
# ============================================================

# Flutter engine + plugin runtime.
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugins.webviewflutter.** { *; }

# Play Core (deferred split installs).
-dontwarn com.google.android.play.core.**

# Firebase reflection.
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# AppsFlyer reflection.
-keep class com.appsflyer.** { *; }
-dontwarn com.appsflyer.**

# JNI + Parcelables.
-keepclasseswithmembernames class * {
    native <methods>;
}
-keep class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
}

# Strip verbose Android logging in release.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}
