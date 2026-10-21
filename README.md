# 早日康复 App · V1（通用版）

到点提醒吃药 + 一键打卡 + 语音口述录入。纯本机存储，不注册、不联网、不上传健康数据。

- 界面方案：Ardot「早日康复 App · V1 界面设计」(5 屏：今日 / 聆听 / 确认 / 锁屏通知 / 家属查看)
- 技术栈：Flutter 3.22+，sqflite + flutter_local_notifications + speech_to_text + flutter_tts
- 包名：`com.medreminder.med_reminder`，`minSdk 23` / `targetSdk 34`

---

## 一、目录结构

```text
med_reminder/
├── pubspec.yaml                        依赖与版本号
├── analysis_options.yaml               lint 规则（关掉跨 await 用 context 的噪音）
├── README.md                           本文件
├── docs/
│   └── APK打包指南.md                   从零到出 APK 的完整步骤（含签名与国产 ROM 设置）
├── android/                            只放「必须手写」的 Android 配置
│   ├── key.properties.example          签名配置模板（复制为 key.properties）
│   └── app/
│       ├── build.gradle.kts            包名/签名/脱糖/R8/压缩资源
│       ├── proguard-rules.pro          通知与语音插件的 keep 规则
│       └── src/main/
│           ├── AndroidManifest.xml     通知、精确闹钟、开机重排、录音等权限
│           └── kotlin/com/medreminder/med_reminder/MainActivity.kt
├── lib/
│   ├── main.dart                       启动顺序 + 通知按钮回调（不打开 App 也能打卡）
│   ├── app.dart                        根节点：主题 + 全局大字号
│   ├── theme/
│   │   └── app_theme.dart              设计 token（颜色/字号/圆角/间距）
│   ├── models/
│   │   ├── medication.dart             用药计划 + 服药记录 + 频次枚举
│   │   ├── medication_draft.dart       语音解析出的「草稿」，带字段级置信度
│   │   └── day_slot.dart               计划 × 记录的合并视图（时间轴的一行）
│   ├── services/
│   │   ├── medication_nlu.dart         中文口语解析器（纯函数，可单测）
│   │   ├── asr_engine.dart             语音识别抽象 + 系统 ASR 实现
│   │   ├── voice_input_service.dart    听 → 解析 → 回读的编排层
│   │   ├── medication_repository.dart  sqflite 存取（计划 / 记录 / 区间查询）
│   │   ├── reminder_scheduler.dart     每日重复通知、通知按钮、延后
│   │   └── app_settings.dart           大字号、延后时长、访客密码
│   ├── state/
│   │   └── app_state.dart              全局状态（ChangeNotifier）：今日进度、打卡、增删
│   ├── widgets/
│   │   └── ui_kit.dart                 卡片/分隔线/主按钮/胶囊/空状态/导航
│   └── pages/
│       ├── app_shell.dart              底部三 Tab（今日 / 记录 / 我的）
│       ├── home_page.dart              S1 今日：进度条 + 时间轴 + 语音添加
│       ├── history_page.dart           记录：近 7 天日历条 + 按日分组明细
│       ├── settings_page.dart          我的：大字号、延后时长、权限修复、免责声明
│       ├── family_view_page.dart       S5 家属查看：本机访客视图（4 位密码）+ V3 预告
│       └── voice_intake_page.dart      S2/S3 语音录入：聆听态 + 分项确认态
├── test/
│   └── medication_nlu_test.dart        解析器单测（15 组真实口语句）
└── tool/
    └── _nlu_check.py                   无 Dart 环境时的等价校验脚本（开发期工具）
```

---

## 二、逐文件说明（按「读代码的顺序」排列）

| 文件 | 职责 | 关键设计 |
|---|---|---|
| `lib/main.dart` | 启动：初始化通知 → 申请权限 → 读库 → 重排通知 → runApp | 顺序不能改；通知按钮回调写库后立刻 `AppState.refresh()` |
| `lib/app.dart` | `MaterialApp` + 主题 + 全局 `textScaler` | 大字号一处生效，页面里不散落字号判断 |
| `lib/theme/app_theme.dart` | 颜色 / 字号 / 圆角 / 间距 token | 与设计稿一一对应，改版只改这里 |
| `lib/models/medication.dart` | `Medication`（计划）、`DoseLog`（记录）、`FrequencyType` | `interval` 在保存时展开成具体时间点，调度层不用区分模型 |
| `lib/models/medication_draft.dart` | 语音草稿：字段 + 置信度 + issues + TTS 回读文案 | `readyToSave` 是安全门禁：药名/剂量/时间齐全才允许落库 |
| `lib/models/day_slot.dart` | `DaySlot`（时刻 + 计划 + 状态）、`buildSlots()`、`slotKey()` | key 带日期，避免昨天与今天互相覆盖 |
| `lib/services/medication_nlu.dart` | 中文口语 → 结构化字段 | 中文数字归一、口语展开（早晚/三餐）、32 个药名映射 |
| `lib/services/asr_engine.dart` | ASR 抽象 + `SystemAsrEngine` | 抽象出来是为了 V2 换云端识别时页面零改动 |
| `lib/services/voice_input_service.dart` | 编排：开始收音 / 解析 / TTS 回读 | 错误码统一翻成「没听清，再说一次好吗」 |
| `lib/services/medication_repository.dart` | 建表、增删改查、按区间查记录 | `statusInRange` 一套查询同时喂首页与历史页 |
| `lib/services/reminder_scheduler.dart` | `zonedSchedule` 每日重复 + 通知按钮 + 延后 | 用 `matchDateTimeComponents: time`，重启更稳 |
| `lib/services/app_settings.dart` | SharedPreferences：大字号 / 延后时长 / 访客密码 | 不做「半套免打扰」，避免假设置 |
| `lib/state/app_state.dart` | 全局状态与写操作 | 统一顺序：写库 → 重建通知 → notify |
| `lib/widgets/ui_kit.dart` | 卡片、分隔线、主按钮、胶囊、空状态、导航 | 圆角/描边/热区只定义一次 |
| `lib/pages/app_shell.dart` | 三 Tab + `IndexedStack` | 切 Tab 不丢滚动位置 |
| `lib/pages/home_page.dart` | 今日页 | 打钩热区 44×44；到点未服标橙；点错可撤销 |
| `lib/pages/history_page.dart` | 记录页 | 日历点 + 分组明细；行内可撤销/补记 |
| `lib/pages/settings_page.dart` | 设置页 | 改延后时长后立刻 `resync` 通知 |
| `lib/pages/family_view_page.dart` | 家属查看 + 访客只读视图 | 权限边界写在界面上：访客页没有打卡按钮 |
| `lib/pages/voice_intake_page.dart` | 语音录入两态 | 4 行分项确认、单项重说、剂量缺失禁用保存 |

---

## 三、数据流

```text
语音/键盘 ──> MedicationDraft ──(确认)──> Medication ──> sqlite
                                                   │
                                                   ├─> ReminderScheduler.resync()  → 本地通知
                                                   └─> AppState.refresh()

通知按钮「已服用/延后」 ──> Repository.log() ──> AppState.refresh() ──> 首页立即变绿
```

三张表：`medications`（计划）、`dose_logs`（记录）、SharedPreferences（设置）。
记录的唯一键是「药品 id + 精确到分钟的日期时间」，所以同一时间点重复打卡只会覆盖、不会翻倍。

---

## 四、本地运行

```bash
# 0. 需要 Flutter 3.22+ / JDK 17 / Android SDK 34
flutter doctor -v

# 1. 生成缺失的平台目录（本仓库只带了必须手写的 android 配置）
flutter create --org com.medreminder --platforms=android .

# 2. 拉依赖
flutter pub get

# 3. 跑单测（解析器）
flutter test

# 4. 连真机调试（模拟器没有语音识别，语音相关必须真机）
flutter run -d <deviceId>
```

> 打包成 APK 的完整步骤见 **[docs/APK打包指南.md](docs/APK打包指南.md)**。

---

## 五、这套代码刻意守住的 6 条底线

1. **剂量没听清就留空并禁用保存**——绝不给默认剂量。
2. **保存前 TTS 回读 + 弹窗二次确认**——语音识别的错不能变成吃错药的错。
3. **通知里能直接打卡**——这是真实使用频率最高的入口，不用解锁。
4. **打错了能撤销**——首页 snackbar 撤销、历史页可改状态。
5. **权限没拿到要明说**——首页顶部提示条 + 设置页修复入口，不允许「静默失效」。
6. **健康数据不出本机**——V1 无账号、无网络请求，设置页明确告知卸载即丢。

---

## 六、V1 边界（有意不做）

- 不做账号与云同步 → 换机不迁移（V3）
- 不做家属远程查看（V3，需登录同一账号 + 云同步）
- 不做依从率图表、剩余药量提醒（V2）
- 不做药品计划的可视化编辑页：目前改计划的方式是「停用旧药 + 语音重新添加」，V2 再补表单编辑
- 不做拍照识药：药盒反光/字号小，识别后仍需手改剂量与频次，省不了步骤
