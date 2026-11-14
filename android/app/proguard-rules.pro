# ProGuard rules for Necxa

# Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# SQLite / Sqflite
-keep class com.tekartik.sqflite.** { *; }
-keep class net.sqlcipher.** { *; }
-dontwarn com.tekartik.sqflite.**

# Connectivity
-keep class com.baseflow.connectivity.** { *; }
-dontwarn com.baseflow.connectivity.**

# Camera
-keep class com.google.android.camerax.** { *; }
-dontwarn com.google.android.camerax.**

# ML Kit (Broad protection to cover Face, Text, etc.)
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**
-keep class com.google.android.gms.internal.mlkit_** { *; }
-dontwarn com.google.android.gms.internal.mlkit_**

# FFmpegKit
-keep class com.arthenica.ffmpegkit.** { *; }
-dontwarn com.arthenica.ffmpegkit.**
-dontwarn com.arthenica.smartexception.**

# Audio
-keep class com.arthenica.audiotoolbox.** { *; }
-keep class com.arthenica.audiovisualizer.** { *; }

# Supabase (Dart handles JSON, but JNI/Platform calls might need this)
-keep class com.supabase.** { *; }
-dontwarn com.supabase.**

# General Native Protection
-keepclasseswithmembernames class * {
    native <methods>;
}

# Parcelable
-keep class * implements android.os.Parcelable {
    public static final *** CREATOR;
}

# Application and Activity Classes
-keep class com.necxa.MainApplication { *; }
-keep class com.necxa.MainActivity { *; }
-keep class com.necxa.** { *; }

# Play Core (Required for split-abi/app bundles)
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.splitinstall.** { *; }
-keep class com.google.android.play.core.tasks.** { *; }
-dontwarn com.google.android.play.core.tasks.**

# Agora RTC SDK
-keep class io.agora.** { *; }
-dontwarn io.agora.**

# Optimization flags
-dontusemixedcaseclassnames
-dontskipnonpubliclibraryclasses
-dontskipnonpubliclibraryclassmembers

# Google Play Services & Google Maps
-keep class com.google.android.gms.maps.** { *; }
-dontwarn com.google.android.gms.maps.**
-keep class com.google.android.gms.common.** { *; }
-dontwarn com.google.android.gms.common.**

