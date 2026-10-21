// ---------------------------------------------------------------------------
// Gradle 插件与仓库声明
// 版本三件套必须互相兼容，改任意一个都要一起看：
//   AGP 8.6.0  ← 需要 →  Gradle 8.7  ← 需要 →  JDK 17
//   desugar_jdk_libs 2.1.4  ← 需要 →  AGP 8.4+
// ---------------------------------------------------------------------------
pluginManagement {
    // Flutter SDK 路径来自 android/local.properties，由 flutter 命令自动写入
    val flutterSdkPath: String = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val path = properties.getProperty("flutter.sdk")
        require(path != null) { "local.properties 里缺少 flutter.sdk，请先执行 flutter pub get" }
        path
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.6.0" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}

include(":app")
