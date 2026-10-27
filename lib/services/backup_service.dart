import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/day_slot.dart';
import '../models/medication.dart';
import 'medication_repository.dart';

/// 导出结果：存到哪了、写了多少行
///
/// 让 UI 能说清「存到哪个文件、导了多少条」—— 老人点完导出最怕的是
/// 「不知道存哪了」，所以路径必须回传给界面展示。
class ExportResult {
  const ExportResult({
    required this.path,
    required this.rows,
    required this.title,
    this.degraded = false,
    this.shareHint,
  });

  final String path;
  final int rows;
  final String title;

  /// true = 没能存到用户想存的位置，退到了应用文件夹
  final bool degraded;

  /// 给用户的补充说明（比如「去手机文件管理 → 下载 里找」）
  final String? shareHint;

  String get fileName => p.basename(path);
}

/// 导入前的体检结果
///
/// 导入是**破坏性**操作（会往库里写东西），所以必须先把「会导致什么后果」
/// 算清楚给用户看，而不是点一下就闷头写。
class ImportPreview {
  const ImportPreview({
    required this.medications,
    required this.logs,
    required this.newMedications,
    required this.duplicateMedications,
    required this.newLogs,
    required this.duplicateLogs,
    required this.exportedAt,
    required this.appVersion,
  });

  final int medications;
  final int logs;
  final int newMedications;
  final int duplicateMedications;
  final int newLogs;
  final int duplicateLogs;
  final DateTime? exportedAt;
  final String? appVersion;

  bool get nothingToDo => newMedications == 0 && newLogs == 0;

  /// 一句话结论（弹窗正文）
  String get summary {
    if (nothingToDo) {
      return '这份备份里的 $medications 种药、$logs 条记录，本机都已经有了，不需要导入。';
    }
    final StringBuffer b = StringBuffer('备份里有 $medications 种药、$logs 条记录。\n\n');
    b.write('导入后会：\n');
    b.write('· 新增 ${newMedications} 种药品');
    if (duplicateMedications > 0) {
      b.write('（另有 $duplicateMedications 种已存在，会跳过，不覆盖本机数据）');
    }
    b.write('\n· 新增 ${newLogs} 条服药记录');
    if (duplicateLogs > 0) {
      b.write('（另有 $duplicateLogs 条已存在，会跳过）');
    }
    return b.toString();
  }
}

/// 导出失败的类型 —— UI 要按这个给不同的出路
///
/// V1.4.0 修复「导出失败 + 提示无写入权限」双重误导：
/// 过去所有失败都显示「所选位置可能没有写入权限」，但真实原因是
/// `getSaveLocation()` 在 Android 上**根本没实现**（见 [_pickSavePath]），
/// 与权限毫无关系。把原因分类后，提示才能落到实处。
enum ExportFailureKind {
  /// 存储空间不足
  noSpace,

  /// 设备存储不可用（只读挂载等）
  storageUnavailable,

  /// 其他意外
  unknown,
}

/// 备份文件格式标识 —— 只认自己导出的文件
const String kBackupFormat = 'zaori-kangfu-backup';

/// v2：medications 行增加 repeat/weekdays/month_days/dose_values 四个键。
const int kBackupVersion = 2;

/// 导入/导出（纯本地文件，不联网、不上传）
///
/// ═══════════════════════════════════════════════════════════════════
/// V1.4.0 核心修复：Android 上「导出必定失败」
/// ═══════════════════════════════════════════════════════════════════
///
/// 【根因】`file_selector` 的 `getSaveLocation()` 在 Android 上**不可用**。
///
/// 证据链（逐层看源码确认）：
/// 1. `FileSelectorAndroid`（file_selector_android 0.5.2+11）只覆写了
///    `openFile` / `openFiles` / `getDirectoryPath`，**没有覆写
///    `getSaveLocation`**；
/// 2. 于是调用落到基类 `FileSelectorPlatform.getSaveLocation()`；
/// 3. 基类实现是 `getSavePath(...)` 的一层转发；
/// 4. `getSavePath()` 的基类实现直接
///    `throw UnimplementedError('getSavePath() has not been implemented.')`。
///
/// 结论：旧代码在 Android 上**每次必抛 UnimplementedError**，
/// 从未真正写过文件。而 `export_flow` 把所有异常都翻成
/// 「所选位置可能没有写入权限」—— 这就是用户看到「导出失败 +
/// 无写入权限」同时出现的由来，其实两句都不准确。
///
/// 【修复策略】不再依赖 SAF 保存对话框：
/// - Android：写入 `<外部存储>/Download/早日康复/`，
///   这是系统「文件管理 → 下载」能直接看到的公共目录，
///   Android 10+ 通过直接路径写 Download 是允许的（属于
///   Android/data 之外但应用可写的公共目录，且无需任何权限）；
///   若因 ROM 限制失败，退到应用专属目录并明确告知路径。
/// - iOS / macOS / Windows / Linux：保留系统保存对话框（这些平台有实现）。
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  /// 导出的统一子目录名 —— 让用户在文件管理里一眼找到
  static const String exportFolderName = '早日康复';

  // ------------------------------------------------------------ 导出：服药记录

  /// 导出某个日期区间的服药记录为 CSV
  Future<ExportResult?> exportRecords({
    required DateTime from,
    required DateTime to,
    required String suggestedName,
  }) async {
    final _ExportBundle bundle = await _buildRecordTable(from: from, to: to);
    return _saveText(
      suggestedName: suggestedName,
      content: bundle.csv,
      title: '服药记录',
      rows: bundle.rows,
    );
  }

  /// 导出某个日期区间的记录，同时保存一份给老人看的纯文本摘要
  ///
  /// 返回 null = 用户取消；返回空列表 = 这段时间没有记录。
  Future<List<ExportResult>?> exportRecordsWithSummary({
    required DateTime from,
    required DateTime to,
    required String baseName,
  }) async {
    final _ExportBundle bundle = await _buildRecordTable(from: from, to: to);
    if (bundle.rows == 0) return <ExportResult>[];

    final List<ExportResult> out = <ExportResult>[];
    final ExportResult? csv = await _saveText(
      suggestedName: '$baseName.csv',
      content: bundle.csv,
      title: '服药记录表格',
      rows: bundle.rows,
    );
    if (csv == null) return null;
    out.add(csv);

    final ExportResult? txt = await _saveText(
      suggestedName: '$baseName.txt',
      content: bundle.summary,
      title: '服药记录摘要',
      rows: bundle.rows,
      appendBom: false,
    );
    if (txt != null) out.add(txt);
    return out;
  }

  /// 导出的药品清单（CSV）
  Future<ExportResult?> exportMedications({
    required String suggestedName,
  }) async {
    final List<Medication> all =
        await MedicationRepository.instance.allMedications();
    final StringBuffer b = StringBuffer()
      ..writeln(<String>[
        '药品名称',
        '单次剂量',
        '剂量单位',
        '服用频次',
        '提醒时间',
        '开始日期',
        '结束日期',
        '是否在提醒',
        '停用时间',
        '备注',
      ].map(_csvCell).join(','));

    for (final Medication m in all) {
      b.writeln(<String>[
        m.name,
        _fmtNum(m.dosageValue),
        m.dosageUnit,
        m.frequencyText,
        m.scheduleText,
        _date(m.startDate),
        m.endDate == null ? '长期（持续执行）' : _date(m.endDate),
        m.enabled ? '是' : '否',
        m.stoppedAt == null ? '' : _dateTime(m.stoppedAt!),
        m.note ?? '',
      ].map(_csvCell).join(','));
    }

    return _saveText(
      suggestedName: suggestedName,
      content: b.toString(),
      title: '药品清单',
      rows: all.length,
    );
  }

  // ------------------------------------------------------------ 导出：备份

  /// 生成一份完整的备份 JSON（不落盘）。
  ///
  /// 除了手动导出，V1.15.0 的「数据保险箱」也用它：内容结构与用户
  /// 手动导出的文件**完全一致**，所以恢复时走同一套 importFromJson，
  /// 不需要维护第二套解析逻辑。
  ///
  /// [extra] 用来塞备份文件之外的附加信息（例如腾讯云密钥），
  /// 用户手动导出时不会带上，只在保险箱里出现。
  Future<String> buildBackupJson({
    Map<String, Object?>? extra,
    bool pretty = false,
  }) async {
    final Database db = await _openDb();
    final List<Map<String, Object?>> meds =
        await db.query('medications', orderBy: 'created_at ASC');
    final List<Map<String, Object?>> logs =
        await db.query('dose_logs', orderBy: 'planned_time ASC');

    final Map<String, Object?> payload = <String, Object?>{
      'format': kBackupFormat,
      'version': kBackupVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'medications': meds,
      'logs': logs,
      if (extra != null) ...extra,
    };

    return pretty
        ? const JsonEncoder.withIndent('  ').convert(payload)
        : jsonEncode(payload);
  }

  /// 库里现在有多少种药（用于判断「重装后是不是空的」）
  Future<int> medicationCount() async {
    try {
      final Database db = await _openDb();
      final List<Map<String, Object?>> r =
          await db.rawQuery('SELECT COUNT(*) AS c FROM medications');
      return (r.first['c'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 导出完整备份（药品 + 全部记录）
  Future<ExportResult?> exportBackup({required String suggestedName}) async {
    final Database db = await _openDb();
    final List<Map<String, Object?>> meds =
        await db.query('medications', orderBy: 'created_at ASC');
    final List<Map<String, Object?>> logs =
        await db.query('dose_logs', orderBy: 'planned_time ASC');

    final Map<String, Object?> payload = <String, Object?>{
      'format': kBackupFormat,
      'version': kBackupVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'medications': meds,
      'logs': logs,
    };

    return _saveText(
      suggestedName: suggestedName,
      content: const JsonEncoder.withIndent('  ').convert(payload),
      title: '完整备份',
      rows: meds.length + logs.length,
      appendBom: false,
    );
  }

  // ------------------------------------------------------------ 导入

  /// 让用户挑一个备份文件，解析并算出「会发生什么」，**不写库**
  Future<({ImportPreview preview, String raw})?> pickAndPreview() async {
    const XTypeGroup group = XTypeGroup(
      label: '早日康复备份文件',
      extensions: <String>['json'],
      mimeTypes: <String>['application/json'],
    );
    final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[group]);
    if (file == null) return null;
    final String raw = await file.readAsString();
    return (preview: await previewFromJson(raw), raw: raw);
  }

  /// 解析备份文本并做冲突预演（纯函数，测试友好）
  Future<ImportPreview> previewFromJson(String raw) async {
    final Map<String, Object?> data = _decode(raw);

    final List<Map<String, Object?>> meds = _asRows(data['medications']);
    final List<Map<String, Object?>> logs = _asRows(data['logs']);

    final Database db = await _openDb();
    final Set<String> existingMedIds = <String>{
      for (final Map<String, Object?> r in await db.query(
        'medications',
        columns: <String>['id'],
      ))
        r['id'] as String,
    };
    final Set<String> existingLogKeys = <String>{
      for (final Map<String, Object?> r in await db.query(
        'dose_logs',
        columns: <String>['medication_id', 'planned_time'],
      ))
        slotKey(
          r['medication_id'] as String,
          DateTime.parse(r['planned_time'] as String),
        ),
    };

    int newMeds = 0;
    int dupMeds = 0;
    for (final Map<String, Object?> r in meds) {
      final Object? id = r['id'];
      if (id is! String || id.isEmpty) continue;
      if (existingMedIds.contains(id)) {
        dupMeds++;
      } else {
        newMeds++;
      }
    }

    int newLogs = 0;
    int dupLogs = 0;
    for (final Map<String, Object?> r in logs) {
      final String? medId = r['medication_id'] as String?;
      final DateTime? planned =
          DateTime.tryParse(r['planned_time'] as String? ?? '');
      if (medId == null || medId.isEmpty || planned == null) continue;
      if (existingLogKeys.contains(slotKey(medId, planned))) {
        dupLogs++;
      } else {
        newLogs++;
      }
    }

    return ImportPreview(
      medications: meds.length,
      logs: logs.length,
      newMedications: newMeds,
      duplicateMedications: dupMeds,
      newLogs: newLogs,
      duplicateLogs: dupLogs,
      exportedAt: DateTime.tryParse(data['exportedAt'] as String? ?? ''),
      appVersion: data['version']?.toString(),
    );
  }

  /// 真正写库（调用方必须先让用户确认过 [previewFromJson] 的结果）
  ///
  /// 冲突策略：**只补不覆盖**。
  Future<({int meds, int logs})> importFromJson(String raw) async {
    final Map<String, Object?> data = _decode(raw);
    final List<Map<String, Object?>> meds = _asRows(data['medications']);
    final List<Map<String, Object?>> logs = _asRows(data['logs']);

    final Database db = await _openDb();
    int medCount = 0;
    int logCount = 0;

    await db.transaction((Transaction txn) async {
      for (final Map<String, Object?> r in meds) {
        final String? id = r['id'] as String?;
        if (id == null || id.isEmpty) continue;
        final List<Map<String, Object?>> hit = await txn.query(
          'medications',
          columns: <String>['id'],
          where: 'id = ?',
          whereArgs: <Object?>[id],
          limit: 1,
        );
        if (hit.isNotEmpty) continue;
        await txn.insert('medications', _normalizeMedRow(r),
            conflictAlgorithm: ConflictAlgorithm.abort);
        medCount++;
      }

      for (final Map<String, Object?> r in logs) {
        final String? medId = r['medication_id'] as String?;
        final DateTime? planned =
            DateTime.tryParse(r['planned_time'] as String? ?? '');
        if (medId == null || medId.isEmpty || planned == null) continue;
        final List<Map<String, Object?>> hit = await txn.query(
          'dose_logs',
          columns: <String>['id'],
          where: 'medication_id = ? AND planned_time >= ? AND planned_time < ?',
          whereArgs: <Object?>[
            medId,
            planned.toIso8601String(),
            planned.add(const Duration(minutes: 1)).toIso8601String(),
          ],
          limit: 1,
        );
        if (hit.isNotEmpty) continue;
        await txn.insert('dose_logs', _normalizeLogRow(r),
            conflictAlgorithm: ConflictAlgorithm.abort);
        logCount++;
      }
    });

    return (meds: medCount, logs: logCount);
  }

  // ------------------------------------------------------------ 内部

  Future<Database> _openDb() async {
    return MedicationRepository.instance.database;
  }

  Map<String, Object?> _decode(String raw) {
    Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      throw const BackupFormatException('这个文件不是 JSON，打不开。');
    }
    if (parsed is! Map<String, Object?>) {
      throw const BackupFormatException('文件内容格式不对。');
    }
    if (parsed['format'] != kBackupFormat) {
      throw const BackupFormatException(
        '这不是「早日康复」的备份文件。\n\n'
        '请用「我的 → 数据存储 → 导出完整备份」生成的文件来导入。',
      );
    }
    final int version = int.tryParse(parsed['version']?.toString() ?? '') ?? 0;
    if (version > kBackupVersion) {
      throw BackupFormatException(
        '这份备份来自更新版本的 App（格式 v$version），当前版本读不了，请先升级 App。',
      );
    }
    return parsed;
  }

  List<Map<String, Object?>> _asRows(Object? raw) {
    if (raw is! List) return <Map<String, Object?>>[];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> m) => m.map(
              (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
            ))
        .toList();
  }

  Map<String, Object?> _normalizeMedRow(Map<String, Object?> r) {
    return <String, Object?>{
      'id': r['id'],
      'name': r['name'] ?? '',
      'dosage_value': (r['dosage_value'] as num?)?.toDouble() ?? 0,
      'dosage_unit': r['dosage_unit'] ?? '片',
      'frequency': FrequencyType.fromName(r['frequency'] as String?).name,
      'times': r['times'] ?? '',
      'interval_hours': r['interval_hours'],
      'note': r['note'],
      'start_date': r['start_date'],
      'end_date': r['end_date'],
      'enabled': r['enabled'] ?? 1,
      'stopped_at': r['stopped_at'],
      'created_at': r['created_at'] ?? DateTime.now().toIso8601String(),
      'repeat': r['repeat'],
      'weekdays': r['weekdays'],
      'month_days': r['month_days'],
      'dose_values': r['dose_values'],
    };
  }

  Map<String, Object?> _normalizeLogRow(Map<String, Object?> r) {
    return <String, Object?>{
      'id': r['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(),
      'medication_id': r['medication_id'],
      'planned_time': r['planned_time'],
      'action_time': r['action_time'] ?? DateTime.now().toIso8601String(),
      'status': IntakeStatus.fromName(r['status'] as String?).name,
      'snooze_count': r['snooze_count'] ?? 0,
      'snooze_minutes': r['snooze_minutes'] ?? 0,
      'source': r['source'] ?? 'import',
    };
  }

  /// 保存一份文本文件，返回落盘结果
  ///
  /// 平台差异（V1.4.0 重写的原因见类注释）：
  /// - **Android**：不用 `getSaveLocation()`（未实现，必抛异常）。
  ///   直接写 `<外部存储>/Download/早日康复/`；失败则退应用专属目录。
  /// - **桌面 / iOS**：继续用系统保存对话框。
  Future<ExportResult?> _saveText({
    required String suggestedName,
    required String content,
    required String title,
    required int rows,
    bool appendBom = true,
  }) async {
    final List<int> bytes = <int>[
      // BOM 只给 CSV：Excel/WPS 靠它认出 UTF-8，否则中文药名全是乱码
      if (appendBom) ...<int>[0xEF, 0xBB, 0xBF],
      ...utf8.encode(content),
    ];

    if (Platform.isAndroid) {
      return _saveOnAndroid(
        suggestedName: suggestedName,
        bytes: bytes,
        title: title,
        rows: rows,
      );
    }

    // ---- 桌面 / iOS：走系统保存对话框 ----
    final FileSaveLocation? loc = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: <XTypeGroup>[
        XTypeGroup(
          label: title,
          extensions: <String>[p.extension(suggestedName).replaceFirst('.', '')],
        ),
      ],
    );
    if (loc == null) return null;

    try {
      await File(loc.path).writeAsBytes(bytes, flush: true);
      return ExportResult(path: loc.path, rows: rows, title: title);
    } on FileSystemException catch (e) {
      // 桌面 / iOS 上写不进去（沙盒、只读盘）→ 退下载目录
      final String? fallback = await _tryWriteToDownload(suggestedName, bytes);
      if (fallback == null) rethrow;
      return ExportResult(
        path: fallback,
        rows: rows,
        title: title,
        degraded: true,
        shareHint: '原位置写入失败，已保存到「下载/早日康复」。',
      );
    }
  }

  /// Android：直接写公共「下载」目录，不需要任何存储权限
  ///
  /// 为什么不走 MediaStore API：往 Downloads 里放自己的子目录 +
  /// `.csv`/`.txt` 这类非媒体文件，用直接路径在 Android 10+ 是允许的
  /// （分区存储只限制 Android/data 之外的**其他应用私有**目录，
  /// Download 是公共可写目录）。这样写还有个大好处：
  /// 用户在「文件管理 → 下载」里能直接看到，不用打开 App。
  Future<ExportResult?> _saveOnAndroid({
    required String suggestedName,
    required List<int> bytes,
    required String title,
    required int rows,
  }) async {
    final String? downloadPath = await _tryWriteToDownload(
      suggestedName,
      bytes,
    );
    if (downloadPath != null) {
      return ExportResult(
        path: downloadPath,
        rows: rows,
        title: title,
        shareHint: '在「文件管理 → 下载 → $exportFolderName」里可以看到。',
      );
    }

    // 有些 ROM 把 Download 也锁了 → 退到应用专属目录（一定可写）
    try {
      final String fallback = await _writeToAppFolder(suggestedName, bytes);
      return ExportResult(
        path: fallback,
        rows: rows,
        title: title,
        degraded: true,
        shareHint: '文件存在 App 自己的文件夹里，手机「文件管理」看不到。'
            '点下面的「发送 / 保存到手机」，可以发到微信，也可以存进手机。',
      );
    } on FileSystemException catch (e) {
      throw ExportException(
        e.osError?.message.contains('ENOSPC') == true
            ? ExportFailureKind.noSpace
            : ExportFailureKind.unknown,
        '写入文件失败：${e.message}',
      );
    }
  }

  /// 尝试写 `<ExternalStorage>/Download/早日康复/`，成功返回完整路径
  ///
  /// 刻意不抛异常：这是「最优位置」，失败就返回 null 让调用方降级。
  Future<String?> _tryWriteToDownload(
    String fileName,
    List<int> bytes,
  ) async {
    Directory? base;
    try {
      base = await getDownloadsDirectory();
    } catch (_) {
      base = null;
    }

    // 有些设备 getDownloadsDirectory() 返回 null，退到手动拼外部存储路径
    final List<String> candidates = <String>{
      if (base != null) p.join(base.path, exportFolderName),
      if (Platform.isAndroid) '/storage/emulated/0/Download/$exportFolderName',
    }.toList();

    for (final String dirPath in candidates) {
      try {
        final Directory dir = Directory(dirPath);
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final String path = _uniquePath(dir.path, fileName);
        await File(path).writeAsBytes(bytes, flush: true);
        debugPrint('[Backup] 已写入 $path');
        return path;
      } catch (e) {
        debugPrint('[Backup] 写入 $dirPath 失败，尝试下一个: $e');
      }
    }
    return null;
  }

  /// 应用专属目录（无需任何权限，卸载前一直存在）
  Future<String> _writeToAppFolder(String fileName, List<int> bytes) async {
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(base.path, exportFolderName));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final String path = _uniquePath(dir.path, fileName);
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  /// 同名文件已存在时追加序号，避免静默覆盖用户的旧导出
  String _uniquePath(String dirPath, String fileName) {
    String path = p.join(dirPath, fileName);
    int i = 1;
    while (File(path).existsSync()) {
      final String ext = p.extension(fileName);
      final String stem = p.basenameWithoutExtension(fileName);
      path = p.join(dirPath, '$stem(${i++})$ext');
    }
    return path;
  }

  /// 把「计划 × 记录」铺成一张可读的表
  Future<_ExportBundle> _buildRecordTable({
    required DateTime from,
    required DateTime to,
  }) async {
    final List<Medication> meds =
        await MedicationRepository.instance.allMedications();
    final Map<String, int> bits = await MedicationRepository.instance
        .statusInRange(from, to.add(const Duration(days: 1)));
    final DateTime now = DateTime.now();

    final StringBuffer csv = StringBuffer()
      ..writeln(<String>[
        '日期',
        '计划时间',
        '药品名称',
        '剂量',
        '状态',
        '是否服用',
        '延后分钟',
        '备注',
      ].map(_csvCell).join(','));

    final StringBuffer txt = StringBuffer();
    int rows = 0;
    int taken = 0;
    int notTaken = 0;

    final DateTime lastDay = DateTime(to.year, to.month, to.day);
    for (DateTime day = DateTime(from.year, from.month, from.day);
        !day.isAfter(lastDay);
        day = day.add(const Duration(days: 1))) {
      final List<DaySlot> slots = buildSlots(meds, day, bits);
      if (slots.isEmpty) continue;

      txt.writeln('${_date(day)}（${_weekday(day)}）');
      for (final DaySlot s in slots) {
        final IntakeStatus st = s.displayStatus(now);
        // 未来的时刻不算结果，跳过，否则导出「本周」会有一堆假逾期
        if (s.planned.isAfter(now)) continue;

        rows++;
        if (st.isTaken) {
          taken++;
        } else {
          notTaken++;
        }
        csv.writeln(<String>[
          _date(day),
          s.hm,
          s.med.name,
          s.doseText,
          st.label,
          st.isTaken ? '已服用' : '未服用',
          s.snoozeMinutes == 0 ? '' : '${s.snoozeMinutes}',
          s.med.note ?? '',
        ].map(_csvCell).join(','));
        txt.writeln('  ${s.hm}  ${s.med.name} ${s.doseText}  '
            '${st.isTaken ? '✓ 已服用' : '✗ 未服用（${st.label}）'}');
      }
      txt.writeln();
    }

    final StringBuffer head = StringBuffer()
      ..writeln('早日康复 · 服药记录摘要')
      ..writeln('统计区间：${_date(from)} 至 ${_date(to)}')
      ..writeln('导出时间：${_dateTime(DateTime.now())}')
      ..writeln()
      ..writeln('这段时间一共 $rows 次计划：已服用 $taken 次，未服用 $notTaken 次。');
    if (rows > 0) {
      final int pct = (taken * 100 / rows).round();
      head.writeln('按时服药比例：$pct%');
    }
    head
      ..writeln()
      ..writeln('说明：跳过、待确认、逾期未确认都算「未服用」。')
      ..writeln('——————————————————————————————')
      ..writeln();

    return _ExportBundle(
      csv: csv.toString(),
      summary: head.toString() + txt.toString(),
      rows: rows,
    );
  }

  static String _csvCell(String raw) {
    final String v = raw.replaceAll('\r\n', ' ').replaceAll('\n', ' ');
    if (v.contains(',') || v.contains('"')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  static String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  static String _date(DateTime? d) {
    if (d == null) return '';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  static String _dateTime(DateTime d) =>
      '${_date(d)} ${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  static String _weekday(DateTime d) {
    const List<String> names = <String>['一', '二', '三', '四', '五', '六', '日'];
    return '周${names[d.weekday - 1]}';
  }
}

/// 备份文件不合规
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 导出写盘失败（带分类，方便 UI 给准确提示）
class ExportException implements Exception {
  const ExportException(this.kind, this.message);
  final ExportFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

class _ExportBundle {
  const _ExportBundle({
    required this.csv,
    required this.summary,
    required this.rows,
  });

  final String csv;
  final String summary;
  final int rows;
}
