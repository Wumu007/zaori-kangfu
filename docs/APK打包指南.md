# Android APK 本地打包指南

从一台干净的电脑到装进手机的 APK，全流程约 30 分钟；首次构建要下载 Gradle 与依赖，会慢一些。

> 本文以 **Windows + 命令行（PowerShell / Git Bash）** 为主，macOS / Linux 的差异只有路径写法，命令本身一致。

---

## 0. 版本对照（先对号，不对号先别往下走）

| 组件 | 本工程要求 | 说明 |
|---|---|---|
| Flutter SDK | **3.22 或更高**（建议 3.29+） | 低于 3.22 不支持部分插件 API |
| Dart | 3.4+（随 Flutter） | `pubspec.yaml` 要求 `>=3.3.0` |
| JDK | **17** | Android Gradle Plugin 8.x 必须用 17，用 11 会报 `Unsupported class file major version` |
| Android SDK Platform | **34** | `compileSdk = 34` |
| Build Tools | 34.0.0 | 缺了 Gradle 会自己下，但慢 |
| Gradle | 8.x（随 Flutter 模板） | 不要手动降级 |
| minSdk | 23（Android 6.0） | speech_to_text / 通知插件的下限 |

---

## 1. 准备环境

### 1.1 安装 Flutter

1. 下载 Flutter SDK 压缩包，解压到**不含中文和空格**的路径，例如 `D:\sdk\flutter`。
2. 把 `D:\sdk\flutter\bin` 加进系统 `Path`。
3. 验证：

```bash
flutter --version
```

### 1.2 安装 JDK 17

- 最省事的做法：装 Android Studio，它自带 JBR 17。
- 或者装 Temurin 17，然后设置：

```bash
# Windows（系统环境变量，或在 PowerShell 里临时设置）
setx JAVA_HOME "C:\Program Files\Eclipse Adoptium\jdk-17.0.x-hotspot"
setx PATH "%JAVA_HOME%\bin;%PATH%"

# 验证
java -version   # 必须显示 17.x
```

### 1.3 安装 Android SDK

打开 Android Studio → **Settings → Languages & Frameworks → Android SDK**，勾选：

- **SDK Platforms**：`Android 14.0 (API 34)`
- **SDK Tools**：`Android SDK Build-Tools 34`、`Android SDK Command-line Tools`、`Android SDK Platform-Tools`

然后接受许可：

```bash
flutter doctor --android-licenses
```

### 1.4 体检

```bash
flutter doctor -v
```

必须看到这三个 ✅，否则先修：

```text
[√] Flutter (Channel stable, 3.2x.x)
[√] Android toolchain - develop for Android devices (Android SDK version 34.0.0)
[√] Android Studio (version 2024.x)
```

> 如果提示 `cmdline-tools component is missing`：Android Studio → SDK Manager → SDK Tools → 勾 `Android SDK Command-line Tools` → Apply。

---

## 2. 生成平台目录，覆盖工程自带的 Android 配置

仓库里 `lib/` 是完整代码，`android/` 只带了**必须手写**的 5 个文件（权限、签名、混淆、入口 Activity）。缺的 Gradle Wrapper 等由 Flutter 生成：

```bash
cd E:/WorkBuddy/2026-10-21-14-25-28/med_reminder

# 生成 android/ 下缺失的文件（已存在的不会被删除）
flutter create --org com.medreminder --platforms=android .
```

**生成完之后，把仓库里的这 4 个文件重新覆盖回去**（`flutter create` 可能用模板版本替换它们）：

| 文件 | 必须保留的内容 |
|---|---|
| `android/app/src/main/AndroidManifest.xml` | 通知、精确闹钟、开机重排、录音权限 + 3 个 Receiver |
| `android/app/build.gradle.kts` | `namespace`、`signingConfigs`、`isCoreLibraryDesugaringEnabled`、R8 |
| `android/app/proguard-rules.pro` | 通知/语音插件的 keep 规则 |
| `android/app/src/main/kotlin/com/medreminder/med_reminder/MainActivity.kt` | 包名必须是 `com.medreminder.med_reminder` |

> ⚠️ 两个包名必须一致：`build.gradle.kts` 的 `namespace` / `applicationId` 与 `MainActivity.kt` 的 `package`。不一致的表现是「安装成功但一打开就闪退」。

如果你的 Flutter 版本生成的是 Groovy 版 `build.gradle`（而不是 `.kts`）：
把本工程的 `.kts` 内容按同样字段翻译过去即可，重点是 `namespace`、`minSdk 23`、`desugaring`、`signingConfigs`。

### 2.1 拉依赖

```bash
flutter pub get
```

### 2.2 先跑起来（强烈建议）

```bash
flutter devices          # 确认真机已连接（USB 调试已打开）
flutter run              # 首次会编译，3~8 分钟
```

**语音功能必须用真机测**：模拟器通常没有中文语音识别服务，会一直返回「没听清」。

---

## 3. 生成签名（发布版必做）

Debug 包能装能测，但不能长期使用：换电脑重装、覆盖升级都会失败，也不允许上架。

### 3.1 生成 keystore

在 `android/app/` 目录下执行（**文件名、别名、密码自己记牢，丢了就无法再更新这个 App**）：

```bash
cd android/app

keytool -genkey -v ^
  -keystore upload-keystore.jks ^
  -keyalg RSA -keysize 2048 -validity 10000 ^
  -alias upload
```

macOS / Linux 把 `^` 换成 `\` 续行。执行过程中会问：

- 姓名 / 组织 / 城市：随便填，只用于证书信息
- 密码：**至少 6 位，记下来**

Windows 上 keytool 在 JDK 的 `bin` 目录里；找不到就写全路径，例如
`"C:\Program Files\Eclipse Adoptium\jdk-17.0.x-hotspot\bin\keytool.exe"`。

### 3.2 写 key.properties

```bash
cd android
cp key.properties.example key.properties
```

编辑 `android/key.properties`：

```properties
storeFile=upload-keystore.jks
storePassword=你刚才设的密码
keyAlias=upload
keyPassword=你刚才设的密码
```

> `storeFile` 的路径基准是 `android/app/`，所以 keystore 放在 `android/app/` 下时直接写文件名即可。
> **`key.properties` 与 `.jks` 都不要提交到 Git。**

### 3.3 校验

```bash
keytool -list -v -keystore upload-keystore.jks -alias upload
```

能看到 `Certificate fingerprint (SHA-256)` 即成功。

---

## 4. 构建 APK

### 4.1 Debug 包（自己测）

```bash
flutter build apk --debug
# 产物：build/app/outputs/flutter-apk/app-debug.apk
```

### 4.2 Release 通用包（一个包兼容所有机型）

```bash
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk（约 18–24 MB）
```

### 4.3 按 CPU 架构分包（推荐，体积最小）

```bash
flutter build apk --release --split-per-abi
```

产物三个，装机时**优先用 arm64**：

| 文件 | 适用机型 | 体积 |
|---|---|---|
| `app-arm64-v8a-release.apk` | 2017 年后的绝大多数手机（**首选**） | 约 8–11 MB |
| `app-armeabi-v7a-release.apk` | 老机型、部分百元机 | 约 8–10 MB |
| `app-x86_64-release.apk` | 模拟器 / 极少数平板 | 约 9–12 MB |

不确定就用 arm64；装不上再试 armeabi-v7a。

### 4.4 上架 Google Play 用 AAB

```bash
flutter build appbundle --release
# 产物：build/app/outputs/bundle/release/app-release.aab
```

### 4.5 构建参数补充

```bash
# 只编某一个架构，速度更快
flutter build apk --release --target-platform android-arm64

# 需要看体积明细
flutter build apk --release --analyze-size --target-platform android-arm64

# 清一次缓存再构建（改了 gradle 配置后建议）
flutter clean && flutter pub get && flutter build apk --release
```

---

## 5. 安装到手机

### 方式 A：adb（推荐，能看日志）

```bash
adb devices                                   # 确认设备在线
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
adb logcat -s flutter                         # 只看本应用的日志
```

### 方式 B：手动传文件

把 apk 拷到手机，用文件管理器点击安装。**需要允许「安装未知来源应用」**。

### 装完的 6 步验收（少一步都可能「以为能用其实不能用」）

1. 首次打开 → 允许**通知**权限、允许**录音**权限；
2. 语音说一句「阿司匹林一片早上八点」→ 确认页 4 行都有值 → 保存；
3. 把其中一次时间改成 2 分钟后 → 锁屏等待 → 通知**弹出并响铃**；
4. 在通知上点「已服用」→ 打开 App，首页对应行变绿勾；
5. 再点一次通知的「延后 10 分钟」→ 10 分钟后应再响一次；
6. **重启手机**，重复第 3 步 —— 这一步验证的是 `BOOT_COMPLETED` 重排是否生效（最常见的坑）。

---

## 6. 国产 ROM 必做设置（提醒不响的头号原因）

系统会把后台 App 冻结，导致「设了提醒但不响」。装完请按机型做一次：

| 品牌 | 设置路径（大意） |
|---|---|
| 小米 / Redmi（MIUI、HyperOS） | 设置 → 应用设置 → 应用管理 → 早日康复 → **省电策略：无限制**、**自启动：允许**、**通知：允许**；另外「设置 → 应用设置 → 特殊权限 → 闹钟与提醒」允许 |
| 华为 / 荣耀（EMUI、HarmonyOS） | 设置 → 应用 → 早日康复 → **耗电详情 → 应用启动管理：手动管理**（允许自启动/关联启动/后台活动）；通知允许；电池优化设为「不允许」 |
| OPPO / 一加（ColorOS） | 设置 → 电池 → 应用耗电管理 → 早日康复 → **允许后台运行 / 允许自启动** |
| vivo（OriginOS） | 设置 → 电池 → 后台耗电管理 → 允许后台高耗电；i管家 → 自启动管理允许 |
| 三星 / 原生 Android | 设置 → 应用 → 早日康复 → 电池 → **不受限制** |

App 内对应位置：**我的 → 通知与闹钟权限**（被拒时会引导到系统设置页）。

> 产品侧兜底话术（建议放进首次引导）：*「如果担心提醒不准，可以把最要紧的一次同时设成手机自带闹钟。」*

---

## 7. 常见报错排查

| 报错 / 现象 | 原因 | 处理 |
|---|---|---|
| `Unsupported class file major version 61` | 用了 JDK 11/21 编 AGP 8 | 切 JDK 17：`flutter config --jdk-dir "C:\...\jdk-17"` |
| `NDK version mismatch` / `ndkVersion` 报错 | 插件要求特定 NDK | 保持 `ndkVersion = flutter.ndkVersion`，或 SDK Manager 装对应 NDK |
| `Core library desugaring is not enabled` | 没开脱糖 | `isCoreLibraryDesugaringEnabled = true` + `desugar_jdk_libs` 依赖 |
| `R8: Missing class com.dexterous...` | 混淆把通知类删了 | 确认 `proguard-rules.pro` 生效且 `proguardFiles` 已配置 |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 新旧包签名不同 | `adb uninstall com.medreminder.med_reminder` 再装 |
| 通知**完全不响** | ① 通知权限被拒 ② 精确闹钟未允许 ③ 电池优化冻结 ④ 少 Receiver ⑤ 时间已过被排到明天 ⑥ 通知渠道被用户关掉 | 按这 6 条顺序查：设置页权限 → 系统「闹钟与提醒」→ 电池策略 → Manifest 三个 Receiver → 换成 2 分钟后的时间重试 → 应用通知 → 关闭一次再打开 |
| 通知**延迟几分钟** | 未用精确闹钟模式 | 代码里已是 `AndroidScheduleMode.exactAllowWhileIdle`；再检查是否被系统「智能省电」压掉 |
| 重启后不提醒 | 少了 `BOOT_COMPLETED` Receiver 或权限 | 检查 `ScheduledNotificationBootReceiver` 与 `RECEIVE_BOOT_COMPLETED` |
| 语音一点就「没听清」 | 设备无中文语音识别服务 / 无 Google 服务 | 系统设置里装「语音服务」或换机测试；国内机型建议预装讯飞/系统语音引擎 |
| 中文显示成方框 | 设备缺中文字体（极少数定制 ROM） | 不用改代码，系统字体缺失；可在 V2 内置子集字体 |
| `Execution failed for task ':app:lintVitalRelease'` | 命中了 lint 致命项 | 先看具体项修掉；临时可 `--no-shrink` 定位 |
| Gradle 下载卡住 | 网络 | 配镜像：`android/build.gradle.kts` 里加阿里云/腾讯云 Maven 仓库 |

---

## 8. 上架前（如果要发应用商店）

1. **隐私政策**：必须写明「用药数据仅存本机、不上传、不共享」。V1 无网络请求，这条很容易写清。
2. **权限用途说明**（应用商店表单会逐条问）：
   - 通知：到点提醒服药
   - 录音：语音录入用药
   - 精确闹钟：保证提醒准时
   - 开机启动：重启后恢复提醒
3. **健康类声明**：明确「不提供诊断与用药建议」，App 内「我的 → 免责声明」已内置。
4. **targetSdk**：Google Play 要求新包 targetSdk 34+；国内商店一般要求 33+。
5. **体积**：`--split-per-abi` + `isShrinkResources = true` 后单包约 8–11 MB（本工程无图片资源与自定义字体，主要体积来自 Flutter 引擎）。

---

## 9. 命令速查

```bash
# 一次完整的发布构建
cd E:/WorkBuddy/2026-10-21-14-25-28/med_reminder
flutter clean
flutter pub get
flutter test                     # 解析器单测，15 组用例
flutter build apk --release --split-per-abi

# 装机
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk

# 看日志
adb logcat -s flutter
```
