import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // Flutter 的 Gradle 插件必须最后应用
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// 签名配置：从 android/key.properties 读取，绝不要把 keystore 提交到仓库
// ---------------------------------------------------------------------------
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    // 必须与 MainActivity.kt 的 package 一致，否则启动即崩溃
    namespace = "com.medreminder.med_reminder"
    // compileSdk 只影响「能编译哪些 API」；插件（flutter_tts 4.2.x）要求 36，
    // 定低了 AGP 会直接报 "requires compileSdk 36"。targetSdk 仍留在 34，
    // 避免 Android 15+ 的强制 edge-to-edge 改动打乱现有页面布局。
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications 用到了 java.time，必须开脱糖
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.medreminder.med_reminder"
        // minSdk 23：speech_to_text 与 flutter_local_notifications 的下限
        minSdk = 23
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    signingConfigs {
        create("release") {
            val storePath = keystoreProperties["storeFile"] as String?
            if (storePath != null) {
                storeFile = file(storePath)
                storePassword = keystoreProperties["storePassword"] as String?
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            // 没有 key.properties 时退回 debug 签名，保证「能装能测」，
            // 但上架前必须换成 release 签名（见 docs/APK打包指南.md）
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // 首版关闭 R8 压缩：Flutter + 三个原生插件（通知/SQLite/TTS）
            // 一起混淆时最容易在运行时反射处崩溃，而崩溃点在老人机上无法排查。
            // 体积代价约 8–10 MB，稳定性收益远大于此；等线上稳定后再打开。
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    // 脱糖库：让 minSdk 23 也能用 java.time
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
