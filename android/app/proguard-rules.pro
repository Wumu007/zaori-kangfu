# flutter_local_notifications 通过反射创建通知与接收器，混淆后必须保留
-keep class com.dexterous.** { *; }
-keep class com.dexterous.flutterlocalnotifications.** { *; }

# 通知 payload 用 Gson 序列化
-keep class com.google.gson.** { *; }
-keepattributes Signature
-keepattributes *Annotation*

# Flutter 引擎
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# speech_to_text / flutter_tts 的 Platform Channel 回调
-keep class com.csdcorp.speech_to_text.** { *; }
-keep class com.tundralabs.fluttertts.** { *; }
