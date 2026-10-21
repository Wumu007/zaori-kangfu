import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // Flutter 的 Gradle 插件必须最后应用；Kotlin 插件由 Flutter 插件自动带上
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

    // 跟 Flutter 走，但同时兜一个下限：flutter_tts 4.2.x 要求 compileSdk >= 36，
    // 定低了 AGP 会直接报 "requires compileSdk 36"
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications 用到了 java.time，minSdk 23 上必须开脱糖
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.medreminder.med_reminder"
        // minSdk 23：speech_to_text 与 flutter_local_notifications 的下限
        minSdk = 23
        // targetSdk 故意停在 34：35+ 会强制 edge-to-edge，页面会被状态栏压住，
        // 而 V1 的布局是按「有系统栏」设计的。等适配完再往上提。
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
            // 没有 key.properties 时退回 debug 签名，保证「能装能测」；
            // 上架前必须换成 release 签名（见 docs/APK打包指南.md）
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // 首版关闭 R8 压缩：Flutter + 三个原生插件（通知/SQLite/TTS）
            // 一起混淆最容易在反射处崩，而崩溃点在没有 logcat 的手机上无法排查。
            // 体积代价约 8–10 MB，稳定性收益远大于此。
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

// 注意：新版 Flutter 模板已不再用 android { kotlinOptions { } }，
// 那种写法在 AGP 9 上直接是编译错误（'is deprecated' 被当成 error）
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 脱糖库：让 minSdk 23 也能用 java.time
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
