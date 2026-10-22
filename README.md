# 早日康复 App · V1.2.0

到点提醒吃药 + 一键打卡 + 语音口述录入 + 完整药品管理 + 导入导出。
纯本机存储，不注册、不联网、不上传健康数据。

- 技术栈：Flutter（CI 跟随 stable 通道），sqflite + flutter_local_notifications + speech_to_text + flutter_tts + file_selector
- 包名：`com.medreminder.med_reminder`，`minSdk 23` / `compileSdk 36` / `targetSdk 34`
- 数据库版本：v2（v1 → v2 自动增量迁移，老用户升级不丢记录）

---

## 一、V1.2.0 做了什么

### 1. 新增药品管理页（`medication_list_page.dart`）

- 药品的**添加 / 编辑 / 删除**全流程表单（`medication_edit_page.dart`）
- 字段：药品名称、单次剂量 + 剂量单位、服用频次、提醒时间、备注
- 两种录入方式并存：**语音口述**（一句「降压药一片，早上八点」直接生成草稿）和**键盘填写**
- **停止提醒但不删记录**：列表里「暂停/启用」只切换 `enabled`，历史 `dose_logs` 原样保留，
  所以停掉的药在历史页仍然能看到当时到底吃没吃

### 2. 服药计划设置

- 时间：一天一个时间点、一天多个时间点、或自定义任意时刻组合
- 有效期：起始日期 + 结束日期
- **长期用药**：结束日期留空即「持续执行」，一直提醒到用户手动停用

### 3. 服药提醒

- 到点由 `flutter_local_notifications` 发系统本地通知，`AndroidScheduleMode.exactAllowWhileIdle`
  保证锁屏与省电模式下也能准时
- 通知上三个按钮：**已服药 / 稍后提醒 / 跳过本次**，不解锁也能操作
- 重启手机自动重排（`RECEIVE_BOOT_COMPLETED` + resync）

### 4. 服药记录（四态）

`IntakeStatus` 明确区分四种状态，**是否真的吃了只看这一个判定**：

| 状态 | 含义 | 算服用 |
|---|---|---|
| `taken` 已服药 | 用户点了「已服药」 | ✅ |
| `skipped` 已跳过 | 用户主动放弃这一次 | ❌ |
| `pending` 待确认 | 点过「稍后提醒」，还没吃 | ❌ |
| `overdue` 逾期未确认 | 超过 30 分钟宽限期仍无反馈，系统判定 | ❌ |

`missed` 是 V1 的旧值，读取时归一化为 `overdue`，仅为兼容历史数据。

### 5. 首页「今日服药清单」

展示当天每次服药的**时间 / 药品名称 / 剂量 / 当前状态**，一行一条，右侧打钩按钮 44×44 热区可直接打卡或撤销。

### 6. 导入 / 导出（V1.2.0 新增）

从「我的 → 备份与恢复」或记录页 / 药品列表右上角进入，**保存位置由用户自己选**（`file_selector`）：

- **导出完整备份**：JSON，含药品 + 全部记录，用于**换手机恢复数据**
- **从备份恢复**：导入前先出预览（新增多少条 / 重复多少条），确认后才写库。**只补不覆盖**，
  不会把手机上已有的新记录冲掉
- **导出服药记录表格**：CSV + 纯文本摘要各一份，给医生看用

> CSV 一律写 UTF-8 BOM，否则 WPS / Excel 打开中文会乱码。

---

## 二、V1.2.0 修的三个 Bug

| Bug | 原因 | 修法 |
|---|---|---|
| 「今日」页两个语音添加按钮 | 列表底部常驻一个、空状态卡片里又放一个，列表为空时两者同时渲染 | 语音入口**只由列表底部负责**，空状态只留文字引导，单一来源 |
| 「我的」页「30 分钟」选项框与其它选项重叠 | 延时选项用了固定宽度容器，`30 分钟` 文字更宽把 box 撑出去 | 改用 `Wrap` + `ChoiceChips<int>`，由布局自然换行 |
| 「通知与闹钟权限」点不动，只弹「已开启」 | 把「查状态」和「申请权限」混在一个动作里，永远只返回查询结果 | 拆成两个**真开关**，拨动直接跳系统设置页；`WidgetsBindingObserver` 在回到 App 时自动刷新状态 |

额外调整：**麦克风权限改为首次使用语音时申请一次**，而不是装完就弹框。启动时只查询通知状态、不申请。

---

## 三、目录结构

```text
med_reminder/
├── pubspec.yaml                        依赖与版本号（1.2.0+3）
├── README.md                           本文件
├── docs/
│   └── APK打包指南.md                   从零到出 APK 的完整步骤（含签名与国产 ROM 设置）
├── .github/workflows/android-apk.yml   GitHub Actions 云端出 APK
├── android/
│   └── app/
│       ├── build.gradle.kts            包名/compileSdk/签名/脱糖/R8
│       ├── proguard-rules.pro          通知与语音插件的 keep 规则
│       └── src/main/
│           ├── AndroidManifest.xml     通知、精确闹钟、开机重排、录音等权限
│           └── kotlin/com/medreminder/med_reminder/MainActivity.kt
├── lib/
│   ├── main.dart                       启动顺序 + 通知按钮回调
│   ├── app.dart                        根节点：主题 + 全局大字号
│   ├── theme/app_theme.dart            设计 token（颜色/字号/圆角/间距）
│   ├── models/
│   │   ├── medication.dart             Medication / DoseLog / FrequencyType / IntakeStatus
│   │   ├── medication_draft.dart       语音解析出的「草稿」，带字段级置信度
│   │   └── day_slot.dart               计划 × 记录的合并视图 + 四态判定 + 状态编解码
│   ├── services/
│   │   ├── medication_nlu.dart         中文口语解析器（纯函数，可单测）
│   │   ├── asr_engine.dart             语音识别抽象 + 系统 ASR 实现
│   │   ├── voice_input_service.dart    听 → 解析 → 回读的编排层 + 麦克风门禁
│   │   ├── medication_repository.dart  sqflite 存取（含 v1→v2 迁移）
│   │   ├── reminder_scheduler.dart     每日重复通知、通知按钮、延后、权限查询
│   │   ├── backup_service.dart         导入导出（CSV / JSON 备份 / 预览 / 判重）
│   │   └── app_settings.dart           大字号、延后时长、访客密码
│   ├── state/app_state.dart            全局状态（ChangeNotifier）
│   ├── widgets/ui_kit.dart             卡片/分隔线/主按钮/胶囊/空状态/导航
│   └── pages/
│       ├── app_shell.dart              底部三 Tab（今日 / 记录 / 我的）
│       ├── home_page.dart              今日：进度条 + 今日清单 + 唯一语音入口 + 权限提示条
│       ├── history_page.dart           记录：日历条 + 按日分组明细 + 导出入口
│       ├── medication_list_page.dart   药品管理：列表 / 暂停 / 编辑 / 删除 / 导出
│       ├── medication_edit_page.dart   药品表单：语音 + 键盘两种录入
│       ├── export_flow.dart            导出导入编排：区间选择 / 处理遮罩 / 结果弹窗
│       ├── settings_page.dart          我的：大字号、延后时长、权限双开关、备份恢复
│       ├── family_view_page.dart       家属查看：本机访客视图（4 位密码）
│       └── slot_action_sheet.dart      单次记录的动作面板（打卡 / 跳过 / 延后 / 补记）
├── test/
│   └── medication_nlu_test.dart        解析器 + 排程/状态判定单测
└── tool/
    └── _nlu_check.py                   无 Dart 环境时的等价校验脚本（开发期工具）
```

---

## 四、逐文件说明

| 文件 | 职责 | 关键设计 |
|---|---|---|
| `lib/main.dart` | 启动：初始化通知 → **查询**权限 → 读库 → 重排通知 → runApp | 启动只查不申请，避免一装上就弹三个框 |
| `lib/models/medication.dart` | `Medication`（计划）、`DoseLog`（记录）、`FrequencyType`、`IntakeStatus` | 频次三值 `once/multi/custom`；`fromName` 兼容 V1 的 `interval`/`daily` |
| `lib/models/day_slot.dart` | `DaySlot`、`buildSlots()`、`slotKey()`、`packStatus/unpackStatus` | 30 分钟宽限期决定「待确认」还是「逾期」；key 带日期避免昨天今天互相覆盖 |
| `lib/services/backup_service.dart` | 导出 CSV/JSON、导入预览、事务内判重写库 | 格式标识 `zaori-kangfu-backup` v1；CSV 写 BOM |
| `lib/services/medication_repository.dart` | 建表、迁移、增删改查、按区间查记录 | v1→v2 用 `PRAGMA table_info` 判重后 `ALTER TABLE` 增量加列 |
| `lib/services/reminder_scheduler.dart` | 通知调度、通知按钮、延后、权限查询/申请 | 精确闹钟走 `exactAllowWhileIdle`，重启后 resync |
| `lib/pages/settings_page.dart` | 设置页 | 权限两个真开关 → 跳系统设置；回到 App 自动刷状态 |
| `lib/pages/export_flow.dart` | 导出导入的交互编排 | 用 `List<ExportResult>?` 区分「取消」与「无数据」 |
| `lib/pages/medication_edit_page.dart` | 药品表单 | 语音草稿填进表单后仍可逐字段改；麦克风被拒时给「去打开」按钮 |

---

## 五、数据流

```text
语音/键盘 ──> MedicationDraft ──(确认)──> Medication ──> sqlite
                                                   │
                                                   ├─> ReminderScheduler.resync()  → 本地通知
                                                   └─> AppState.refresh()

通知按钮「已服药/延后/跳过」 ──> Repository.log() ──> AppState.refresh() ──> 首页立即变色

备份文件 ──> BackupService.pickAndPreview() ──> 预览弹窗 ──(确认)──> 事务写库（只补不覆盖）
```

三张表：`medications`（计划）、`dose_logs`（记录）、SharedPreferences（设置）。
记录的唯一键是「药品 id + 精确到分钟的日期时间」，同一时间点重复打卡只会覆盖、不会翻倍。

---

## 六、构建 APK

### 云端（推荐，本地零安装）

推到 `main` 分支即自动触发 `.github/workflows/android-apk.yml`，约 10–15 分钟出
`app-release.apk`，在 Actions 运行页底部的 **Artifacts** 下载。

### 本地

```bash
flutter doctor -v
flutter create --org com.medreminder --platforms=android .
flutter pub get
flutter test
flutter build apk --release --build-name=1.2.0 --build-number=3
```

> 详见 **[docs/APK打包指南.md](docs/APK打包指南.md)**。

---

## 七、这套代码刻意守住的底线

1. **剂量没听清就留空并禁用保存**——绝不给默认剂量。
2. **保存前 TTS 回读 + 二次确认**——语音识别的错不能变成吃错药的错。
3. **通知里能直接打卡**——真实使用频率最高的入口，不用解锁。
4. **打错了能撤销**——首页 snackbar 撤销、历史页可改状态。
5. **权限没拿到要明说**——首页顶部橙色提示条 + 设置页两个开关，不允许「静默失效」。
6. **健康数据不出本机**——无账号、无网络请求，卸载即丢；换机靠用户自己导出的备份文件。
7. **导入只补不覆盖**——恢复数据绝不能把手机上更新的记录冲掉，且导入前必须预览。

---

## 八、边界（有意不做）

- 不做账号与云同步 → 换机靠「导出完整备份 + 导入」，不走服务器
- 不做家属远程查看（需登录同一账号 + 云同步）
- 不做依从率图表、剩余药量提醒
- 不做拍照识药：药盒反光/字号小，识别后仍需手改剂量与频次，省不了步骤
